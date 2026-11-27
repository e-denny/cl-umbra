;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The damage history measured on a card (D61): does a buffer repaint only what
;;;; changed since *that* buffer was last scanned out?
;;;;
;;;; Run by scripts/damage-probe.sh, from a text console whose login owns the seat.
;;;; Exit status: 0 pass, 1 fail, 77 skip.
;;;;
;;;; Clause 25 renders exactly *one* frame, and one frame is always full, so it cannot
;;;; answer this question at all -- which is why the hardware half of D61 needed this
;;;; probe and not a new clause.  It takes the card the way the gate does (a seat, one
;;;; open, never a second descriptor), installs the VT frame hooks the desktop installs,
;;;; and flips a sequence of frames while the pointer moves.  Per frame it prints the
;;;; buffer, the damage box the compositor reported, whether the frame flipped, and
;;;; the buffer's place in the history.  Then it writes a sentinel into the buffer the
;;;; next frame will draw into -- the one *not* on screen -- and reads pixels back out
;;;; afterwards: a dumb buffer on a real card is still host memory, so the pixel claim
;;;; is checkable here and not only against a fake card.
;;;;
;;;; The sequence is the argument (D61):
;;;;
;;;;   1-2   neither buffer has a past, so both are painted whole
;;;;   3     the pointer moves; the box reaches back to where it was, and is not the mode
;;;;   4-5   small moves; each draws into a buffer two frames old, and stays small --
;;;;         the two-buffer rotation is not degrading to full every frame
;;;;   6     the pointer stops: this frame is NOT empty, because its buffer missed
;;;;         frame 5's change and owes exactly that, and nothing more
;;;;   7     idle again: owes nothing, changed nothing, so it is drawn and not flipped,
;;;;         but it still takes a frame number
;;;;   8     the sentinel frame: the damage box is repainted whole, the rest of the
;;;;         buffer is not
;;;;
;;;; A card is taken only when it is virtual, or named twice the way clauses 22 and 25
;;;; decide it; a seat another compositor owns is a SKIP, not a failure (D56 §4).

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

;;; ---------------------------------------------------------------------------
;;; The probe's own vocabulary (the same shape as scripts/drm-tinywl-gate.lisp)
;;; ---------------------------------------------------------------------------

(defparameter *checks* 0)
(defparameter *failures* 0)

(defparameter *compositor* nil
  "The compositor the frame helpers report from; bound once the output is up.")

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
  (format t "damage-probe: skip ~A~%" (apply #'format nil description arguments))
  (uiop:quit 77))

(defun finish ()
  (format t "~&damage-probe: ~D checks, ~D failed~%" *checks* *failures*)
  (uiop:quit (if (plusp *failures*) 1 0)))

(defun fd-count ()
  (length (uiop:directory-files #p"/proc/self/fd/")))

(defun box-area (box)
  (if (consp box) (* (third box) (fourth box)) most-positive-fixnum))

(defun box-inside-p (inner outer)
  "Is box INNER wholly within box OUTER?"
  (and (consp inner) (consp outer)
       (<= (first outer) (first inner))
       (<= (second outer) (second inner))
       (<= (+ (first inner) (third inner)) (+ (first outer) (third outer)))
       (<= (+ (second inner) (fourth inner)) (+ (second outer) (fourth outer)))))

(defun box-description (box)
  (cond ((eq box :full) ":full")
        ((null box) "nothing")
        (t (format nil "(~D ~D ~D ~D)" (first box) (second box)
                   (third box) (fourth box)))))

(defun count-colour (buffer x y width height colour)
  "How many pixels in the box hold COLOUR -- a claim the pixels make, not the code."
  (loop for py from y below (+ y height)
        sum (loop for px from x below (+ x width)
                  count (= colour (cf.backend.drm:dumb-buffer-pixel buffer px py)))))

(defun partial ()
  (cf:compositor-partial-frame-count *compositor*))

;;; ---------------------------------------------------------------------------
;;; Which card, and taking it through the seat
;;; ---------------------------------------------------------------------------

(defun card-of (path)
  (string-right-trim "/" (file-namestring path)))

(defun choose-card ()
  "The first card this probe is willing to take, and its driver.

The same two-setting rule clause 22 and clause 25 use: a virtual driver is a yes,
and anything else needs the card named and the allow variable set, because taking
somebody's screen must take two deliberate acts."
  (let ((paths (cf.backend.drm:drm-device-paths))
        (named (uiop:getenv "CL_DRM_MODESET_CARD"))
        (allowed (equal (uiop:getenv "CL_DRM_MODESET_ALLOW") "1"))
        (candidates '()))
    (dolist (path paths)
      (let ((driver (handler-case (cf.backend.drm:drm-driver-at path)
                      (cf.backend.drm:drm-error () nil))))
        (when (and driver
                   (or (cf.backend.drm:drm-virtual-driver-p driver)
                       (and allowed (equal named path))))
          (push (list path driver) candidates))))
    (unless candidates
      (skip "no card this probe may take~@[ (cards: ~{~A~^, ~})~]; load vkms, or name a card with CL_DRM_MODESET_CARD=/dev/dri/cardN and CL_DRM_MODESET_ALLOW=1"
            (mapcar #'card-of paths)))
    (first candidates)))

(defun seat-errno (condition)
  (and (typep condition 'cf.session:session-error)
       (cf.session:session-error-errno condition)))

(defun open-seat ()
  (handler-case
      (let ((session (cf.session:open-session :name "seat0")))
        (unless (cf.session:session-enabled-p session)
          (cf.session:close-session session)
          (skip "the seat opened but is not enabled (state ~A): run this from a text console whose login owns the seat"
                (cf.session:session-state-string session)))
        session)
    (cf.session:session-error (condition)
      (skip "the seat was refused (errno ~A): run this from a console session logind may hand the seat to"
            (seat-errno condition)))))

(defun open-seat-device (session path)
  "The seat's descriptor, adopted without opening the path a second time (D59)."
  (multiple-value-bind (fd id) (cf.session:open-session-device session path)
    (handler-case
        (values (cf.backend.drm:open-drm-device-from-fd fd :path path) id)
      (error (condition)
        (ignore-errors (cf.session:close-session-device session id))
        (error condition)))))

;;; ---------------------------------------------------------------------------
;;; Frames
;;; ---------------------------------------------------------------------------

(defun report-frame (output scanout label)
  "Draw and present one frame; say what the compositor answered; return three values.

The buffer is read from the scanout *before* the render, because that is the one the
VT preparer will pick (it calls DRM-SCANOUT-NEXT-BUFFER itself), and because
CF:RENDER-FRAME answers the pixman target it drew through, not the buffer behind it.

Returns (values DAMAGE-BOUNDS TARGET FLIPPED-P)."
  (let* ((number (1+ (cf:compositor-frame-count *compositor*)))
         (buffer (cf.backend.drm:drm-scanout-next-buffer scanout))
         (flips-before (cf.backend.drm:drm-scanout-frames scanout))
         (target (cf:render-frame *compositor*))
         (bounds (cf:output-damage-bounds *compositor*))
         (flips (cf.backend.drm:drm-scanout-frames scanout)))
    (note "frame ~D (~A): buffer ~A, damage ~A, ~:[drawn, not flipped~;flipped~], flips ~D, sequence ~D, partial ~D"
          number label
          (cf.backend.drm:dumb-buffer-framebuffer-id buffer)
          (box-description bounds)
          (/= flips-before flips) flips
          (cf.backend.vt:vt-output-frame-sequence output)
          (partial))
    (values bounds target (/= flips-before flips))))

(defun measure-rotation (output scanout width height)
  "The frames that answer D61's question on this card."
  (let ((x (floor width 8))
        (y (floor height 8))
        (last-bounds nil))
    ;; 1-2: neither buffer has a past, so both are painted whole.
    (multiple-value-bind (b1 t1) (report-frame output scanout "nothing moved yet")
      (check (eq b1 :full) "the first frame paints its buffer whole (~A)" (box-description b1))
      (check t1 "and it was presented")
      (check (= 0 (partial)) "no partial frame yet"))
    (multiple-value-bind (b2) (report-frame output scanout "still nothing moved")
      (check (eq b2 :full)
             "the second frame paints the other buffer whole too (~A), because it has never been drawn"
             (box-description b2)))

    ;; 3: the pointer moves for the first time.  The box reaches back to where it
    ;; was, and is not the whole output.
    (cf:inject-pointer-motion *compositor* x y)
    (let ((before (partial)))
      (multiple-value-bind (b3 t3) (report-frame output scanout "pointer moved")
        (check (= (1+ before) (partial)) "the third frame is counted as partial")
        (check (consp b3) "and its damage is a box, not the whole output: ~A"
               (box-description b3))
        (check (< (box-area b3) (* width height))
               "the box is smaller than the mode (~D of ~D pixels)"
               (box-area b3) (* width height))
        (check t3 "and it was presented")
        (setf last-bounds b3)))

    ;; 4-5: small moves.  On a two-buffer rotation each of these draws into a buffer
    ;; two frames old; a box a few cursor widths wide is the whole claim of D61.
    (dotimes (i 2)
      (cf:inject-pointer-motion *compositor* (+ x (* 20 (1+ i))) y)
      (let ((before (partial)))
        (multiple-value-bind (bounds) (report-frame output scanout "pointer moved a little")
          (check (= (1+ before) (partial)) "a small move is counted as partial")
          (check (and (consp bounds) (< (box-area bounds) (* width 256)))
                 "and repaints only a small box (~A, ~D pixels)"
                 (box-description bounds) (box-area bounds))
          (setf last-bounds bounds))))

    ;; 6: the pointer stops.  This frame is NOT empty: it draws into the buffer that
    ;; was last shown two frames ago, so it owes that frame's change -- the union of
    ;; the box the cursor left and the box it arrived in, and no more.  That
    ;; obligation is the difference between D61 and a full repaint.
    (let ((before (partial)))
      (multiple-value-bind (b6 t6 flipped) (report-frame output scanout "pointer stopped")
        (declare (ignore t6))
        (check flipped "an idle frame still flips when this buffer missed the last change")
        (check (and (consp b6) (box-inside-p b6 last-bounds)
                    (< (box-area b6) (box-area last-bounds)))
               "and it repaints only the change it missed (~A), not the merged box it was shown (~A)"
               (box-description b6) (box-description last-bounds))
        (check (= (1+ before) (partial)) "and it is counted as partial")))

    ;; 7: idle again.  Now the buffer missed an unchanged frame, owes nothing and
    ;; changes nothing: drawing is cheap, a flip is a vblank's wait.
    (let ((sequence (cf.backend.vt:vt-output-frame-sequence output)))
      (multiple-value-bind (b7 target flipped) (report-frame output scanout "still stopped")
        (declare (ignore target))
        (check (not flipped) "a frame with nothing owed and nothing changed is not flipped")
        (check (null b7) "and it has no damage at all (~A)" (box-description b7))
        (check (= (1+ sequence) (cf.backend.vt:vt-output-frame-sequence output))
               "but it took a frame number (sequence ~D -> ~D)"
               sequence (cf.backend.vt:vt-output-frame-sequence output))))))

(defun measure-sentinel (output scanout width height)
  "Fill the buffer the next frame will draw into, then check what the frame leaves.

A dumb buffer on a real card is still host memory, so this is readable here; the
buffer filled is the one *not* on screen, so nothing flickers."
  (let* ((x (floor width 8))
         (y (floor height 8))
         (buffer (cf.backend.drm:drm-scanout-next-buffer scanout))
         (sentinel #xFF5A5A5A)
         (old-x (+ x 40))
         (new-x (+ x 60))
         (before (partial)))
    (cf.render.pixman:fill-target (cf.backend.vt:vt-output-frame-target output buffer)
                                  sentinel)
    (cf:inject-pointer-motion *compositor* new-x y)
    (let ((flips-before (cf.backend.drm:drm-scanout-frames scanout)))
      (cf:render-frame *compositor*)
      (note "frame ~D (sentinel): buffer ~A, damage ~A, flips ~D"
            (cf:compositor-frame-count *compositor*)
            (cf.backend.drm:dumb-buffer-framebuffer-id buffer)
            (box-description (cf:output-damage-bounds *compositor*))
            (cf.backend.drm:drm-scanout-frames scanout))
      (check (= (1+ flips-before) (cf.backend.drm:drm-scanout-frames scanout))
             "a moved pointer does flip")
      (check (= (1+ before) (partial)) "and the frame is partial")
      (check (= sentinel (cf.backend.drm:dumb-buffer-pixel buffer 10 (- height 10)))
             "a pixel nobody damaged still holds what it held (~X at (10 ~D))"
             sentinel (- height 10))
      ;; Both boxes are inside the damage, so both are filled with the background:
      ;; no sentinel survives where the cursor was, and none where it went.
      (check (zerop (count-colour buffer old-x y 16 16 sentinel))
             "the box the cursor left is repainted, not left as the sentinel")
      (check (zerop (count-colour buffer new-x y 16 16 sentinel))
             "and so is the box it arrived in: the whole damage box, nothing more"))))

;;; ---------------------------------------------------------------------------
;;; The run
;;; ---------------------------------------------------------------------------

(defun restore (path output saved crtc-id)
  "Give the screen back, then check that it went back the way it was found.

The descriptor baseline is taken *here*, the way clause 25 takes it: what this
checks is that closing the output gives back what the output held.  Counting from
before the seat was opened would count the seat's and the display's sockets as a
leak, and they are still open at this point on purpose."
  (let ((before (fd-count)))
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
    (check (<= (fd-count) before)
           "no descriptor was left behind (~D open before closing the output, ~D after)"
           before (fd-count))))

(defun run (path driver)
  (let ((session (open-seat))
        (output nil)
        (compositor nil)
        (saved nil)
        (crtc-id nil)
        (directory (format nil "/tmp/damage-probe-~D/" (get-universal-time))))
    (ensure-directories-exist directory)
    (note "seat ~A is ~A; card ~A, driver ~A"
          (cf.session:session-name session)
          (cf.session:session-state-string session)
          path driver)
    (unwind-protect
         (handler-case
             (progn
               (multiple-value-bind (device device-id) (open-seat-device session path)
                 (setf output (cf.backend.vt:open-vt-output session :path path
                                                            :device device
                                                            :device-id device-id)))
               (check (cf.backend.vt:vt-output-enabled-p output)
                      "the seat opened ~A and the output came up with it" path)
               (check (= 1 (cf.session:session-open-device-count session))
                      "one open of the card, and the seat did it")
               (let* ((width (cf.backend.vt:vt-output-width output))
                      (height (cf.backend.vt:vt-output-height output))
                      (scanout (cf.backend.vt:vt-output-scanout output)))
                 (setf saved (cf.backend.drm:drm-scanout-saved-state scanout)
                       crtc-id (cf.backend.drm:drm-scanout-crtc-id scanout))
                 (note "mode ~Dx~D on ~A, pitch ~D bytes"
                       width height (cf.backend.vt:vt-output-connector-name output)
                       (cf.backend.drm:dumb-buffer-pitch
                        (cf.backend.drm:drm-scanout-next-buffer scanout)))
                 (check (= 2 (cf.backend.drm:drm-scanout-buffer-count scanout))
                        "two buffers, so the frame on screen is never redrawn")
                 (setf compositor (cf:make-headless-compositor
                                   :width width :height height
                                   :display-name (format nil "damage-probe-~D"
                                                         (get-universal-time))
                                   :runtime-dir directory)
                       *compositor* compositor)
                 (multiple-value-bind (preparer presenter)
                     (cf.backend.vt:make-vt-frame-hooks output)
                   (setf (cf.backend.headless:compositor-frame-preparer compositor)
                         preparer
                         (cf.backend.headless:compositor-frame-presenter compositor)
                         presenter))
                 (measure-rotation output scanout width height)
                 (measure-sentinel output scanout width height)
                 (note "partial frames measured on ~A: ~D" path (partial)))
               (restore path output saved crtc-id)
               (setf output nil))
           (error (condition)
             (check nil "the probe failed: ~A" condition)))
      (when output
        (ignore-errors (cf.backend.vt:close-vt-output output)))
      (ignore-errors (cf.session:close-session session))
      (when compositor
        (ignore-errors (wayland.server:close-display
                        (cf:compositor-display compositor))))
      (ignore-errors (uiop:delete-directory-tree (pathname directory) :validate t)))
    (finish)))

(let ((card (choose-card)))
  (run (first card) (second card)))
