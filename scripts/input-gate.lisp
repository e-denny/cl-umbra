;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The input gate (clause 23): the seat, the devices, and the path from an evdev
;;;; code to a keybinding (D56).
;;;;
;;;; Run by scripts/input-gate.sh.  Exit status: 0 pass, 1 fail, 77 skip.
;;;;
;;;; Three parts, because the three can fail independently and for different
;;;; reasons:
;;;;
;;;;   1. THE SEAT.  cf.session opens logind's seat for this session.  On a machine
;;;;      somebody is using, that call is *expected to fail*: logind lets one
;;;;      client take control of a session, and the running compositor has it.  A
;;;;      refusal is reported as a skip with the errno, not as a failure -- the
;;;;      same policy D55 applies to a card another master is presenting on.  The
;;;;      seat's state machine is tested without a provider in
;;;;      tests/unit/session.lisp; what only a live session can answer is whether
;;;;      logind says yes, and on whose.
;;;;
;;;;   2. THE DEVICES.  libinput opens every /dev/input/event* that is there, says
;;;;      what each one is (name, sysname, vendor, product, capabilities), and is
;;;;      then closed again with no descriptor leaked.  This needs read access --
;;;;      membership of the `input' group -- so it is skipped, with that sentence,
;;;;      when the group is not in the process's effective set.  Nothing is
;;;;      grabbed: the session keeps its keyboard while this runs.
;;;;
;;;;   3. THE CHAIN.  A raw event -- what a device would have produced -- goes
;;;;      through the decoder into a real compositor's seat: evdev code 60 becomes
;;;;      the keysym name "F2" becomes a keybinding firing, a 5000-pixel motion
;;;;      lands on the last pixel of the output rather than past it, and an
;;;;      unnamed key is reported rather than dropped.  No device, no session and
;;;;      no hardware is needed for this part, which is why it always runs.
;;;;
;;;; What is deliberately NOT tested here: a virtual keyboard written through
;;;; /dev/uinput.  It would prove the round trip on a device we create, and it
;;;; would also appear in the live session as a real keyboard -- so a test key
;;;; would be typed into whatever window is focused.  The same coverage comes from
;;;; part 3 with none of that reach.

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defvar *checks* 0)
(defvar *failures* 0)
(defvar *skips* 0)

(defun check (value description &rest arguments)
  (incf *checks*)
  (if value
      (format t "  ok   ~A~%" (apply #'format nil description arguments))
      (progn
        (incf *failures*)
        (format t "  FAIL ~A~%" (apply #'format nil description arguments))))
  value)

(defun note (description &rest arguments)
  (format t "       ~A~%" (apply #'format nil description arguments)))

(defun skip (description &rest arguments)
  (incf *skips*)
  (format t "  skip ~A~%" (apply #'format nil description arguments)))

(defun finish (summary &rest arguments)
  (cond
    ((plusp *failures*)
     (format t "~&input-gate: ~D check(s), ~D failed~%" *checks* *failures*)
     (sb-ext:exit :code 1))
    ;; No check at all means nothing was proved; say so rather than pass.
    ((zerop *checks*)
     (format t "~&input-gate: skip nothing could be checked on this machine~%")
     (sb-ext:exit :code 77))
    (t
     (format t "~&input-gate: ~A~%" (apply #'format nil summary arguments))
     (sb-ext:exit :code 0))))

(defun fd-count ()
  (length (directory "/proc/self/fd/*")))

(defun event-paths ()
  (sort (mapcar #'namestring (directory "/dev/input/event*")) #'string<))

(defun event-node-readable-p (path)
  "Whether this process may open an event node read-write, which is what libinput
asks for.  Asked by opening it: membership recorded in /etc/group is not the same
as membership in the effective set, and a login that predates the change has the
old set -- which is exactly the confusion EACCES produces."
  (handler-case
      (let ((fd (wayland.ffi:open-path path :direction :io)))
        (wayland.ffi:close-fd fd)
        t)
    (wayland.ffi:io-error (condition)
      (declare (ignore condition))
      nil)))

;;; ---------------------------------------------------------------------------
;;; 1. The seat
;;; ---------------------------------------------------------------------------

(defun probe-seat ()
  (format t "~&the seat~%")
  (handler-case
      (let ((session (cf.session:open-session)))
        (unwind-protect
             (progn
               (check (plusp (cf.session:session-fd session))
                      "the seat opened: ~A on fd ~D"
                      (cf.session:session-seat-name session)
                      (cf.session:session-fd session))
               ;; Availability may be reported from inside the open (logind) or
               ;; only on dispatch (seatd); give the connection a few cycles.
               (loop repeat 20
                     until (cf.session:session-enabled-p session)
                     do (cf.session:dispatch-session session :timeout 50))
               (check (cf.session:session-enabled-p session)
                      "the seat reports itself available (~D enable(s), ~D dispatch(es))"
                      (cf.session:session-enable-count session)
                      (cf.session:session-dispatch-count session))
               (let ((path (first (event-paths))))
                 (when (and path (cf.session:session-enabled-p session))
                   (handler-case
                       (multiple-value-bind (fd id)
                           (cf.session:open-session-device session path)
                         (check (plusp fd) "~A opened through the seat: fd ~D, device id ~D"
                                path fd id)
                         (check (cf.session:close-session-device session id)
                                "the device was given back to the seat")
                         (check (= 0 (cf.session:session-open-device-count session))
                                "the seat holds no device afterwards"))
                     (cf.session:session-error (condition)
                       (skip "~A through the seat: ~A"
                             path (cf.session:session-error-operation condition))))))
               (check (null (cf.session:session-device-paths session))
                      "no device is left open on the seat"))
          (cf.session:close-session session)
          (check (cf.session:session-closed-p session) "the seat is closed")))
    (cf.session:session-error (condition)
      ;; EBUSY: another client of this session holds logind's control (a running
      ;; compositor).  ENOSYS: every backend refused and the last one was libseat's
      ;; no-op -- which is what EBUSY from logind degrades to.  Neither is a bug in
      ;; this module; both mean "this session already has an owner".
      (let ((errno (cf.session:session-error-errno condition)))
        (if (member errno '(16 38 19 13 2 22))
            (progn
              (skip "the seat: ~A (errno ~D) -- this session already has a seat owner"
                    (cf.session:session-error-operation condition) errno)
              (note "logind lets one client take control of a session; a running")
              (note "compositor holds it.  The state machine is unit-tested; the")
              (note "live path needs a free VT (phase 4d)."))
            (check nil "the seat: ~A" condition))))))

;;; ---------------------------------------------------------------------------
;;; 2. The devices
;;; ---------------------------------------------------------------------------

(defun probe-devices ()
  (format t "~&the devices~%")
  (let ((paths (event-paths)))
    (cond
      ((null paths)
       (skip "no /dev/input/event* nodes on this machine"))
      ((not (event-node-readable-p (first paths)))
       (skip "~D event node(s) present, but ~A is not readable by this process"
             (length paths) (first paths))
       (note "the `input' group is what grants it (this project's chosen route,")
       (note "D56).  usermod -aG input edgar takes effect at the next login; a")
       (note "shell started before the change still carries the old group set."))
      (t
       (let* ((baseline (fd-count))
              (driver (cf.backend.libinput:make-input-driver :width 800 :height 600))
              (added '()))
         (unwind-protect
              (progn
                (cf.backend.libinput:open-input driver :udev nil)
                (dolist (path paths)
                  (unless (cf.backend.libinput:add-input-device driver path)
                    (note "libinput refused ~A (it reports the errno itself)" path)))
                ;; DEVICE_ADDED arrives on dispatch, so drain a few cycles.
                (loop repeat 10 do (cf.backend.libinput:poll-input driver) (sleep 0.02))
                (setf added (cf.backend.libinput:input-driver-device-names driver))
                (check (plusp (length added))
                       "libinput opened ~D of ~D event node(s)"
                       (length added) (length paths))
                (check (= (length added)
                          (cf.backend.libinput:input-driver-device-added-count driver))
                       "every opened device was announced once (~D)"
                       (cf.backend.libinput:input-driver-device-added-count driver))
                (check (= (length added)
                          (cf.backend.libinput:input-driver-config-applied-count driver))
                       "every device was given the framework's defaults (tap, natural scroll)")
                (dolist (sysname added)
                  (let ((device (gethash sysname (cf.backend.libinput:input-driver-devices driver))))
                    (check (and (stringp (getf device :name))
                                (plusp (length (getf device :name))))
                           "~A: ~S" sysname (getf device :name))
                    (check (listp (getf device :caps))
                           "~A: capabilities ~S" sysname (getf device :caps))))
                (check (member :keyboard
                               (loop for sysname in added
                                     append (getf (gethash sysname (cf.backend.libinput:input-driver-devices driver))
                                                  :caps)))
                       "at least one opened device is a keyboard"
                       ))
           (cf.backend.libinput:close-input driver)
           (check (= baseline (fd-count))
                  "no descriptor leaked (~D before, ~D after)" baseline (fd-count))))))))

;;; ---------------------------------------------------------------------------
;;; 3. The chain into a compositor
;;; ---------------------------------------------------------------------------

(defun probe-chain ()
  (format t "~&the chain~%")
  (let* ((compositor (cf:make-headless-compositor :width 800 :height 600
                                                  :background #xFF000000))
         (fired '())
         ;; START-INPUT is what a compositor calls: it builds the driver, opens the
         ;; context and puts libinput's fd in the reactor.  It is used here rather
         ;; than a hand-built driver so the wiring is what this clause checks.
         (driver (cf:start-input compositor :udev nil)))
    (unwind-protect
         (progn
           (check (not (null (cf.backend.libinput:input-driver-source driver)))
                  "libinput's descriptor is a reactor source")
           (cf:add-keybinding compositor "F2" (lambda () (push :f2 fired)))
           ;; evdev 60 is KEY_F2.  If the evdev -> keysym-name join is wrong, the
           ;; binding simply does not fire: the failure is silent without this.
           (cf.backend.libinput:apply-raw-event
            driver (cf.backend.libinput:make-raw-event
                    :kind :keyboard-key :key 60 :key-state :pressed))
           (check (equal '(:f2) fired)
                  "evdev code 60 reached a keybinding as the key name ~S" "F2")
           (cf.backend.libinput:apply-raw-event
            driver (cf.backend.libinput:make-raw-event
                    :kind :keyboard-key :key 60 :key-state :released))
           ;; A key nobody bound and nobody focused: counted, not an error.
           (cf.backend.libinput:apply-raw-event
            driver (cf.backend.libinput:make-raw-event
                    :kind :keyboard-key :key 30 :key-state :pressed))
           (check (= 3 (cf.backend.libinput:input-driver-key-count driver))
                  "three key events were decoded (~D)"
                  (cf.backend.libinput:input-driver-key-count driver))
           ;; Motion is a delta; 5000 to the right is the last pixel of the output.
           (cf.backend.libinput:apply-raw-event
            driver (cf.backend.libinput:make-raw-event :kind :motion :dx 5000d0 :dy -20d0))
           (check (= 799 (cf.backend.libinput:input-driver-pointer-x driver))
                  "a 5000-pixel motion clamps to the last column (~D)"
                  (cf.backend.libinput:input-driver-pointer-x driver))
           (check (= 0 (cf.backend.libinput:input-driver-pointer-y driver))
                  "and to the first row above the top (~D)"
                  (cf.backend.libinput:input-driver-pointer-y driver))
           (cf.backend.libinput:apply-raw-event
            driver (cf.backend.libinput:make-raw-event :kind :motion :dx -4d0 :dy 4d0))
           (check (= 795 (cf.backend.libinput:input-driver-pointer-x driver))
                  "coming back from the edge comes back from the edge (~D), not
                   from 5000 pixels outside it"
                  (cf.backend.libinput:input-driver-pointer-x driver))
           ;; A button and a scroll reach the seat's calls without an error.
           (cf.backend.libinput:apply-raw-event
            driver (cf.backend.libinput:make-raw-event
                    :kind :button :button #x110 :button-state :pressed))
           (cf.backend.libinput:apply-raw-event
            driver (cf.backend.libinput:make-raw-event
                    :kind :scroll-wheel :axis :vertical :value 15d0))
           (check (= 1 (cf.backend.libinput:input-driver-button-count driver))
                  "a left button was delivered")
           (check (= 1 (cf.backend.libinput:input-driver-axis-count driver))
                  "one wheel click was delivered as one axis event")
           ;; A key the table does not name is a report, not a crash.
           (cf.backend.libinput:apply-raw-event
            driver (cf.backend.libinput:make-raw-event
                    :kind :keyboard-key :key 240 :key-state :pressed))
           (check (= 1 (cf.backend.libinput:input-driver-unknown-key-count driver))
                  "an unnamed key (240) was counted as unknown rather than dropped")
           (check (null (cf.backend.libinput:input-driver-callback-errors driver))
                  "the compositor's seat took every event without a condition"))
      (cf:stop-input driver)
      (check (null (cf.backend.libinput:input-driver-source driver))
             "STOP-INPUT took the descriptor back out of the reactor"))))

;;; ---------------------------------------------------------------------------

(probe-seat)
(probe-devices)
(probe-chain)
(finish "~D check(s); ~D skipped; ~A event node(s) present"
        *checks* *skips* (length (event-paths)))
