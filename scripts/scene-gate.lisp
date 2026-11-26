;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The scene v0 gate: two real clients, placement, hit testing, click to focus,
;;;; and a cursor drawn where the pointer is.
;;;;
;;;; Run by scripts/scene-gate.sh.  The environment carries WESTON_CLIENT (a
;;;; system binary, run twice) and FRAME_PNG.
;;;;
;;;; Why two instances of weston-simple-shm rather than one client twice: each
;;;; maps its own xdg_toplevel on its own connection, so "which window did the
;;;; click focus" is a question about two independent clients with their own
;;;; libwayland, not about one client's internal state.  Every assertion below is
;;;; something a person could check by looking at the screen:
;;;;
;;;;   * the first window is placed at (0,0) and the second at (32,32) -- a
;;;;     cascade, not two windows in the same place;
;;;;   * the pointer is over window A and the seat says so, while the *keyboard*
;;;;     is still on B: a hover is not a click;
;;;;   * clicking A moves the keyboard to A and tells both toplevels: A is
;;;;     configured activated and B is configured not activated;
;;;;   * clicking B moves it back;
;;;;   * both windows are actually drawn where they were placed;
;;;;   * the cursor's own pixels -- an opaque black tip and an opaque white body
;;;;     -- are in the frame at the pointer's position, because it is composited
;;;;     last and over whatever is underneath.
;;;;
;;;; The windows' content is checked at one pixel each, because a placement that
;;;; puts a window where nothing is drawn would pass every hit-test assertion
;;;; above while showing the user a blank screen.

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defparameter *background* #xFF000000 "Opaque black: nothing drawn there.")
(defparameter *cursor-tip* #xFF000000 "The arrow's top-left pixel: opaque black.")
(defparameter *cursor-body* #xFFFFFFFF "The arrow's (1,3) pixel: opaque white.")

(defun resources-of-type (compositor type)
  (loop for client in (wayland.server:display-clients (cf:compositor-display compositor))
        append (remove-if-not (lambda (resource) (typep resource type))
                              (wayland.server:client-resources client))))

(defun window-toplevel (surface)
  "The xdg_toplevel SURFACE draws through, or NIL."
  (let ((shell (and surface (wayland.server:surface-shell-surface surface))))
    (and shell (wayland.server:xdg-surface-role shell))))

(defun mapped-windows (compositor)
  "Every mapped toplevel as (CONS TOPLEVEL SURFACE), in no particular order.

Order is not used anywhere below on purpose: two clients choose their own object
ids, so the only thing that identifies a window here is where the compositor put
it -- which is exactly what this gate is about."
  (loop for toplevel in (resources-of-type compositor 'wayland.server:xdg-toplevel)
        for shell = (wayland.server:xdg-toplevel-shell-surface toplevel)
        for surface = (and shell (wayland.server:xdg-surface-surface shell))
        when (and surface
                  (wayland.server:surface-mapped-p surface)
                  (wayland.server:surface-current-buffer surface))
          collect (cons toplevel surface)))

(defun window-at (compositor x y)
  "The window whose scene node is at (X, Y), or NIL."
  (loop for window in (mapped-windows compositor)
        for node = (cf:surface-scene-node (cdr window))
        when (and node (= x (cf.scene:node-x node)) (= y (cf.scene:node-y node)))
          return window))

(defun pump-until (compositor predicate seconds)
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display compositor)))
    (loop
      (let ((value (funcall predicate)))
        (when value (return value))
        (when (> (get-internal-real-time) deadline)
          (return nil))
        (wayland.server:run-once display :timeout 0.01)))))

(defun pump (compositor seconds)
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display compositor)))
    (loop until (> (get-internal-real-time) deadline)
          do (wayland.server:run-once display :timeout 0.01))))

(defun activated-p (toplevel)
  (and toplevel
       (member wayland.server:+xdg-toplevel-state-activated+
               (wayland.server:xdg-toplevel-configure-states toplevel))))

(let* ((client (or (uiop:getenv "WESTON_CLIENT")
                   (error "WESTON_CLIENT is not set")))
       (png (or (uiop:getenv "FRAME_PNG") "/tmp/cl-wayland-scene.png"))
       (compositor (cf:make-headless-compositor :width 512 :height 512
                                                :background *background*))
       (display (cf:compositor-display compositor))
       (seat (cf:compositor-seat compositor))
       (processes '())
       (ok t))

  (flet ((fail (control &rest arguments)
           (setf ok nil)
           (format t "  FAIL ~?~%" control arguments))
         (start-client (label)
           (let ((process (sb-ext:run-program client nil :wait nil
                                                         :output t :error t)))
             (push process processes)
             (format t "client ~A: pid ~D~%" label (sb-ext:process-pid process))
             process)))

    (unwind-protect
         (progn
           (format t "compositor: 512x512 headless, socket ~A~%"
                   (wayland.server:display-socket-path display))

           ;; 1. Two windows, placed by the cascade, each drawn from its own buffer.
           (start-client "A")
           (unless (pump-until compositor
                               (lambda () (= 1 (length (mapped-windows compositor))))
                               20)
             (fail "window A never mapped"))
           (start-client "B")
           (unless (pump-until compositor
                               (lambda () (= 2 (length (mapped-windows compositor))))
                               20)
             (fail "window B never mapped"))

           (let* ((a (window-at compositor 0 0))
                  (b (window-at compositor 32 32)))
             (cond
               ((or (null a) (null b))
                (fail "the two windows are not at (0,0) and (32,32): ~S"
                      (loop for window in (mapped-windows compositor)
                            for node = (cf:surface-scene-node (cdr window))
                            collect (multiple-value-list (cf.scene:node-position node)))))
               (t
                (let* ((node-a (cf:surface-scene-node (cdr a)))
                       (node-b (cf:surface-scene-node (cdr b)))
                       (aw (cf.scene:node-width node-a)) (ah (cf.scene:node-height node-a))
                       (bw (cf.scene:node-width node-b)) (bh (cf.scene:node-height node-b)))
                  (format t "window A: node at (0,0), buffer ~Dx~D~%" aw ah)
                  (format t "window B: node at (32,32), buffer ~Dx~D~%" bw bh)
                  (unless (and (plusp aw) (plusp ah) (plusp bw) (plusp bh))
                    (fail "a window has a zero-sized buffer"))

                  ;; 2. Focus on map: B mapped last, so B has the keyboard.
                  (if (eq (wayland.server:seat-keyboard-focus seat) (cdr b))
                      (format t "focus: window B took the keyboard when it mapped~%")
                      (fail "the keyboard is on ~S, not on the window that mapped last"
                            (wayland.server:seat-keyboard-focus seat)))

                  ;; 3. Hover A: the pointer enters A, the keys stay with B.
                  (cf:inject-pointer-motion compositor 5 5)
                  (pump compositor 0.1)
                  (if (eq (wayland.server:seat-pointer-focus seat) (cdr a))
                      (format t "hover: pointer focus moved to window A at (5,5)~%")
                      (fail "the pointer is on ~S, not on the window under it"
                            (wayland.server:seat-pointer-focus seat)))
                  (unless (eq (wayland.server:seat-keyboard-focus seat) (cdr b))
                    (fail "a hover stole the keyboard from window B"))

                  ;; 4. Click A: click-to-focus, and the configure says so.
                  (cf:inject-pointer-button compositor :left :pressed)
                  (cf:inject-pointer-button compositor :left :released)
                  (pump compositor 0.2)
                  (let ((a (window-at compositor 0 0))
                        (b (window-at compositor 32 32)))
                    (if (eq (wayland.server:seat-keyboard-focus seat) (cdr a))
                        (format t "click: the keyboard moved to window A~%")
                        (fail "clicking A left the keyboard on ~S"
                              (wayland.server:seat-keyboard-focus seat)))
                    (unless (activated-p (car a))
                      (fail "window A was not configured activated after the click"))
                    (when (activated-p (car b))
                      (fail "window B is still configured activated after losing focus"))
                    (format t "configure: A activated ~S, B activated ~S~%"
                            (activated-p (car a)) (activated-p (car b))))

                  ;; 5. Click B, at a point inside B and covered by both.
                  (cf:inject-pointer-motion compositor 37 37)
                  (pump compositor 0.1)
                  (if (eq (wayland.server:seat-pointer-focus seat) (cdr b))
                      (format t "hover: pointer focus moved back to window B~%")
                      (fail "the pointer is on ~S, not on window B"
                            (wayland.server:seat-pointer-focus seat)))
                  (cf:inject-pointer-button compositor :left :pressed)
                  (cf:inject-pointer-button compositor :left :released)
                  (pump compositor 0.2)
                  (let ((a (window-at compositor 0 0))
                        (b (window-at compositor 32 32)))
                    (unless (eq (wayland.server:seat-keyboard-focus seat) (cdr b))
                      (fail "clicking B left the keyboard on ~S"
                            (wayland.server:seat-keyboard-focus seat)))
                    (unless (activated-p (car b))
                      (fail "window B was not configured activated after the click"))
                    (when (activated-p (car a))
                      (fail "window A is still configured activated after losing focus"))
                    (format t "configure: A activated ~S, B activated ~S~%"
                            (activated-p (car a)) (activated-p (car b))))

                  ;; 6. Hit testing directly: A alone, B alone, the bare output.
                  (let ((scene (cf:compositor-scene compositor)))
                    (multiple-value-bind (node x y) (cf.scene:scene-hit-test scene 5 5)
                      (declare (ignore x y))
                      (unless (eq node (cf:surface-scene-node (cdr a)))
                        (fail "hit test at (5,5) found ~S, not window A's node" node)))
                    (multiple-value-bind (node x y) (cf.scene:scene-hit-test scene 37 37)
                      (declare (ignore x y))
                      (unless (eq node (cf:surface-scene-node (cdr b)))
                        (fail "hit test at (37,37) found ~S, not window B's node" node)))
                    (multiple-value-bind (node x y) (cf.scene:scene-hit-test scene 500 500)
                      (declare (ignore x y))
                      (if (null node)
                          (format t "hit test: (500,500) is the bare output~%")
                          (fail "something is hit at (500,500): ~S" node))))

                  ;; 7. Pixels: both windows are drawn where they were placed, and
                  ;;    the cursor is on top of whatever is under it.
                  (cf:render-frame compositor)
                  (let ((inside-a (cf:frame-pixel compositor 5 5))
                        (inside-b (cf:frame-pixel compositor 72 72)))
                    (unless (/= inside-a *background*)
                      (fail "window A's area is background at (5,5)"))
                    (unless (/= inside-b *background*)
                      (fail "window B's area is background at (72,72)"))
                    (format t "pixels: A at (5,5) = #x~8,'0X, B at (72,72) = #x~8,'0X~%"
                            inside-a inside-b))
                  (let ((cx (cf:compositor-cursor-x compositor))
                        (cy (cf:compositor-cursor-y compositor)))
                    (unless (and (= cx 37) (= cy 37))
                      (fail "the cursor is at (~D,~D), not where the pointer was injected"
                            cx cy))
                    (if (= *cursor-tip* (cf:frame-pixel compositor cx cy))
                        (format t "cursor: black tip at (~D,~D)~%" cx cy)
                        (fail "the cursor tip at (~D,~D) is #x~8,'0X, not #x~8,'0X"
                              cx cy (cf:frame-pixel compositor cx cy) *cursor-tip*))
                    (if (= *cursor-body* (cf:frame-pixel compositor (+ cx 1) (+ cy 3)))
                        (format t "cursor: white body at (~D,~D)~%"
                                (+ cx 1) (+ cy 3))
                        (fail "the cursor body at (~D,~D) is #x~8,'0X, not #x~8,'0X"
                              (+ cx 1) (+ cy 3)
                              (cf:frame-pixel compositor (+ cx 1) (+ cy 3))
                              *cursor-body*)))))))

           (cf:write-frame-png compositor png)
           (format t "screenshot: ~A~%" png)
           (format t "frames rendered: ~D over ~D window(s)~%"
                   (cf:compositor-frame-count compositor)
                   (length (cf:compositor-surfaces compositor))))

      ;; Stop both clients, then prove the teardown left nothing behind.
      (dolist (process processes)
        (when (sb-ext:process-alive-p process)
          (ignore-errors (sb-ext:process-kill process 15))))
      (pump-until compositor
                  (lambda () (notany #'sb-ext:process-alive-p processes))
                  5)
      (dolist (process processes)
        (ignore-errors (sb-ext:process-close process)))
      (pump compositor 0.2)
      (let ((left (length (wayland.server:display-clients display))))
        (if (zerop left)
            (format t "teardown: no clients, no objects left~%")
            (fail "~D client(s) still connected after the clients exited" left)))
      (wayland.server:close-display display)
      (format t "~&~:[FAILED~;PASSED~]~%" ok)
      (uiop:quit (if ok 0 1)))))
