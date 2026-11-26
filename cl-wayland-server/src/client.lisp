;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; One client connection: accept, read, dispatch, flush, tear down.
;;;;
;;;; The error policy is the important part (D9, docs/architecture.md §6):
;;;;
;;;;   * a client-caused failure (malformed message, bad id, version violation)
;;;;     becomes wl_display.error, a flush, and a disconnect -- never a debugger;
;;;;   * the peer going away (EOF, EPIPE, ECONNRESET) is an orderly teardown;
;;;;   * a Lisp error in our own code is logged with a backtrace while the stack
;;;;     is still live, reported to the client as `implementation', and then
;;;;     also disconnects: a server that cannot trust its own state must not
;;;;     keep serving that client.
;;;;
;;;; Backpressure lives here too: a client that never reads stops being read
;;;; from, so the events it generates cannot grow our memory
;;;; (docs/protocol-layer.md §2).

(in-package #:wayland.server)

;;; ---------------------------------------------------------------------------
;;; Accept
;;; ---------------------------------------------------------------------------

(defun create-client (display fd &key pid uid gid)
  "Wrap an accepted descriptor in a CLIENT and start serving it.

The wl_display resource (id 1) exists before any message can arrive, because
every client is allowed to call get_registry on it immediately."
  (let* ((id (prog1 (display-next-client-id display)
               (incf (display-next-client-id display))))
         (client (make-instance 'client
                                :id id
                                :display display
                                :fd fd
                                :pid pid
                                :uid uid
                                :gid gid)))
    ;; Oldest first: dispatch order, and the order CLOSE-DISPLAY tears down in.
    (setf (display-clients display)
          (append (display-clients display) (list client)))
    (setf (client-display-resource client)
          (make-resource client
                         1
                         (resolve-interface "wl_display")
                         :version 1
                         :class 'display-resource))
    (setf (client-source client)
          (add-source (display-reactor display) fd
                      :name (format nil "client ~D" id)
                      :interest :read
                      :on-readable
                      (lambda (source events)
                        (declare (ignore source events))
                        (service-client client))
                      :on-writable
                      (lambda (source events)
                        (declare (ignore source events))
                        (flush-client client))))
    (client-log client :info "connected")
    client))

;;; ---------------------------------------------------------------------------
;;; Reading and dispatching
;;; ---------------------------------------------------------------------------

(defun receive-messages (client)
  "Drain the socket and dispatch every complete message it held."
  (pump (client-fd client)
        (client-input client)
        (lambda (object-id opcode reader)
          (dispatch-message client object-id opcode reader))))

(defun service-client (client)
  "One readable event on CLIENT: pump, fire this batch's callbacks, flush."
  (unless (client-closed-p client)
    (handler-case
        (handler-bind
            ((error (lambda (condition)
                      (when (unexpected-error-p condition)
                        (log-internal-error client condition)))))
          (receive-messages client)
          ;; wl_display.sync is answered at the end of the batch, not inside the
          ;; request: that is what makes it a roundtrip (docs/protocol-layer.md §5).
          (run-pending-callbacks client)
          (flush-client client))
      (wl-protocol-error (condition)
        (fail-client client condition))
      (truncated-descriptors (condition)
        (fail-client client (as-protocol-error client condition)))
      (wire-error (condition)
        (fail-client client (as-protocol-error client condition)))
      (connection-closed (condition)
        (declare (ignore condition))
        (teardown-client client))
      (io-error (condition)
        (fail-client client (as-protocol-error client condition)))
      (error (condition)
        (fail-client client (as-internal-error client condition))))))

(defun run-pending-callbacks (client)
  "Fire the wl_callback.done events queued by this batch of requests."
  (let ((callbacks (nreverse (client-pending-callbacks client))))
    (setf (client-pending-callbacks client) nil)
    (dolist (callback callbacks)
      (unless (resource-destroyed-p callback)
        (wl-callback.done callback 0)
        ;; The callback id was the client's, so destroying it sends delete_id.
        (destroy-resource callback)))
    (length callbacks)))

;;; ---------------------------------------------------------------------------
;;; Flushing and backpressure
;;; ---------------------------------------------------------------------------

(defparameter +output-high-water-mark+ (* 64 1024)
  "Octets of unflushed output above which we stop reading this client's requests.

Clients that do not read must not be able to make us grow: the buffer stops
growing because the requests that would produce more events stop arriving
(docs/protocol-layer.md §2).  The fixed 64 KiB ring of the plan is still a
phase-0 leftover; this watermark is the bound that matters until then.")

(defun client-congested-p (client)
  (>= (buffer-size (client-output client)) +output-high-water-mark+))

(defun update-client-interest (client)
  "Ask epoll for exactly what this client's state allows.

Nothing pending: read.  Something pending: read and write.  Congested: write
only -- we stop listening to a client that is not listening to us."
  (let ((source (client-source client)))
    (when source
      (set-source-interest (display-reactor (client-display client))
                           source
                           (cond ((zerop (buffer-size (client-output client))) :read)
                                 ((client-congested-p client) :write)
                                 (t :read-write))))))

(defun flush-client (client)
  "Write as much of CLIENT's out buffer as the socket accepts.

Returns true when the buffer is empty, NIL when the socket said EAGAIN and the
reactor now owns the rest."
  (unless (client-closed-p client)
    (when (plusp (buffer-size (client-output client)))
      (log-message :debug "client ~D: flushing ~D octets"
                   (client-id client) (buffer-size (client-output client))))
    (loop while (plusp (buffer-size (client-output client)))
          do (let ((written (flush-buffer (client-fd client)
                                          (client-output client))))
               (when (zerop written)
                 (update-client-interest client)
                 (return-from flush-client nil))))
    (update-client-interest client)
    t))

(defun flush-all (display)
  "Flush every client; used at the end of a cycle and by the demo's loop."
  (log-message :debug "flush-all: ~D client~:P" (length (display-clients display)))
  (dolist (client (copy-list (display-clients display)))
    (unless (client-closed-p client)
      (flush-client client)))
  (length (display-clients display)))

;;; ---------------------------------------------------------------------------
;;; Errors
;;; ---------------------------------------------------------------------------

(defun unexpected-error-p (condition)
  "True for a condition that is not one the connection layer expects and maps."
  (not (or (typep condition 'wl-protocol-error)
           (typep condition 'wire-error)
           (typep condition 'truncated-descriptors)
           (typep condition 'io-error))))

#+sbcl
(defun log-internal-error (client condition)
  "Log a Lisp error with the stack still live (called from HANDLER-BIND)."
  (client-log client :error "internal error (~A): ~A" (type-of condition) condition)
  (when (log-enabled-p :debug)
    (let ((*print-right-margin* 120))
      (format *log-stream* "~&~A~%" (with-output-to-string (stream)
                                      (sb-debug:print-backtrace
                                       :stream stream :count 30))))))

#-sbcl
(defun log-internal-error (client condition)
  (client-log client :error "internal error (~A): ~A" (type-of condition) condition))

(defun as-protocol-error (client condition &key (object-id 1)
                                            (code +error-invalid-method+))
  "A condition the client caused, re-expressed as the protocol error it is."
  (make-condition 'wl-protocol-error
                  :client client
                  :object-id object-id
                  :code code
                  :message (princ-to-string condition)))

(defun as-internal-error (client condition)
  (make-condition 'wl-protocol-error
                  :client client
                  :object-id 1
                  :code +error-implementation+
                  :message (format nil "compositor internal error: ~A" condition)))

(defun send-client-error (client object-id code message)
  "Send wl_display.error and try to get it out before the socket closes."
  (let ((display (client-display-resource client)))
    (when (and display (not (resource-destroyed-p display)))
      (wl-display.error display object-id code message)
      ;; A client that will not take the error is gone anyway; the teardown
      ;; below is what matters, not this write.
      (handler-case (flush-client client)
        (wayland.ffi:io-error () nil)))))

(defun fail-client (client condition)
  "Report CONDITION to the client, then disconnect it.  Never re-signals."
  (let ((object-id (or (wl-protocol-error-object-id condition) 1))
        (code (wl-protocol-error-code condition)))
    (client-log client (if (= code +error-implementation+) :error :warn)
                "disconnecting: ~A" condition)
    (send-client-error client object-id code (wl-protocol-error-message condition))
    (teardown-client client))
  nil)

;;; ---------------------------------------------------------------------------
;;; Registries
;;; ---------------------------------------------------------------------------

(defun client-registries (client)
  "Every live wl_registry of CLIENT, oldest first.

A client may call get_registry more than once, and each registry gets its own
copy of the global list: they are objects like any other."
  (loop for resource in (reverse (client-resources client))
        when (and (typep resource 'registry)
                  (not (resource-destroyed-p resource)))
          collect resource))

;;; ---------------------------------------------------------------------------
;;; Teardown
;;; ---------------------------------------------------------------------------

(defun teardown-client (client)
  "The one way a connection ends: EOF, protocol error, or shutdown.

Idempotent, and it destroys resources in reverse creation order.  Descriptors
are closed here and nowhere else: the socket, the descriptors that arrived but
no message claimed, and any descriptor queued in the out buffer that never went
out (docs/architecture.md §7)."
  (unless (client-closed-p client)
    (setf (client-closed-p client) t)
    (when (client-source client)
      (remove-source (display-reactor (client-display client)) (client-source client))
      (setf (client-source client) nil))
    (dolist (resource (client-resources client))
      (unless (resource-destroyed-p resource)
        (destroy-resource resource)))
    (setf (client-resources client) nil)
    (setf (client-pending-callbacks client) nil)
    (setf (client-pending-new-ids client) nil)
    (reset-input-buffer (client-input client))
    (dolist (fd (buffer-fds (client-output client)))
      (close-fd fd))
    (clear-message-buffer (client-output client))
    (close-fd (client-fd client))
    (setf (display-clients (client-display client))
          (remove client (display-clients (client-display client))))
    (client-log client :info "disconnected"))
  t)

(defun disconnect-client (client)
  "Disconnect CLIENT deliberately (not because of an error)."
  (teardown-client client))
