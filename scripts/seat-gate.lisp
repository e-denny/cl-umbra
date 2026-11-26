;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The phase-3b gate: seats and input, checked against a real client that prints
;;;; what it received.
;;;;
;;;; Run by scripts/seat-gate.sh.  The environment carries SEAT_CLIENT (normally
;;;; weston-eventdemo), KEYMAP_FILE (where to dump the keymap we actually sent, so
;;;; a C probe can parse it with libxkbcommon) and FRAME_PNG.
;;;;
;;;; Why `weston-eventdemo --log-key --log-button --log-motion --log-axis`:
;;;; it prints, from the client's own xkb state, the *unicode* code point and the
;;;; modifier mask of every key, the surface-local coordinates of every motion
;;;; event, the button code, and scroll values.  So the assertions below are not
;;;; "we called a function": each one is a number that could only be printed if the
;;;; whole chain worked --
;;;;
;;;;   keycode and keymap travel correctly (16 -> 'Q', not something else);
;;;;   the keymap's two-level types and its `interpret Shift` rules work in the
;;;;     client's xkb state (Shift+q is uppercase Q = 81);
;;;;   our `wl_keyboard.modifiers` agrees with that state (mask 0x1);
;;;;   repeat_info arrived before the first key (else weston's own repeat setup
;;;;     would not have run);
;;;;   enter/leave, motion, button and axis reached the focused surface, with the
;;;;     coordinates we injected.
;;;;
;;;; The client is run on a pty so its stdio is line-buffered and its lines can be
;;;; read as they appear -- no stdbuf, no LD_PRELOAD, no waiting for exit.

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defparameter *background* #xFF000000)

(defvar *client-lines* '()
  "Lines the client printed so far, oldest first.")

(defun fd-count ()
  (length (directory #p"/proc/self/fd/*")))

(defun resources-of-type (compositor type)
  (loop for client in (wayland.server:display-clients (cf:compositor-display compositor))
        append (remove-if-not (lambda (resource) (typep resource type))
                              (wayland.server:client-resources client))))

(defun pump (compositor pty until seconds)
  "Run the compositor until UNTIL returns true or SECONDS pass.

Every iteration drains the client's pty, because the client's output *is* the
evidence: refusing to read it while waiting for it would be a deadlock with extra
steps."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display compositor)))
    (loop
      (let ((value (and until (funcall until))))
        (when value
          (return value))
        (when (> (get-internal-real-time) deadline)
          (return nil))
        (wayland.server:run-once display :timeout 0.01)
        (loop while (and pty (listen pty))
              do (let ((line (read-line pty nil nil)))
                   (when line
                     (setf *client-lines*
                           (append *client-lines* (list line))))))))))

(defun wait-for-line (compositor pty needle seconds)
  "Wait until the client printed a line containing NEEDLE; return the line."
  (or (find needle *client-lines* :test #'search)
      (pump compositor pty
            (lambda () (find needle *client-lines* :test #'search))
            seconds)))

(let* ((client (or (uiop:getenv "SEAT_CLIENT")
                   (error "SEAT_CLIENT is not set")))
       (keymap-file (or (uiop:getenv "KEYMAP_FILE") "/tmp/cl-wayland-keymap.xkb"))
       (png (or (uiop:getenv "FRAME_PNG") "/tmp/cl-wayland-seat.png"))
       ;; Measured before the compositor exists, so its own descriptors cancel
       ;; against their closing later; a leaked keymap descriptor does not.
       (fds-before (fd-count))
       (compositor (cf:make-headless-compositor :width 256 :height 256
                                                :background *background*))
       (display (cf:compositor-display compositor))
       (seat (cf:compositor-seat compositor))
       (process nil)
       (pty nil)
       (ok t))

  (labels ((fail (control &rest arguments)
           (setf ok nil)
           (format t "  FAIL ~?~%" control arguments))
         (expect-line (needle &key (seconds 5))
           (let ((line (wait-for-line compositor pty needle seconds)))
             (if line
                 (format t "  ok   client printed: ~A~%" (string-trim '(#\Return) line))
                 (fail "the client never printed ~S" needle))
             line)))

    (unwind-protect
         (progn
           (format t "compositor: 256x256 headless, socket ~A~%"
                   (wayland.server:display-socket-path display))
           (format t "client: ~A~%" client)
           (setf process (sb-ext:run-program client
                                             (list "--log-key" "--log-button"
                                                   "--log-motion" "--log-axis"
                                                   "--log-focus"
                                                   "--width" "200" "--height" "150")
                                             :wait nil :pty t)
                 pty (sb-ext:process-pty process))

           ;; 1. The client maps a window; focus follows the map (our policy).
           (let ((toplevel (pump compositor pty
                                 (lambda ()
                                   (find-if (lambda (r)
                                              (wayland.server:xdg-toplevel-mapped-p r))
                                            (resources-of-type
                                             compositor
                                             'wayland.server:xdg-toplevel)))
                                 20)))
             (if (null toplevel)
                 (fail "no toplevel mapped within 20 s")
                 (progn
                   ;; 2. The seat's own view.
                   (format t "seat ~A: capabilities ~D, keymap ~D octets, ~D binding~:P~%"
                           (wayland.server:seat-name seat)
                           (wayland.server:seat-capabilities seat)
                           (length (wayland.server:seat-keymap seat))
                           (length (wayland.server:seat-bindings seat)))
                   (unless (= (logior wayland.server:+wl-seat-capability-pointer+
                                      wayland.server:+wl-seat-capability-keyboard+)
                              (wayland.server:seat-capabilities seat))
                     (fail "capabilities ~D are not pointer|keyboard"
                           (wayland.server:seat-capabilities seat)))
                   (unless (wayland.server:seat-keyboard-focus seat)
                     (fail "the mapped toplevel did not take keyboard focus"))
                   (let ((keyboards (resources-of-type compositor 'wayland.server:keyboard))
                         (pointers (resources-of-type compositor 'wayland.server:pointer)))
                     (format t "client objects: ~D keyboard~:P, ~D pointer~:P~%"
                             (length keyboards) (length pointers))
                     (unless keyboards (fail "the client created no wl_keyboard"))
                     (unless pointers (fail "the client created no wl_pointer"))
                     (dolist (keyboard keyboards)
                       (unless (eq (wayland.server:keyboard-surface keyboard)
                                   (wayland.server:seat-keyboard-focus seat))
                         (fail "keyboard ~D did not get enter for the focused surface"
                               (wayland.server:resource-id keyboard)))))

                   ;; 3. The toplevel was activated by the focus change.
                   (format t "toplevel ~D: configure ~D, states ~S~%"
                           (wayland.server:resource-id toplevel)
                           (wayland.server:xdg-toplevel-configure-count toplevel)
                           (wayland.server:xdg-toplevel-configure-states toplevel))
                   (unless (member wayland.server:+xdg-toplevel-state-activated+
                                   (wayland.server:xdg-toplevel-configure-states toplevel))
                     (fail "the focused toplevel was never configured as activated"))
                   (unless (> (wayland.server:xdg-toplevel-configure-count toplevel) 1)
                     (fail "no second configure was sent on the focus change")))))

           ;; 4. Pointer and keyboard input, in the order a person would make it.
           ;;
           ;; Two motions, because there are two things to prove and they are
           ;; different events: the first *enters* the window (weston-eventdemo
           ;; sets an input region inset by 32 pixels, and it is honoured now --
           ;; D31 -- so (0,0) is not part of the window as far as input goes), and
           ;; the second is the motion event a client sees once it has the
           ;; pointer.
           (cf:inject-pointer-motion compositor 50 60)
           (expect-line "focus x: 0, y: 0")
           (cf:inject-pointer-motion compositor 50 60)
           (expect-line "motion time: ")
           (expect-line "x: 50.000000, y: 60.000000")

           (cf:inject-pointer-button compositor :left :pressed)
           (cf:inject-pointer-button compositor :left :released)
           (expect-line "button: 272, state: pressed, x: 50, y: 60")
           (expect-line "button: 272, state: released, x: 50, y: 60")

           (cf:inject-pointer-axis compositor :vertical 15)
           (expect-line "axis: vertical, value: 15.000000")

           ;; Shift, then q: the client must print unicode 81 ('Q') with the shift
           ;; modifier, which is the keymap and the modifiers event agreeing.
           (cf:inject-key compositor "Shift_L" :pressed)
           (cf:inject-key compositor "q" :pressed)
           (cf:inject-key compositor "q" :released)
           (cf:inject-key compositor "Shift_L" :released)
           (expect-line "key key: 16, unicode: 81, state: pressed, modifiers: 0x1")
           (expect-line "key key: 42, unicode: 65505, state: pressed")

           ;; 5. What we actually sent, for the C probe to parse.
           (with-open-file (stream keymap-file :direction :output
                                               :if-exists :supersede
                                               :external-format :utf-8)
             (write-string (wayland.server:seat-keymap seat) stream))
           (format t "keymap written to ~A~%" keymap-file)
           (cf:write-frame-png compositor png))

      ;; Tell the client to stop, close the display (so it sees EOF even if the
      ;; signal was missed), drain whatever it printed on the way out, and only
      ;; then close the pty: listening on a closed stream is the sort of error
      ;; this ordering exists to avoid.
      (when (and process (sb-ext:process-alive-p process))
        (ignore-errors (sb-ext:process-kill process 15)))
      (wayland.server:close-display display)
      (when pty
        (ignore-errors
          (loop repeat 50
                do (sleep 0.01)
                   (loop while (listen pty)
                         do (let ((line (read-line pty nil nil)))
                              (when line
                                (setf *client-lines*
                                      (append *client-lines* (list line)))))))))
      (when process
        (ignore-errors (sb-ext:process-close process)))
      ;; Measured after everything this script opened has been closed, against a
      ;; count taken before the compositor existed: a leaked keymap descriptor is
      ;; the difference, and every other descriptor cancels.
      (let ((fds-after (fd-count)))
        (if (= fds-before fds-after)
            (format t "descriptors: ~D -> ~D (the keymap fd was closed)~%"
                    fds-before fds-after)
            (progn (setf ok nil)
                   (format t "  FAIL descriptors ~D -> ~D: a keymap fd leaked~%"
                           fds-before fds-after))))
      (when (and (not ok) *client-lines*)
        (format t "~&client printed ~D line(s):~%" (length *client-lines*))
        (dolist (line *client-lines*)
          (format t "  | ~A~%" (string-trim '(#\Return) line))))
      (format t "~&~:[FAILED~;PASSED~]~%" ok)
      (uiop:quit (if ok 0 1)))))
