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
  --drm                 take a VT: a seat, the card it hands out, and that screen
  --card PATH           the card to take with --drm (default /dev/dri/card0)
  --connector NAME      which output of it to program (default: the first connected)
  --parent PATH         the parent's socket (implies --nested)
  --size WxH            output size in layout pixels (default 1280x800)
  --scale N             device pixels per layout pixel (default 1); 2 draws at
                        the density of a HiDPI output
  --launch CMD          start CMD (default weston-terminal) as a client of ours:
                        immediately, and again on Alt+Shift+Return
  --display NAME        the name of our own socket (default wayland-0 headless,
                        tinywl-1 nested and on a VT, where the session compositor
                        very likely owns wayland-0)
  --runtime-dir DIR     where the socket goes (default XDG_RUNTIME_DIR)
  --stats SECONDS       write one line of numbers (rss, fds, frames, partial, flips)
                        every SECONDS to the log, for a soak; 0 (default) is quiet, and
                        TINYWL_STATS_INTERVAL sets the same thing from the environment
  --help                this text

On a VT, TINYWL_FRAME_LOG names a file (or 1 for stderr) that gets one line per
frame -- the frame and its buffer, the three damage boxes, and the flip's own
completion, wait and gap in milliseconds.  It is off by default; it exists to read
a flicker from the console, because a flicker cannot be photographed.

With none of --headless, --nested or --drm, tinywl nests when WAYLAND_DISPLAY
names a live compositor and runs headless otherwise.  --drm needs a seat it may
take, so run it from a text console and not from inside a compositor that already
owns the screen; it gives the screen back on Alt+Esc and on SIGINT, SIGTERM or
SIGHUP.  Press Alt+Esc to quit, Alt+F1 to send the bottom window to the front,
Alt+Shift+Return to start a terminal, Alt+left-drag to move a window and
Alt+right-drag to resize it from the edge under the pointer.
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
                 ((string= argument "--drm") (setf mode :drm))
                 ((string= argument "--card")
                  (setf options (list* :card (value) options))
                  (skip))
                 ((string= argument "--connector")
                  (setf options (list* :connector (value) options))
                  (skip))
                 ((string= argument "--parent") (setf parent (value) mode :nested) (skip))
                 ((string= argument "--size")
                  (multiple-value-bind (width height) (parse-size (value))
                    (setf options (list* :width width :height height options)))
                  (skip))
                 ((string= argument "--scale")
                  (let ((scale (parse-integer (value) :junk-allowed t)))
                    (unless (and scale (plusp scale))
                      (error "~A is not a scale; it must be a positive integer" (value)))
                    (setf options (list* :scale scale options)))
                  (skip))
                 ((string= argument "--display") (setf options (list* :display-name (value) options)) (skip))
                 ;; One executable, not a shell command line: what to launch is policy, and a
                 ;; compositor's policy is the running image's (D14) -- set TINYWL:*TERMINAL-COMMAND*.
                 ((string= argument "--launch") (setf options (list* :launch (list (value)) options)) (skip))
                 ((string= argument "--runtime-dir") (setf options (list* :runtime-dir (value) options)) (skip))
                 ((string= argument "--stats")
                  (let ((seconds (parse-integer (value) :junk-allowed t)))
                    (unless (and seconds (not (minusp seconds)))
                      (error "~A is not a statistics interval; it is a number of seconds" (value)))
                    (setf options (list* :stats-interval seconds options)))
                  (skip))
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
      ;; The first thing a person hits on a VT: the session's compositor owns
      ;; wayland-0, and its lock is live.
      (when (typep condition 'srv:socket-in-use)
        (format *error-output*
                "tinywl: that socket name belongs to another compositor; name ours ~
with --display, for example --display tinywl-1, and point clients at it with ~
WAYLAND_DISPLAY=tinywl-1~%"))
      (write-string +usage+ *error-output*)
      2)))
