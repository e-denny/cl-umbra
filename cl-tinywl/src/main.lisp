;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; tinywl's `main': parse a short command line, start a session, run it, stop it.
;;;;
;;;; tinywl.c's main creates the backend, the renderer, the compositor, the seat and
;;;; the shell, then runs the event loop; here the framework's defaults do that from
;;;; one call, and what is left is the two choices a person makes at a terminal:
;;;; where the output goes (a window inside the current session, or a target in
;;;; memory) and how big it is.

(in-package #:tinywl)

(defparameter +usage+
  "Usage: tinywl [OPTIONS]

  --headless            render into memory; input must be injected (a test backend)
  --nested              run as a window inside the compositor in WAYLAND_DISPLAY
  --parent PATH         the parent's socket (implies --nested)
  --size WxH            output size in pixels (default 512x512)
  --display NAME        the name of our own socket (default wayland-0 headless,
                        tinywl-1 nested)
  --runtime-dir DIR     where the socket goes (default XDG_RUNTIME_DIR)
  --help                this text

With neither --headless nor --nested, tinywl nests when WAYLAND_DISPLAY names a
live compositor and runs headless otherwise.  Press Alt+Esc to quit, Alt+F1 to send
the bottom window to the front, Alt+left-drag to move a window and Alt+right-drag
to resize it from the edge under the pointer.
")

(defun parse-size (text)
  "WIDTHxHEIGHT, or an error a person can act on."
  (let ((x (position #\x text)))
    (unless x
      (error "~S is not a size; the form is WIDTHxHEIGHT, for example 512x512" text))
    (let ((width (parse-integer text :end x :junk-allowed t))
          (height (parse-integer text :start (1+ x) :junk-allowed t)))
      (unless (and width height (plusp width) (plusp height))
        (error "~S is not a size; both dimensions must be positive integers" text))
      (values width height))))

(defun parse-arguments (arguments)
  "ARGUMENTS as keyword arguments to START, or :help / :error.

Deliberately hand-written: tinywl has five options, and a compositor's command line
is the one interface that must not need a library to read."
  (let ((options '())
        (mode nil)
        (parent nil)
        (help nil))
    (loop for rest on arguments
          for argument = (first rest)
          do (flet ((value ()
                      (or (second rest)
                          (error "~A needs a value" argument)))
                    (skip ()
                      (setf rest (cdr rest))))
               (cond
                 ((string= argument "--headless") (setf mode :headless))
                 ((string= argument "--nested") (setf mode :nested))
                 ((string= argument "--parent") (setf parent (value) mode :nested) (skip))
                 ((string= argument "--size")
                  (multiple-value-bind (width height) (parse-size (value))
                    (setf options (list* :width width :height height options)))
                  (skip))
                 ((string= argument "--display") (setf options (list* :display-name (value) options)) (skip))
                 ((string= argument "--runtime-dir") (setf options (list* :runtime-dir (value) options)) (skip))
                 ((string= argument "--help") (setf help t))
                 (t (error "unknown option ~S" argument)))))
    (when help
      (return-from parse-arguments :help))
    ;; A socket that exists is the compositor's own announcement that it is there;
    ;; WAYLAND_DISPLAY naming one that does not is a mistake to report, not a
    ;; reason to open a headless output nobody asked for.
    (let ((mode (or mode (if (parent-socket-p) :nested :headless))))
      (list* :mode mode (append (when parent (list :parent-path parent)) options)))))

(defun parent-socket-p ()
  "Is there a live compositor at WAYLAND_DISPLAY?"
  (let ((path (parent-socket-path (uiop:getenv "WAYLAND_DISPLAY"))))
    (and path (probe-file path) t)))

(defun main (&optional (arguments (uiop:command-line-arguments)))
  "Run tinywl; returns the exit code.

Called as `(tinywl:main)' from a saved image, or from a REPL for a session in
progress -- the same call either way, because a running Lisp image is this
compositor's control surface (D14)."
  (handler-case
      (let ((options (parse-arguments arguments)))
        (cond
          ((eq options :help)
           (write-string +usage+)
           (finish-output)
           0)
          (t
           (let ((session (apply #'start options)))
             (format t "tinywl: ~A session on ~A, ~Dx~D~%"
                     (string-downcase (symbol-name (session-mode session)))
                     (srv:display-socket-path
                      (cf:compositor-display (session-compositor session)))
                     (cf:compositor-width (session-compositor session))
                     (cf:compositor-height (session-compositor session)))
             (finish-output)
             (unwind-protect
                  (progn (run session) 0)
               (stop session)
               (format t "tinywl: stopped~%")
               (finish-output))))))
    (error (condition)
      (format *error-output* "tinywl: ~A~%" condition)
      (write-string +usage+ *error-output*)
      2)))
