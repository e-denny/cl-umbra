;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The display: socket, clients, globals, and the loop that serves them.
;;;;
;;;; MAKE-DISPLAY is the whole of phase 1's setup: resolve the socket name, take
;;;; the lock, bind, listen, and register the accept source.  There is no thread
;;;; and no hidden loop: RUN-ONCE runs one reactor cycle, RUN runs them until
;;;; something asks to stop (D9: single-threaded, re-entrancy forbidden).

(in-package #:wayland.server)

;;; ---------------------------------------------------------------------------
;;; Creating and closing
;;; ---------------------------------------------------------------------------

(defun make-display (&key (display-name (uiop:getenv "WAYLAND_DISPLAY"))
                          (runtime-dir (uiop:getenv "XDG_RUNTIME_DIR"))
                          (reactor (make-reactor))
                          (accept-budget 16))
  "Create the socket DISPLAY-NAME names and start accepting clients.

DISPLAY-NAME and RUNTIME-DIR default to $WAYLAND_DISPLAY and $XDG_RUNTIME_DIR;
an absolute DISPLAY-NAME is used as-is, which is how a nested compositor or a
test gets its own socket.  The reactor is created here unless one is passed, and
CLOSE-DISPLAY closes it either way."
  (let* ((name (or display-name "wayland-0"))
         (path (handler-case
                   (wayland.io:socket-path :display-name name
                                           :runtime-dir runtime-dir)
                 (wayland.io:socket-path-error (condition)
                   (error 'socket-condition
                          :path name
                          :cause condition
                          :detail "cannot resolve the socket name")))))
    (multiple-value-bind (socket-fd lock-fd) (open-display-socket path)
      (let ((display (make-instance 'display
                                    :reactor reactor
                                    :name name
                                    :socket-path path
                                    :socket-fd socket-fd
                                    :lock-fd lock-fd
                                    :accept-budget (max 1 accept-budget))))
        (setf (display-source display)
              (add-source reactor socket-fd
                          :name "wayland socket"
                          :interest :read
                          :on-readable
                          (lambda (source events)
                            (declare (ignore source events))
                            (accept-pending-clients display))))
        (log-message :info "listening on ~A" path)
        display))))

(defun close-display (display)
  "Stop accepting, disconnect every client, remove the socket file.  Idempotent."
  (unless (display-closed-p display)
    (setf (display-closed-p display) t)
    (when (display-source display)
      (remove-source (display-reactor display) (display-source display))
      (setf (display-source display) nil))
    (dolist (client (copy-list (display-clients display)))
      (teardown-client client))
    (close-display-socket (display-socket-path display)
                          (display-socket-fd display)
                          (display-lock-fd display))
    (close-reactor (display-reactor display))
    (log-message :info "closed ~A" (display-socket-path display)))
  t)

;;; ---------------------------------------------------------------------------
;;; Accepting
;;; ---------------------------------------------------------------------------

(defun accept-pending-clients (display)
  "Accept up to ACCEPT-BUDGET connections; return how many were accepted.

The budget is what keeps a connect storm from starving the clients that are
already connected: level-triggered epoll will report the socket again next
cycle, so nothing is lost by stopping early."
  (let ((accepted 0))
    (loop repeat (display-accept-budget display)
          do (multiple-value-bind (fd pid uid gid) (accept-peer display)
               (unless fd (return))
               (create-client display fd :pid pid :uid uid :gid gid)
               (incf accepted)))
    accepted))

;;; ---------------------------------------------------------------------------
;;; The loop
;;; ---------------------------------------------------------------------------

(defun run-once (display &key timeout)
  "One reactor cycle: commands, wait, sources, timers, idles, then flush.

The flush belongs here, at the end of every cycle, and not only where events are
produced: a compositor that queues events outside a client's readable event (a
backend injecting input, a timer, an idle) would otherwise leave them in the
buffer until something unrelated flushed.  libwayland-server's loop flushes its
clients every iteration for the same reason.  Found by weston-eventdemo sitting
idle after its first frame: our motion events were queued and never written."
  (prog1 (wayland.reactor:run-once (display-reactor display) :timeout timeout)
    (flush-all display)))

(defun run (display &key timeout stop)
  "Run cycles until REQUEST-STOP, STOP returns true, or TIMEOUT seconds pass.

Returns :stopped or :timeout.  This is the compositor's main loop; a client
error inside it never escapes (see SERVICE-CLIENT)."
  (wayland.reactor:run (display-reactor display) :timeout timeout :stop stop))

;;; ---------------------------------------------------------------------------
;;; Serials
;;; ---------------------------------------------------------------------------

(defun display-next-serial (display)
  "A per-display monotonic serial, wrapped at 32 bits.

Phase 1 has nothing serial-bearing yet; seats, selections and popup grabs in
later phases do, and clients echo these numbers back, so the counter belongs to
the display and not to any one resource."
  (setf (display-serial display)
        (logand (1+ (display-serial display)) #xFFFFFFFF)))
