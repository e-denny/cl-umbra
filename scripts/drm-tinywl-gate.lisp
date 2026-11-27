;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The VT gate (clause 25): a card taken the way a compositor on a VT takes one --
;;;; through a seat, not by opening the node (4d-3).
;;;;
;;;; Run by scripts/drm-tinywl-gate.sh.  Exit status: 0 pass, 1 fail, 77 skip.
;;;;
;;;; Clause 22 proves the screen can be taken when this process may open the node;
;;;; clause 23 proves a device can be decoded; clause 24 proves the keymap is the
;;;; session's.  This clause is the join: libseat opens the card, cf.backend.vt
;;;; adopts the descriptor *without* opening the path, a scene with the cursor in it
;;;; is rendered into the scanout and flipped, the kernel retires the flip, and a
;;;; disable puts the screen back and gives the descriptor back to the seat.
;;;;
;;;; Two things make this safe on a working machine:
;;;;
;;;;   * a card is only taken when it is virtual (or named twice, CL_DRM_MODESET_CARD
;;;;     and CL_DRM_MODESET_ALLOW=1), exactly as clause 22 decides it;
;;;;   * a seat that somebody else controls is a SKIP, not a failure: libseat reports
;;;;     the provider's errno from its last backend (D56 §4), which under a running
;;;;     compositor is ENOSYS over logind's EBUSY.  The skip names it.
;;;;
;;;; The VT *switch* itself is not performed here unless CL_DRM_SWITCH_VT names a
;;;; VT to switch to.  Switching takes the screen away from whatever is on it, which
;;;; is a person's decision and not a gate's; the probe says so and moves on.

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defparameter *checks* 0)
(defparameter *failures* 0)

(defun check (value description &rest arguments)
  (incf *checks*)
  (if value
      (format t "  ok   ~A~%" (apply #'format nil description arguments))
      (progn
        (incf *failures*)
        (format t "  FAIL ~A~%" (apply #'format nil description arguments)))))

(defun note (description &rest arguments)
  (format t "       ~A~%" (apply #'format nil description arguments)))

(defun skip (description &rest arguments)
  (format t "drm-tinywl-gate: skip ~A~%" (apply #'format nil description arguments))
  (uiop:quit 77))

(defun finish (summary &rest arguments)
  (format t "~&drm-tinywl-gate: ~D checks, ~D failed~%" *checks* *failures*)
  (if (plusp *failures*)
      (uiop:quit 1)
      (progn
        (format t "drm-tinywl-gate: ~A~%" (apply #'format nil summary arguments))
        (uiop:quit 0))))

(defun fd-count ()
  (length (uiop:directory-files #p"/proc/self/fd/")))

(defun current-vt ()
  "The VT this process is on: XDG_VTNR from the login, else what the kernel says.

Switching *back* needs this and not a constant: on a machine whose first VT runs a
compositor, a probe on VT 2 that switched back to VT 1 would hand the screen to
that compositor in the middle of the test -- a wrong answer, and a different one
each run."
  (or (ignore-errors (parse-integer (uiop:getenv "XDG_VTNR")))
      (let ((path #p"/sys/class/tty/tty0/active"))
        (when (probe-file path)
          (with-open-file (stream path)
            (let ((line (read-line stream nil nil)))
              (when (and line (> (length line) 3) (string= "tty" line :end2 3))
                (ignore-errors (parse-integer line :start 3)))))))))


(defun card-of (path)
  (string-right-trim "/" (file-namestring path)))

(defun allowed-card (path)
  "Is this gate willing to take PATH's screen?  Returns (values allowed driver).

The same two-setting rule clause 22 uses: a virtual driver is a yes, and anything
else needs the card named and the allow variable set, because taking somebody's
screen must take two deliberate acts."
  (let ((driver (handler-case (cf.backend.drm:drm-driver-at path)
                  (cf.backend.drm:drm-error () nil)))
        (named (equal (uiop:getenv "CL_DRM_MODESET_CARD") path))
        (allowed (equal (uiop:getenv "CL_DRM_MODESET_ALLOW") "1")))
    (values (and driver
                 (or (cf.backend.drm:drm-virtual-driver-p driver)
                     (and named allowed)))
            driver)))

;;; ---------------------------------------------------------------------------
;;; The seat, which is the whole point
;;; ---------------------------------------------------------------------------

(defun seat-errno (condition)
  (and (typep condition 'cf.session:session-error)
       (cf.session:session-error-errno condition)))

(defun describe-seat-failure (condition)
  "What the provider said, in terms a person can act on.

libseat reports the errno of the last backend it tried: seatd's socket missing is
ENOENT and logind refusing control of a session it does not own is EBUSY, both of
which arrive here as the no-op backend's ENOSYS (measured, D56 §4).  So the message
names the errno it got and the two things it usually means."
  (let ((errno (seat-errno condition)))
    (cond
      ((eql errno wayland.ffi:+enosys+)
       "libseat answered ENOSYS: no backend took the seat (seatd is not running, and logind will not hand over a session another compositor owns)")
      ((eql errno wayland.ffi:+ebusy+)
       "libseat answered EBUSY: this session is owned by another compositor -- run from a text console")
      ((eql errno wayland.ffi:+eacces+)
       "libseat answered EACCES: this user may not take the seat")
      (t (format nil "libseat failed with errno ~A" errno)))))

(defun open-seat ()
  (handler-case
      (let ((session (cf.session:open-session :name "seat0")))
        (unless (cf.session:session-enabled-p session)
          (cf.session:close-session session)
          (skip "the seat opened but is not enabled (state ~A): a seat that is not
enabled yet would need a VT switch to become usable, and this machine's session is
another compositor's"
                (cf.session:session-state-string session)))
        session)
    (cf.session:session-error (condition)
      (skip "~A" (describe-seat-failure condition)))))

;;; ---------------------------------------------------------------------------
;;; The probe
;;; ---------------------------------------------------------------------------

(let* ((session (open-seat))
       (paths (cf.backend.drm:drm-device-paths))
       (candidates '()))
  (dolist (path paths)
    (multiple-value-bind (allowed driver) (allowed-card path)
      (when allowed
        (push (list path (card-of path) driver) candidates))))
  (unless candidates
    (cf.session:close-session session)
    (skip "no virtual KMS card~@[ (cards: ~{~A~^, ~})~]; load vkms, or name a card with CL_DRM_MODESET_CARD and CL_DRM_MODESET_ALLOW=1"
          (mapcar #'card-of paths)))
  (destructuring-bind (path card driver) (first candidates)
    (note "seat ~A is ~A, card ~A (~A), driver ~A"
          (cf.session:session-name session)
          (cf.session:session-state-string session)
          card path driver)
    ;; The card is opened *by the seat*, which is the one thing this clause adds to
    ;; clause 22's arithmetic.  A descriptor this process opened would pass every
    ;; other check and prove nothing about a VT.  The seat comes first because it is
    ;; the part only a VT can answer: a session another compositor owns is a skip
    ;; here, before any card is looked at.
    (let* ((output nil)
           (compositor nil))
      (unwind-protect
           (handler-case
               (progn
                 (setf output (cf.backend.vt:open-vt-output session :path path))
                 (check (cf.backend.vt:vt-output-enabled-p output)
                        "the seat opened ~A and the output came up with it" card)
                 (check (= 1 (cf.session:session-open-device-count session))
                        "exactly one device is open, and the seat is the one that opened it")
                 (check (plusp (cf.backend.vt:vt-output-width output))
                        "a mode was programmed: ~Dx~D on connector ~A"
                        (cf.backend.vt:vt-output-width output)
                        (cf.backend.vt:vt-output-height output)
                        (cf.backend.vt:vt-output-connector-name output))
                 (let* ((device (cf.backend.vt:vt-output-device output))
                        (scanout (cf.backend.vt:vt-output-scanout output))
                        (saved (cf.backend.drm:drm-scanout-saved-state scanout))
                        (crtc-id (cf.backend.drm:drm-scanout-crtc-id scanout))
                        (width (cf.backend.vt:vt-output-width output))
                        (height (cf.backend.vt:vt-output-height output)))
                   (check (cf.backend.drm:drm-device-master-p device)
                          "the descriptor the seat handed over is master -- SET MASTER is per-fd, not privileged")
                   (check (= 2 (cf.backend.drm:drm-scanout-buffer-count scanout))
                          "two buffers, so the frame being scanned out is never redrawn")

                   ;; One real frame, through the compositor's own seam: the preparer
                   ;; answers a target over the scanout buffer, the scene draws -- cursor
                   ;; included, because there is no cursor plane (D58) -- and the
                   ;; presenter flips and waits for the kernel's completion.
                   (setf compositor (cf:make-headless-compositor
                                     :width width :height height
                                     :display-name "tinywl-vt-gate"
                                     :runtime-dir (or (uiop:getenv "XDG_RUNTIME_DIR") "/tmp")))
                   (multiple-value-bind (preparer presenter)
                       (cf.backend.vt:make-vt-frame-hooks output)
                     (setf (cf.backend.headless:compositor-frame-preparer compositor) preparer
                           (cf.backend.headless:compositor-frame-presenter compositor) presenter))
                   (cf:inject-pointer-motion compositor (floor width 2) (floor height 2))
                   (cf:request-frame compositor)
                   (let ((target (cf:render-frame compositor)))
                     (check (not (null target)) "a frame was drawn into a scanout buffer")
                     (check (= 1 (cf.backend.drm:drm-scanout-frames scanout))
                            "and presented: one flip, retired by the kernel"))
                   (let ((event (cf.backend.drm:drm-scanout-last-event scanout)))
                     (check (and event (eq :flip-complete (getf event :type)))
                            "the completion is the kernel's own flip event")
                     (check (and event (= crtc-id (getf event :crtc-id)))
                            "for this CRTC, not somebody else's")
                     (when event
                       (note "flip sequence ~D at ~D.~6,'0D"
                             (getf event :sequence) (getf event :tv-sec) (getf event :tv-usec))))

                   ;; The frame was drawn through a target at the driver's pitch (D58):
                   ;; a padded pitch is the case that shears, and it is the case a real
                   ;; card is allowed to have.
                   (let ((pitch (cf.backend.drm:dumb-buffer-pitch
                                 (cf.backend.drm:drm-scanout-next-buffer scanout))))
                     (note "pitch ~D for ~D pixels at ~D bytes each~@[ (padded)~]"
                           pitch width (* width 4) (and (/= pitch (* width 4)) t))
                     (check (>= pitch (* width 4))
                            "the driver's pitch is at least the width in pixels"))

                   ;; A VT switch, only when a person named the VT to switch to.
                   (let ((vt (ignore-errors (parse-integer (uiop:getenv "CL_DRM_SWITCH_VT")))))
                     (cond
                       ((null vt)
                        (note "no VT switch performed: set CL_DRM_SWITCH_VT=N to switch there and back (that is a manual round trip, docs/testing.md §11)"))
                       (t
                        (let ((here (current-vt)))
                          (cond
                            ((null here)
                             (note "this process does not say which VT it is on
(XDG_VTNR unset, /sys/class/tty/tty0/active unreadable), so the round trip is not
attempted: switching back to a guess is how a probe steals a compositor's VT"))
                            ((= here vt)
                             (note "CL_DRM_SWITCH_VT names the VT this gate is already on (~D): nothing to switch to" vt))
                            (t
                             (check (plusp here)
                                    "this gate knows which VT it is on (~D), so it can come back" here)
                             (note "switching to VT ~D" vt)
                             (handler-case (cf.session:switch-session-to session vt)
                               (error (condition)
                                 (note "the switch request failed: ~A" condition)))
                             (let ((waited 0))
                               (loop while (and (< waited 200)
                                                (cf.session:session-enabled-p session))
                                     do (cf.session:dispatch-session session :timeout 10)
                                        (incf waited))
                               (check (not (cf.session:session-enabled-p session))
                                      "the switch disabled the seat: the seat is a subscription")
                               (check (not (cf.backend.vt:vt-output-enabled-p output))
                                      "and the output gave the screen back"))
                             ;; The way back is the person's: polkit lets the
                             ;; *active* session activate a VT, and after the switch
                             ;; this one is not active.  So the gate asks, and if the
                             ;; ask is refused it says which keys to press and keeps
                             ;; dispatching -- the enable it is waiting for arrives
                             ;; from the kernel through logind either way.
                             (note "switching back to VT ~D, this gate's own; if that
is refused (an inactive session may not activate a VT), press Ctrl+Alt+F~D and this
waits up to a minute for the seat to come back" here here)
                             (handler-case (cf.session:switch-session-to session here)
                               (error (condition)
                                 (note "the return switch was refused: ~A" condition)))
                             (let ((waited 0))
                               (loop until (or (>= waited 600)
                                               (cf.session:session-enabled-p session))
                                     do (cf.session:dispatch-session session :timeout 100)
                                        (incf waited))
                               (check (cf.session:session-enabled-p session)
                                      "coming back enabled the seat again")
                               (check (cf.backend.vt:vt-output-enabled-p output)
                                      "and the output took the screen again, by itself")
                               (check (>= (cf.backend.vt:vt-output-enable-count output) 2)
                                      "with the enable counted"))))))))

                   ;; Giving it all back, which is what a compositor that exits does.
                   (let ((descriptors-before (fd-count)))
                     (cf.backend.vt:close-vt-output output)
                     (check (not (cf.backend.vt:vt-output-enabled-p output))
                            "closing the output gave the screen back")
                     (let ((after (handler-case (cf.backend.drm:open-drm-device path)
                                    (cf.backend.drm:drm-error () nil))))
                       (when after
                         (unwind-protect
                              (let ((state (cf.backend.drm:drm-crtc-state after crtc-id)))
                                (check (= (cf.backend.drm:drm-crtc-buffer-id saved)
                                          (cf.backend.drm:drm-crtc-buffer-id state))
                                       "the CRTC's framebuffer is the one that was there before")
                                (check (eq (cf.backend.drm:drm-crtc-mode-valid-p saved)
                                           (cf.backend.drm:drm-crtc-mode-valid-p state))
                                       "and its mode is on or off as it was"))
                           (cf.backend.drm:close-drm-device after))))
                     (check (<= (fd-count) descriptors-before)
                            "no descriptor was left behind (~D open before, ~D after)"
                            descriptors-before (fd-count))))
                 (cf.session:close-session session)
                 (finish "the card was taken through a seat, one frame was retired by the kernel, and the screen went back"))
             (error (condition)
               (incf *failures*)
               (check nil "the VT session failed: ~A" condition)
               (finish "the VT gate failed")))
        ;; Whatever happened, the screen goes back: a gate that leaves a card taken
        ;; is worse than a gate that fails.
        (when output (ignore-errors (cf.backend.vt:close-vt-output output)))
        (ignore-errors (cf.session:close-session session))))))
