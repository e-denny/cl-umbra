;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; wayland-server-demo: the phase-1 walking skeleton.
;;;;
;;;; It creates a socket, offers wl_compositor and wl_output, and serves clients
;;;; until SIGTERM or SIGINT.  `wayland-info` against it is the phase-1 gate.
;;;;
;;;; Signals arrive through the reactor's signalfd, not as handlers that preempt
;;;; dispatch (docs/protocol-layer.md §7), so shutdown happens between messages.

(in-package #:cl-user)

(defpackage #:wayland.server.demo
  (:use #:cl)
  (:documentation "The runnable phase-1 server: two dummy globals, no drawing.")
  (:export #:main #:toplevel))

(in-package #:wayland.server.demo)

(defun main (&key (display-name (uiop:getenv "WAYLAND_DISPLAY"))
                  (runtime-dir (uiop:getenv "XDG_RUNTIME_DIR"))
                  (log-level :info))
  "Serve until SIGTERM/SIGINT or until DISPLAY is closed.  Returns 0."
  (setf wayland.server:*log-level* log-level)
  (wayland.ffi:ignore-sigpipe)
  (let* ((display (wayland.server:make-demo-display
                   :display-name display-name
                   :runtime-dir runtime-dir))
         (reactor (wayland.server:display-reactor display)))
    (unwind-protect
         (progn
           ;; The gate's script waits for this line, then starts wayland-info.
           (format t "~&listening on ~A~%" (wayland.server:display-socket-path display))
           (finish-output)
           ;; ADD-SIGNAL-HANDLER, not ADD-SIGNAL-SOURCE: a process-directed
           ;; SIGTERM can land on SBCL's finalizer thread, where a blocked-signal
           ;; signalfd never sees it (wayland.reactor has the measurements).
           (wayland.reactor:add-signal-handler
            reactor
            (list wayland.ffi:+sigterm+ wayland.ffi:+sigint+)
            :name "termination"
            :on-signal (lambda (source signal)
                         (declare (ignore source))
                         (wayland.server:log-message :info "signal ~D: shutting down" signal)
                         (wayland.reactor:request-stop reactor)))
           (wayland.server:run display)
           0)
      (wayland.server:close-display display))))

(defun toplevel (&rest arguments)
  "Entry point for the built executable: MAIN, then exit with its code."
  (declare (ignore arguments))
  (uiop:quit (or (main) 0)))
