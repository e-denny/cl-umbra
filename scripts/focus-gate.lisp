;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The focus stack gate (clause 18): three real windows, Alt+Tab, and a window
;;;; closing.
;;;;
;;;; Run by scripts/focus-gate.sh.  The environment carries WESTON_CLIENT (a system
;;;; binary, run three times) and FRAME_PNG.
;;;;
;;;; Why three instances of weston-simple-shm: each maps its own xdg_toplevel on its
;;;; own connection, so "which window has the keyboard" is a question about three
;;;; independent clients with their own libwayland.  Each one is then moved to a
;;;; place of its own (0,0), (150,0), (300,0) in an 800x600 output, so a click can
;;;; name a window unambiguously and the overlaps are there to raise into.
;;;;
;;;; What is asserted, and why each assertion is a real one:
;;;;
;;;;   * the window that mapped last has the keyboard, and the stack says so
;;;;     (C B A)                                           -- map means focus;
;;;;   * Alt+Tab takes the *least* recently focused window   -- the stack is
;;;;     history, not draw order, and the window it chose is also raised (a cycle
;;;;     you cannot see is not a cycle);
;;;;   * four presses visit three windows and wrap           -- a rotating cycle
;;;;     visits every window once, which an MRU toggle cannot;
;;;;   * a click focuses the window under the pointer and moves it to the front of
;;;;     the stack, without raising it                       -- focus is the
;;;;     framework's, raising is the compositor's policy;
;;;;   * closing the focused window gives the keys to the most recently focused
;;;;     window that is left, and takes the closed one out of the stack
;;;;     -- "the window that mapped last" cannot answer this;
;;;;   * with one window left, Alt+Tab is a no-op rather than an error.
;;;;
;;;; The `activated' state in the losing and winning toplevels' last configure is
;;;; checked each time: the keyboard focus and the state array must not drift apart
;;;; (D27), and the state array is the only part of this the *clients* can see.

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defparameter *background* #xFF000000 "Opaque black: nothing drawn there.")
(defvar *failures* 0)

(defun check (value control &rest arguments)
  (if value
      (format t "  ok   ~?~%" control arguments)
      (progn (incf *failures*)
             (format t "  FAIL ~?~%" control arguments)))
  value)

(defun resources-of-type (compositor type)
  (loop for client in (wayland.server:display-clients (cf:compositor-display compositor))
        append (remove-if-not (lambda (resource) (typep resource type))
                              (wayland.server:client-resources client))))

(defun pump (compositor seconds)
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display compositor)))
    (loop until (> (get-internal-real-time) deadline)
          do (wayland.server:run-once display :timeout 0.01))))

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

(defun mapped-pairs (compositor)
  "Every mapped toplevel as (CONS TOPLEVEL SURFACE), newest first."
  (loop for toplevel in (resources-of-type compositor 'wayland.server:xdg-toplevel)
        for shell = (wayland.server:xdg-toplevel-shell-surface toplevel)
        for surface = (and shell (wayland.server:xdg-surface-surface shell))
        when (and surface
                  (wayland.server:surface-mapped-p surface)
                  (wayland.server:surface-current-buffer surface))
          collect (cons toplevel surface)))

(defun activated-p (toplevel)
  "Is the last configure this toplevel got the `activated' one?"
  (member wayland.server:+xdg-toplevel-state-activated+
          (wayland.server:xdg-toplevel-configure-states toplevel)))

(defun focused-surface (compositor)
  (wayland.server:seat-keyboard-focus (cf:compositor-seat compositor)))

(defun stack (compositor)
  (cf:compositor-focus-stack compositor))

(defun top-node-surface (compositor)
  "The surface of the frontmost child of the scene's root, or NIL."
  (let* ((root (cf.scene:scene-root (cf:compositor-scene compositor)))
         (children (cf.scene:node-children root)))
    (let ((node (car (last children))))
      (and (typep node 'cf.scene:buffer-node)
           (cf.scene:buffer-node-surface node)))))

(defun press (compositor key)
  (cf:inject-key compositor key :pressed)
  (cf:inject-key compositor key :released)
  (pump compositor 0.05))

(defun alt-tab (compositor)
  (cf:inject-key compositor "Alt_L" :pressed)
  (cf:inject-key compositor "Tab" :pressed)
  (cf:inject-key compositor "Tab" :released)
  (cf:inject-key compositor "Alt_L" :released)
  (pump compositor 0.05))

(defun click (compositor x y)
  (cf:inject-pointer-motion compositor x y)
  (cf:inject-pointer-button compositor :left :pressed)
  (cf:inject-pointer-button compositor :left :released)
  (pump compositor 0.1))

(let* ((client (or (uiop:getenv "WESTON_CLIENT")
                   (error "WESTON_CLIENT is not set")))
       (log-dir (uiop:getenv "FOCUS_LOG_DIR"))
       (compositor (cf:make-headless-compositor :width 800 :height 600
                                                :background *background*))
       (display (cf:compositor-display compositor))
       (processes '()))
  (flet ((start-client (label)
           (let* ((log (format nil "~A/~A.log" (or log-dir "/tmp") label))
                  ;; One file for both streams: two opens of one path would race
                  ;; (SBCL opens each separately, and the second sees FILE-EXISTS).
                  (process (sb-ext:run-program client nil :wait nil
                                                         :output log :error :output)))
             (push process processes)
             (format t "client ~A: pid ~D, log ~A~%" label
                     (sb-ext:process-pid process) log)
             process)))
    (unwind-protect
         (progn
           (format t "compositor: 800x600 headless, socket ~A~%"
                   (wayland.server:display-socket-path display))

           ;; 1. Three windows, each mapped in turn.  Mapping focuses, so the stack
           ;;    is (C B A) and C has both the keyboard and the activated state.
           (let ((windows '()))
             (loop for label in '("A" "B" "C")
                   for count from 1
                   do (start-client label)
                      (check (pump-until compositor
                                         (lambda () (= count (length (mapped-pairs compositor))))
                                         20)
                             "window ~A mapped" label))
             ;; Give each its own column so a click can name one: 256-pixel buffers
             ;; at (0,0), (150,0) and (300,0) overlap on purpose (raise is visible in
             ;; the scene order) but each has a stretch of its own.
             (setf windows (sort (mapped-pairs compositor) #'<
                                 :key (lambda (pair)
                                        (cf.scene:node-x (cf:surface-scene-node (cdr pair))))))
             (loop for window in windows
                   for x in '(0 150 300)
                   do (cf.scene:set-node-position (cf:surface-scene-node (cdr window)) x 0))
             (cf:request-frame compositor)
             (pump compositor 0.3)
             (destructuring-bind (a b . rest) windows
               (let ((c (first rest)))
                 (format t "windows: A=(0,0) B=(150,0) C=(300,0)~%")
                 (check (eq (cdr c) (focused-surface compositor))
                        "the window that mapped last has the keyboard")
                 (check (equal (list (cdr c) (cdr b) (cdr a)) (stack compositor))
                        "and the stack is (C B A), most recently focused first")
                 (check (activated-p (car c)) "C is configured activated")
                 (check (not (activated-p (car a))) "A is not")
                 (check (not (activated-p (car b))) "B is not")

                 ;; 2. Alt+Tab: the least recently focused window, raised.
                 (alt-tab compositor)
                 (check (eq (cdr a) (focused-surface compositor))
                        "alt+Tab focused the least recently focused window (A)")
                 (check (equal (list (cdr a) (cdr c) (cdr b)) (stack compositor))
                        "and rotated the stack to (A C B)")
                 (check (eq (cdr a) (top-node-surface compositor))
                        "and raised it: the cycle shows what it chose")
                 (check (activated-p (car a)) "A is configured activated")
                 (check (not (activated-p (car c))) "C is not")

                 ;; 3. Three more presses visit every window once and wrap.
                 (alt-tab compositor)
                 (check (eq (cdr b) (focused-surface compositor)) "alt+Tab again focused B")
                 (alt-tab compositor)
                 (check (eq (cdr c) (focused-surface compositor)) "then C")
                 (alt-tab compositor)
                 (check (eq (cdr a) (focused-surface compositor))
                        "and a fourth press wraps back to A")
                 (check (equal (list (cdr a) (cdr c) (cdr b)) (stack compositor))
                        "the stack rotated once per press and is back at A's turn")

                 ;; 4. A click focuses the window under the pointer, and does not
                 ;;    raise it: raising is the compositor's policy, not the
                 ;;    framework's (D31, D45).
                 (let ((before (top-node-surface compositor)))
                   (click compositor 280 10)          ; B's own stretch
                   (check (eq (cdr b) (focused-surface compositor))
                          "a click at (280,10) focused B")
                   (check (equal (list (cdr b) (cdr a) (cdr c)) (stack compositor))
                          "and moved B to the front of the stack")
                   (check (activated-p (car b)) "B is configured activated")
                   (check (not (activated-p (car a))) "A is not")
                   (check (eq before (top-node-surface compositor))
                          "and the click did not raise B (the framework does not)"))

                 ;; 5. The focused window closes: the keys go to the next in the
                 ;;    history, and the closed window leaves it.
                 (wayland.server:close-toplevel (car b))
                 (check (pump-until compositor
                                    (lambda ()
                                      (not (member (cdr b) (mapcar #'cdr (mapped-pairs compositor)))))
                                    15)
                        "the focused window's client closed and its window unmapped")
                 (pump compositor 0.3)
                 (check (eq (cdr a) (focused-surface compositor))
                        "and the keys went to the next window in the history (A)")
                 (check (equal (list (cdr a) (cdr c)) (stack compositor))
                        "the closed window is out of the stack")
                 (check (activated-p (car a)) "A is configured activated")
                 (check (null (cf:surface-scene-node (cdr b)))
                        "and its scene node is gone")

                 ;; 6. Two windows left: Alt+Tab toggles between them.
                 (alt-tab compositor)
                 (check (eq (cdr c) (focused-surface compositor))
                        "alt+Tab with two windows focuses the other one")
                 (alt-tab compositor)
                 (check (eq (cdr a) (focused-surface compositor))
                        "and again toggles back")

                 ;; 7. One window left: nothing to cycle to, and no error.
                 (wayland.server:close-toplevel (car c))
                 (pump-until compositor
                             (lambda ()
                               (not (member (cdr c) (mapcar #'cdr (mapped-pairs compositor)))))
                             15)
                 (pump compositor 0.3)
                 (check (eq (cdr a) (focused-surface compositor)) "A still has the keys")
                 (check (eq (cdr a) (cf:focus-stack-cycle compositor))
                        "alt+Tab with one window focuses it again")
                 (check (equal (list (cdr a)) (stack compositor))
                        "and the stack holds exactly that window"))))

           (check (every (lambda (process) (sb-ext:process-alive-p process))
                         (remove-if-not (lambda (process)
                                          (sb-ext:process-alive-p process))
                                        processes))
                  "the remaining client is still connected"))
      (dolist (process processes)
        (when process
          (ignore-errors (sb-ext:process-kill process 15))
          (ignore-errors (sb-ext:process-close process))))
      (ignore-errors (wayland.server:close-display display)))))

(format t "~%focus-gate: ~D failure~:P~%" *failures*)
(uiop:quit (if (zerop *failures*) 0 1))
