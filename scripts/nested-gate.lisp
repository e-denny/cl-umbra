;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The phase-3 nested gate (clause 15): a real client inside a real nested
;;;; session, inside our own compositor, in one image and two sockets.
;;;;
;;;; Run by scripts/nested-gate.sh.  The environment carries NESTED_CLIENT
;;;; (normally weston-eventdemo) and FRAME_PNG.
;;;;
;;;; The picture, from the inside out:
;;;;
;;;;   weston-eventdemo  --(wayland)-->  nested compositor  --(wayland)-->  parent
;;;;        real client                  our compositor,             our compositor,
;;;;                                    our client library          headless 256x256
;;;;
;;;; Every arrow is a real socket with real messages, and the two compositors are
;;;; the same image.  What each assertion proves:
;;;;
;;;;   1. the parent sees our nested output as an ordinary xdg_toplevel: mapped,
;;;;      titled, activated -- so surface creation, the xdg handshake, shm pools and
;;;;      buffers, attach/commit and the parent-side input region all work;
;;;;   2. the parent's pixels equal the nested compositor's own target over a grid
;;;;      of points -- so the frame was rendered *into the parent's buffer*, not
;;;;      merely committed;
;;;;   3. a pointer motion injected into the parent arrives in the nested session
;;;;      as a motion at the same coordinates, printed by the client;
;;;;   4. a key injected into the parent arrives as the same key, with the same
;;;;      modifier state, printed by the client (the evdev code was translated to a
;;;;      key name and back through our own keymap);
;;;;   5. the parent sent a keymap descriptor to our client and it was read;
;;;;   6. closing the nested session removes the parent's toplevel and leaves no
;;;;      clients behind.
;;;;
;;;; The parent's pointer is parked in a corner before the pixel comparison: the
;;;; parent draws its own cursor into the frame, and that cursor is genuinely not
;;;; part of the nested output.

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defparameter *background* #xFF000000)
(defparameter *parent-pointer-x* 240)
(defparameter *parent-pointer-y* 240)

(defvar *client-lines* '()
  "Lines the nested client printed so far, oldest first.")

(defun fd-count ()
  (length (directory #p"/proc/self/fd/*")))

(defun resources-of-type (compositor type)
  (loop for client in (wayland.server:display-clients (cf:compositor-display compositor))
        append (remove-if-not (lambda (resource) (typep resource type))
                              (wayland.server:client-resources client))))

(defun parent-frame-has-content-p (compositor)
  "Some pixel of the parent's frame is not the background colour.

Scans inside (0,0)-(192,192), which excludes the parent's own cursor (parked at
240,240): the cursor is drawn by the parent and is deliberately not part of the
nested output, so it must not be able to satisfy this check."
  (loop for y from 0 below 192 by 8
        thereis (loop for x from 0 below 192 by 8
                      thereis (/= (cf:frame-pixel compositor x y) *background*))))

(defun drain-pty (pty)
  (loop while (and pty (listen pty))
        do (let ((line (read-line pty nil nil)))
             (when line
               (setf *client-lines* (append *client-lines* (list line)))))))

(defun pump-world (parent nested pty seconds &key until)
  "Advance every loop in this image until UNTIL is true or SECONDS pass.

Three reactors: the parent's, the nested compositor's, and the parent connection the
nested backend holds.  The client's pty is drained every iteration, because its
output is the evidence for the input assertions."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop
      (let ((value (and until (funcall until))))
        (when value
          (return value)))
      (when (> (get-internal-real-time) deadline)
        (return nil))
      (cf:nested-dispatch nested :timeout 0)
      (wayland.server:run-once (cf:compositor-display parent) :timeout 0.005)
      (drain-pty pty))))

(defun wait-for-line (parent nested pty needle seconds)
  (or (find needle *client-lines* :test #'search)
      (pump-world parent nested pty seconds
                  :until (lambda () (find needle *client-lines* :test #'search)))))

(let* ((client (or (uiop:getenv "NESTED_CLIENT")
                   (error "NESTED_CLIENT is not set")))
       (png (or (uiop:getenv "FRAME_PNG") "/tmp/cl-wayland-nested.png"))
       (runtime-dir (uiop:getenv "XDG_RUNTIME_DIR"))
       (fds-before (fd-count))
       (parent (cf:make-headless-compositor :width 256 :height 256
                                            :display-name "nested-parent"
                                            :runtime-dir runtime-dir
                                            :background *background*))
       (parent-display (cf:compositor-display parent))
       (parent-socket (wayland.server:display-socket-path parent-display))
       (nested nil)
       (process nil)
       (pty nil)
       (ok t))

  (labels ((fail (control &rest arguments)
             (setf ok nil)
             (format t "  FAIL ~?~%" control arguments))
           (expect-line (needle &key (seconds 8))
             (let ((line (wait-for-line parent nested pty needle seconds)))
               (if line
                   (format t "  ok   client printed: ~A~%"
                           (string-trim '(#\Return #\Newline) line))
                   (fail "the client never printed ~S" needle))
               line)))

    (unwind-protect
         (progn
           (format t "parent: 256x256 headless, socket ~A~%" parent-socket)
           (setf nested (cf:start-nested
                         :parent-path parent-socket
                         :width 256 :height 256
                         :display-name "nested-child"
                         :runtime-dir runtime-dir
                         ;; In this image the parent must be pumped by us; in a real
                         ;; session the parent is another process and this is nil.
                         :pump (lambda (seconds)
                                 (wayland.server:run-once parent-display
                                                          :timeout seconds))))
           (let ((nested-display (cf:compositor-display (cf:nested-compositor nested))))
             (format t "nested: 256x256, socket ~A~%"
                     (wayland.server:display-socket-path nested-display))
             (format t "parent saw: ~D toplevel~:P~%"
                     (length (resources-of-type parent 'wayland.server:xdg-toplevel))))

           ;; 1. The parent sees an ordinary window, focused, with our title.
           ;;    The first commit is scheduled by START-NESTED and happens on the
           ;;    nested reactor's next idle, so wait for the map instead of
           ;;    assuming it.
           (unless (pump-world parent nested nil 10
                               :until (lambda ()
                                        (find-if (lambda (r)
                                                   (wayland.server:xdg-toplevel-mapped-p r))
                                                 (resources-of-type
                                                  parent 'wayland.server:xdg-toplevel))))
             (fail "the parent never mapped our nested toplevel"))
           (let ((toplevel (find-if (lambda (r) (wayland.server:xdg-toplevel-mapped-p r))
                                    (resources-of-type parent 'wayland.server:xdg-toplevel))))
             (cond
               ((null toplevel)
                (fail "the parent never mapped our nested toplevel"))
               (t
                (format t "parent toplevel: title ~S, app-id ~S, states ~S~%"
                        (wayland.server:xdg-toplevel-title toplevel)
                        (wayland.server:xdg-toplevel-app-id toplevel)
                        (wayland.server:xdg-toplevel-configure-states toplevel))
                (unless (equal (wayland.server:xdg-toplevel-title toplevel)
                               "cl-umbra nested")
                  (fail "the parent did not receive our title"))
                (unless (equal (wayland.server:xdg-toplevel-app-id toplevel)
                               "cl-umbra")
                  (fail "the parent did not receive our app-id"))
                (unless (member wayland.server:+xdg-toplevel-state-activated+
                                (wayland.server:xdg-toplevel-configure-states toplevel))
                  (fail "the parent did not activate our nested window"))
                (unless (eq (wayland.server:seat-keyboard-focus
                             (cf:compositor-seat parent))
                            (wayland.server:xdg-surface-surface
                             (wayland.server:xdg-toplevel-shell-surface toplevel)))
                  (fail "the parent's keyboard focus is not our nested surface")))))

           ;; 3. The client inside the nested session draws and takes the keyboard.
           (setf process (sb-ext:run-program
                          client
                          (list "--log-key" "--log-button" "--log-motion"
                                "--log-focus" "--width" "200" "--height" "150")
                          :wait nil :pty t
                          :environment
                          (list (format nil "WAYLAND_DISPLAY=nested-child")
                                (format nil "XDG_RUNTIME_DIR=~A" runtime-dir)
                                "HOME=/tmp"
                                "PATH=/usr/local/bin:/usr/bin:/bin")))
           (setf pty (sb-ext:process-pty process))
           (format t "nested client: ~A (pid ~D)~%"
                   client (sb-ext:process-pid process))
           (unless (pump-world parent nested pty 20
                               :until (lambda ()
                                        (find-if (lambda (r) (wayland.server:xdg-toplevel-mapped-p r))
                                                 (resources-of-type
                                                  (cf:nested-compositor nested)
                                                  'wayland.server:xdg-toplevel))))
             (fail "the client never mapped a window inside the nested session"))
           ;; The client's window is the nested output's first toplevel: (0,0).
           (pump-world parent nested pty 1.0)

           ;; 2. Frames actually cross: the parent's buffer holds what we drew.
           ;;    Parked first, because the parent draws its own cursor into its
           ;;    frame and that cursor is not part of the nested output.
           (cf:inject-pointer-motion parent *parent-pointer-x* *parent-pointer-y*)
           (unless (pump-world parent nested pty 10
                               :until (lambda ()
                                        (and (cf:nested-mapped-p nested)
                                             (>= (cf:nested-frame-count nested) 2)
                                             (parent-frame-has-content-p parent))))
             (fail "the nested session never presented a drawn frame to the parent"))
           (pump-world parent nested pty 0.3)
           (let* ((inner (cf:nested-compositor nested))
                  (points '((20 20) (100 100) (200 40) (60 200) (150 150)))
                  (mismatches 0)
                  (lit 0))
             (format t "frames presented to the parent: ~D~%"
                     (cf:nested-frame-count nested))
             (dolist (point points)
               (destructuring-bind (x y) point
                 (let ((parent-pixel (cf:frame-pixel parent x y))
                       (nested-pixel (cf:frame-pixel inner x y)))
                   (unless (= parent-pixel nested-pixel)
                     (incf mismatches)
                     (format t "  FAIL pixel (~D,~D): parent #x~8,'0X, nested #x~8,'0X~%"
                             x y parent-pixel nested-pixel))
                   (unless (= parent-pixel *background*)
                     (incf lit)))))
             (format t "pixel grid: ~D/~D points equal, ~D of them non-background~%"
                     (- (length points) mismatches) (length points) lit)
             (when (plusp mismatches)
               (fail "the parent's frame is not the nested compositor's frame"))
             (when (zerop lit)
               (fail "the parent frame is entirely background: nothing was presented"))
             (cf:write-frame-png parent png))

           ;; 4. Parent pointer -> nested client.  Two motions for the same reason
           ;; the seat gate needs two: the first enters, the second is a motion.
           (cf:inject-pointer-motion parent 50 60)
           (expect-line "focus x: 0, y: 0")
           (cf:inject-pointer-motion parent 50 60)
           (expect-line "motion time: ")
           (expect-line "x: 50.000000, y: 60.000000")

           ;; 5. Parent keys -> nested client, through both keymaps.
           (cf:inject-key parent "Shift_L" :pressed)
           (cf:inject-key parent "q" :pressed)
           (cf:inject-key parent "q" :released)
           (cf:inject-key parent "Shift_L" :released)
           (expect-line "key key: 16, unicode: 81, state: pressed, modifiers: 0x1")

           ;; 6. What crossed the boundary, counted rather than inferred.
           (format t "parent -> nested: ~D pointer event~:P, ~D key~:P, keymap ~D octets~%"
                   (cf:nested-pointer-event-count nested)
                   (cf:nested-key-count nested)
                   (cf:nested-parent-keymap-size nested))
           (unless (plusp (cf:nested-pointer-event-count nested))
             (fail "no pointer events crossed from the parent"))
           (unless (plusp (cf:nested-key-count nested))
             (fail "no key events crossed from the parent"))
           (unless (plusp (cf:nested-parent-keymap-size nested))
             (fail "the parent's keymap descriptor was never received"))

           ;; 7. Teardown: the parent's window goes away and its client list empties.
           (cf:stop-nested nested)
           ;; The nested display is closed now; only the parent's reactor can run.
           (pump-world parent nested nil 5
                       :until (lambda ()
                                (null (wayland.server:display-clients parent-display))))
           (let ((toplevels (resources-of-type parent 'wayland.server:xdg-toplevel)))
             (if toplevels
                 (fail "the parent still has ~D toplevel(s) after teardown"
                       (length toplevels))
                 (format t "teardown: the parent's toplevel is gone~%"))))

      ;; Always: stop the client, close both displays, drain what it printed.
      (when (and process (sb-ext:process-alive-p process))
        (ignore-errors (sb-ext:process-kill process 15)))
      (when nested
        (ignore-errors (cf:stop-nested nested)))
      (ignore-errors (wayland.server:close-display parent-display))
      (when pty
        (ignore-errors
          (loop repeat 50
                do (sleep 0.01)
                   (drain-pty pty))))
      (when process
        (ignore-errors (sb-ext:process-close process)))
      (let ((after (fd-count)))
        (if (<= after fds-before)
            (format t "descriptors: ~D before, ~D after~%" fds-before after)
            (fail "descriptors leaked: ~D before, ~D after" fds-before after))))

    (format t "~:[FAILED~;PASSED~]: nested session~%" ok)
    (uiop:quit (if ok 0 1))))
