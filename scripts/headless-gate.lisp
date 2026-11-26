;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The phase-2a gate: a libwayland shm client draws through our headless
;;;; compositor, and the frame it produced is checked pixel by pixel.
;;;;
;;;; Run by scripts/headless-frame.sh, which compiles the client first.  The
;;;; environment carries HEADLESS_CLIENT (the binary), FRAME_PNG (where the
;;;; screenshot goes) and the usual WAYLAND_DISPLAY/XDG_RUNTIME_DIR.
;;;;
;;;; The client is a separate process with its own libwayland, its own id
;;;; allocation and its own event queue: nothing about this is a mock.

;; The source registry and Quicklisp are set up by scripts/lib.sh, which the
;; driver has already sourced.
(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defparameter *background* #xFF000000 "Opaque black: nothing drawn there.")
(defparameter *red* #xFFFF0000 "Premultiplied, opaque red.")
(defparameter *blue* #xFF0000FF "Premultiplied, opaque blue.")

(defun wait-for-client (compositor process timeout)
  "Pump the compositor until PROCESS exits, or TIMEOUT seconds pass.

A frame callback is what lets the client exit, and it only arrives after a
render, so this loop is the whole compositor lifecycle under test."
  (let ((display (cf:compositor-display compositor))
        (deadline (+ (get-internal-real-time)
                     (* timeout internal-time-units-per-second))))
    (loop
      (when (not (sb-ext:process-alive-p process))
        (return t))
      (when (> (get-internal-real-time) deadline)
        (sb-ext:process-kill process 15)
        (return nil))
      ;; A real compositor waits in epoll; here the client is the only source.
      (wayland.server:run-once display :timeout 0.01))))

(defun check (compositor pixels)
  "PIXELS is a list of (x y expected description); return a failure count."
  (let ((failures 0))
    (dolist (entry pixels)
      (destructuring-bind (x y expected description) entry
        (let ((actual (cf:frame-pixel compositor x y)))
          (if (= actual expected)
              (format t "  ok   ~A: (~D,~D) = #x~8,'0X~%" description x y actual)
              (progn
                (incf failures)
                (format t "  FAIL ~A: (~D,~D) = #x~8,'0X, expected #x~8,'0X~%"
                        description x y actual expected))))))
    failures))

(let* ((client (or (uiop:getenv "HEADLESS_CLIENT")
                   (error "HEADLESS_CLIENT is not set")))
       (png (or (uiop:getenv "FRAME_PNG") "/tmp/cl-wayland-frame.png"))
       (compositor (cf:make-headless-compositor :width 256 :height 256
                                                :background *background*))
       (process nil))
  (unwind-protect
       (let ((ok t))
         (format t "compositor: 256x256 headless, socket ~A~%"
                 (wayland.server:display-socket-path (cf:compositor-display compositor)))
         (setf process (sb-ext:run-program client nil :wait nil :output t :error t))
         ;; There is a softwar cursor now (D31) and it is drawn at the pointer.
         ;; Park it away from every pixel asserted below -- the cursor's own
         ;; pixels are what the scene gate checks; this clause is about the
         ;; buffer's position and must not accidentally measure an arrow.
         (cf:inject-pointer-motion compositor 128 128)
         (unless (wait-for-client compositor process 10)
           (format t "FAIL: the client did not finish within 10 s~%")
           (setf ok nil))
         (when process
           (let ((status (sb-ext:process-exit-code process)))
             (unless (eql status 0)
               (format t "FAIL: the client exited ~S~%" status)
               (setf ok nil))))
         ;; The frame that matters was rendered while the client was alive: its
         ;; commit marked the output dirty and an idle drew it.  Re-rendering now
         ;; would clear the target, because the client is gone and its surface
         ;; with it -- which is exactly the trap this comment exists to prevent.
         (unless (plusp (cf:compositor-frame-count compositor))
           (format t "FAIL: no frame was ever rendered~%")
           (setf ok nil))
         (format t "frame ~D rendered, ~D surface(s)~%"
                 (cf:compositor-frame-count compositor)
                 (length (cf:compositor-surfaces compositor)))
         (when (plusp (check compositor (list (list 10 20 *red* "first pixel of the buffer")
                                   (list 41 20 *red* "last pixel of the red half")
                                   (list 42 20 *blue* "first pixel of the blue half")
                                   (list 50 20 *blue* "middle of the blue half")
                                   (list 73 51 *blue* "last pixel of the buffer")
                                   (list 9 20 *background* "just left of it")
                                   (list 74 20 *background* "just right of it")
                                   (list 10 52 *background* "just below it")
                                   (list 0 0 *background* "far corner"))))
           (setf ok nil))
         (cf:write-frame-png compositor png)
         (format t "screenshot: ~A~%" png)
         (format t "~&~:[FAILED~;PASSED~]~%" ok)
         (uiop:quit (if ok 0 1)))
    (when process (ignore-errors (sb-ext:process-close process)))
    (wayland.server:close-display (cf:compositor-display compositor))))
