;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The grabs gate: a real client asks to be moved, the compositor moves it, and
;;;; a real client asks to be resized, and the compositor configures the size.
;;;;
;;;; Run by scripts/grab-gate.sh, which generates xdg-shell's client protocol code
;;;; with wayland-scanner and compiles tests/c-client/wayland-move-client.c.
;;;;
;;;; What only a real client can prove, and what each assertion is therefore for:
;;;;
;;;;   * the serial the client echoed came from a real wl_pointer.button event
;;;;     that we sent, so the grab path is connected to the input path;
;;;;   * the window's scene node follows the pointer while the button is down, and
;;;;     stops when it comes up -- a grab that never ended, or ended twice, shows
;;;;     up here as a position that keeps moving or one that never moves;
;;;;   * the *same* window is not moved by a motion after the button came up;
;;;;   * a resize request becomes an xdg_toplevel.configure carrying the size the
;;;;     drag asked for, which is the only way a compositor can resize a buffer it
;;;;     does not own;
;;;;   * the client never sees a protocol error, so a refused request was refused
;;;;     with silence rather than a disconnect;
;;;;   * Alt+F1 cycles the two windows and Alt+Esc stops the main loop.

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defparameter *window-colour* #xFF3C8C3C "The client's buffer: opaque green-ish.")
(defparameter *background* #xFF000000 "Opaque black.")
(defvar *ok* t)
(defvar *client-lines* '() "Lines the move client printed so far, oldest first.")

(defun check (condition control &rest arguments)
  (if condition
      (format t "  ok   ~?~%" control arguments)
      (progn (setf *ok* nil)
             (format t "  FAIL ~?~%" control arguments)))
  condition)

(defun resources-of-type (compositor type)
  (loop for client in (wayland.server:display-clients (cf:compositor-display compositor))
        append (remove-if-not (lambda (resource) (typep resource type))
                              (wayland.server:client-resources client))))

(defun mapped-surfaces (compositor)
  (remove-if-not (lambda (surface)
                   (and (cf:surface-scene-node surface)
                        (wayland.server:surface-mapped-p surface)))
                 (cf:compositor-surfaces compositor)))

(defun node-position (surface)
  (let ((node (cf:surface-scene-node surface)))
    (multiple-value-list (cf.scene:node-position node))))

(defun collect-lines (pty)
  "Read whatever the client printed.  A pty whose process has exited raises EIO
from LISTEN, which is the normal end of a drain, not an error."
  (handler-case
      (loop while (and pty (listen pty))
            do (let ((line (read-line pty nil nil)))
                 (when line
                   (setf *client-lines* (append *client-lines* (list line))))))
    (error () nil)))

(defun pump (compositor pty seconds)
  "Run the compositor for SECONDS, reading the client's pty as it goes."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display compositor)))
    (loop until (> (get-internal-real-time) deadline)
          do (wayland.server:run-once display :timeout 0.01)
             (collect-lines pty))))

(defun pump-until (compositor pty predicate seconds)
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (display (cf:compositor-display compositor)))
    (loop
      (collect-lines pty)
      (let ((value (funcall predicate)))
        (when value (return value))
        (when (> (get-internal-real-time) deadline)
          (return nil))
        (wayland.server:run-once display :timeout 0.01)))))

(defun wait-for-line (compositor pty needle seconds)
  (or (find needle *client-lines* :test #'search)
      (pump-until compositor pty
                  (lambda () (find needle *client-lines* :test #'search))
                  seconds)))

(defun expect-line (compositor pty needle)
  (let ((line (wait-for-line compositor pty needle 5)))
    (check line "client printed ~S~@[: ~A~]" needle
           (and line (string-trim '(#\Return) line)))
    line))

;;; ---------------------------------------------------------------------------
;;; The steps, in the order a person would do them
;;; ---------------------------------------------------------------------------

(defun move-and-release (compositor pty surface)
  "Click, let the client ask to be moved, drag, release; the window follows once."
  (cf:inject-pointer-motion compositor 50 50)
  (pump compositor pty 0.1)
  (cf:inject-pointer-button compositor :left :pressed)
  (expect-line compositor pty "move ")
  (check (cf:compositor-grab compositor)
         "a grab is active after the client's move request")

  (cf:inject-pointer-motion compositor 80 90)
  (pump compositor pty 0.1)
  (check (equal '(30 40) (node-position surface))
         "the drag moved the window to ~S, not (30,40)" (node-position surface))

  (cf:inject-pointer-button compositor :left :released)
  (pump compositor pty 0.1)
  (check (null (cf:compositor-grab compositor))
         "the grab ended on the button release")

  (cf:inject-pointer-motion compositor 140 150)
  (pump compositor pty 0.1)
  (check (equal '(30 40) (node-position surface))
         "motion after the release left the window at ~S" (node-position surface))

  (cf:render-frame compositor)
  (check (= *window-colour* (cf:frame-pixel compositor 80 90))
         "the window is drawn at its new position (#x~8,'0X)"
         (cf:frame-pixel compositor 80 90)))

(defun resize (compositor pty)
  "A right-button drag from (130,115) to (170,145) asks for 200x150 + (40,30)."
  (cf:inject-pointer-motion compositor 130 115)
  (pump compositor pty 0.1)
  (cf:inject-pointer-button compositor :right :pressed)
  (expect-line compositor pty "resize ")
  (check (cf:compositor-grab compositor)
         "a grab is active after the client's resize request")

  (cf:inject-pointer-motion compositor 170 145)
  (pump compositor pty 0.2)
  (check (wait-for-line compositor pty "configure 240x180" 5)
         "the compositor configured the client for 240x180")

  (cf:inject-pointer-button compositor :right :released)
  (pump compositor pty 0.1)
  (check (null (cf:compositor-grab compositor))
         "the resize grab ended on the button release")

  ;; And a resize stops where the output does (D46).  The window's anchored
  ;; top-left is (30,40), so the bottom-right edge may travel to (512,512) and no
  ;; further: the drag asks for 482x472 however far the pointer goes.
  (cf:inject-pointer-motion compositor 80 80)
  (pump compositor pty 0.1)
  (cf:inject-pointer-button compositor :right :pressed)
  ;; The client asks on the press, and the grab takes the pointer where it is *then*:
  ;; moving first would give the drag a zero delta.  Pump until the request has
  ;; arrived (the stale "resize" line from the first drag is still in the log).
  (pump compositor pty 0.2)
  (check (typep (cf:compositor-grab compositor) 'cf.grab:resize-grab)
         "a second resize grab started from inside the window")
  ;; The pointer goes *past* the bottom edge with x still inside: the grab survives,
  ;; the height stops at the output and the width keeps following (D47).  A drag that
  ;; stopped entirely here is what the manual test reported.
  ;; The drag starts at (80,80) on a 200x150 window whose anchored top-left is (30,40).
  (cf:inject-pointer-motion compositor 200 600)
  (pump compositor pty 0.2)
  (check (and (cf:compositor-grab compositor)
              (wait-for-line compositor pty "configure 320x472" 5))
         "a drag past the bottom edge keeps resizing x (320x472)")
  (cf:inject-pointer-motion compositor 300 600)
  (pump compositor pty 0.2)
  (check (wait-for-line compositor pty "configure 420x472" 5)
         "and keeps following it, with the height still at the output's bound (420x472)")
  (cf:inject-pointer-motion compositor 500 500)
  (pump compositor pty 0.2)
  (check (wait-for-line compositor pty "configure 482x472" 5)
         "until x reaches the edge too, where both stop (482x472, not 1120x1070)")
  (cf:inject-pointer-button compositor :right :released)
  (pump compositor pty 0.1)
  (check (null (cf:compositor-grab compositor))
         "and the clamped resize ended on the release"))

(defun keybindings (compositor pty)
  "Alt+F1 cycles the bottom window to the top; Alt+Esc stops the main loop."
  (let* ((surface (first (mapped-surfaces compositor)))
         (node (cf:surface-scene-node surface))
         (seat (cf:compositor-seat compositor))
         (root (cf.scene:scene-root (cf:compositor-scene compositor))))
    (cf:inject-key compositor "Alt_L" :pressed)
    (cf:inject-key compositor "F1" :pressed)
    (cf:inject-key compositor "F1" :released)
    (cf:inject-key compositor "Alt_L" :released)
    (pump compositor pty 0.2)
    (check (eq node (car (last (cf.scene:node-children root))))
           "alt+F1 raised the bottom window")
    (check (eq surface (wayland.server:seat-keyboard-focus seat))
           "alt+F1 focused the window it raised")

    (cf:inject-key compositor "Alt_L" :pressed)
    (cf:inject-key compositor "Escape" :pressed)
    (cf:inject-key compositor "Escape" :released)
    (cf:inject-key compositor "Alt_L" :released)
    (check (wayland.reactor:stopped-p
            (wayland.server:display-reactor (cf:compositor-display compositor)))
           "alt+Esc asked the main loop to stop")))

;;; ---------------------------------------------------------------------------
;;; Main
;;; ---------------------------------------------------------------------------

(let* ((client (or (uiop:getenv "MOVE_CLIENT")
                   (error "MOVE_CLIENT is not set")))
       (png (or (uiop:getenv "FRAME_PNG") "/tmp/cl-wayland-grab.png"))
       (compositor (cf:make-headless-compositor :width 512 :height 512
                                                :background *background*))
       (display (cf:compositor-display compositor))
       (process nil)
       (process-b nil)
       (pty nil))

  (unwind-protect
       (progn
         (format t "compositor: 512x512 headless, socket ~A~%"
                 (wayland.server:display-socket-path display))

         ;; 1. A window that can ask to be moved, and a click that reaches it.
         (setf process (sb-ext:run-program client
                                           (list "--width" "200" "--height" "150")
                                           :wait nil :pty t)
               pty (sb-ext:process-pty process))
         (let ((surface (pump-until compositor pty
                                    (lambda () (first (mapped-surfaces compositor)))
                                    20)))
           (check surface "a window mapped within 20 s")
           (when surface
             (format t "window: node at ~S, buffer ~Dx~D~%"
                     (node-position surface)
                     (cf.scene:node-width (cf:surface-scene-node surface))
                     (cf.scene:node-height (cf:surface-scene-node surface)))
             (check (equal '(0 0) (node-position surface))
                    "the first window is at ~S, not (0,0)" (node-position surface))
             (move-and-release compositor pty surface)
             (resize compositor pty)

             ;; 2. A second window, so cycling has somewhere to go.
             (setf process-b (sb-ext:run-program "weston-simple-shm" nil
                                                 :wait nil :output t :error t
                                                 :search t))
             (check (pump-until compositor pty
                                (lambda () (>= (length (mapped-surfaces compositor)) 2))
                                20)
                    "the second window mapped")
             (keybindings compositor pty)

             ;; 3. The client is still connected: a refused request is silence,
             ;;    and nothing we sent was a protocol error.
             (check (sb-ext:process-alive-p process)
                    "the move client is still connected at the end")
             (cf:write-frame-png compositor png)
             (format t "screenshot: ~A~%" png))))

    ;; Stop both clients, prove the teardown left nothing, then close.
    (dolist (p (list process process-b))
      (when (and p (sb-ext:process-alive-p p))
        (ignore-errors (sb-ext:process-kill p 15))))
    (pump compositor pty 0.3)
    (let ((left (length (wayland.server:display-clients display))))
      (if (zerop left)
          (format t "teardown: no clients, no objects left~%")
          (progn (setf *ok* nil)
                 (format t "  FAIL ~D client(s) still connected after the clients exited~%"
                         left))))
    (wayland.server:close-display display)
    (when pty
      (ignore-errors (collect-lines pty)))
    (dolist (p (list process process-b))
      (when p (ignore-errors (sb-ext:process-close p))))
    (format t "~&~:[FAILED~;PASSED~]~%" *ok*)
    (uiop:quit (if *ok* 0 1))))
