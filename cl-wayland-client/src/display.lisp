;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The display: one socket, one reactor, one object table.
;;;;
;;;; wl_display is object 1 and is the display itself, which is why DISPLAY is a
;;;; subclass of PROXY: (proxy-id display) is 1, and a request method can treat
;;;; the display like any other object.
;;;;
;;;; Outbound requests accumulate in one buffer and are flushed in batches, as
;;;; libwayland does: a burst of create_surface/attach/commit costs one writev
;;;; rather than three.  EAGAIN is not an error; the source switches to
;;;; read-write interest and the reactor flushes when the socket drains.
;;;;
;;;; Inbound, the socket is just a reactor source: readable means "there are
;;;; messages", and WAYLAND.IO:PUMP turns the stream back into messages for
;;;; DISPATCH-MESSAGE.  See docs/protocol-layer.md §6.

(in-package #:wayland.client)

;;; ---------------------------------------------------------------------------
;;; The display
;;; ---------------------------------------------------------------------------

(defclass display (proxy)
  ((socket :initarg :socket :reader display-socket)
   (reactor :initarg :reactor :reader display-reactor)
   (input :initform (make-input-buffer) :reader display-input)
   (output :initform (make-message-buffer :capacity 4096) :reader display-output)
   (objects :initform (make-hash-table :test #'eql) :reader display-objects)
   (next-id :initform +first-client-id+ :accessor display-next-id)
   ;; Ids the server released with wl_display.delete_id, newest first.
   (free-ids :initform nil :accessor display-free-ids)
   (source :initform nil :accessor display-source)
   (closed-p :initform nil :accessor display-closed-p))
  (:documentation
   "A connection to a compositor.  Owns its socket, its reactor and its objects;
DISCONNECT releases all three."))

;;; ---------------------------------------------------------------------------
;;; Where the socket lives
;;; ---------------------------------------------------------------------------

(defun socket-path (&key display-name (runtime-dir (uiop:getenv "XDG_RUNTIME_DIR")))
  "The socket path the environment describes (docs/protocol-layer.md §5).

WAYLAND_DISPLAY may be a bare name, which lives in $XDG_RUNTIME_DIR, or an
absolute path, which is how nested compositors name their socket.  The default
name is \"wayland-0\"."
  (let ((name (or display-name (uiop:getenv "WAYLAND_DISPLAY") "wayland-0")))
    (cond
      ((zerop (length name))
       (error 'client-error :detail "WAYLAND_DISPLAY is empty"))
      ((char= (char name 0) #\/)
       name)
      ((null runtime-dir)
       (error 'client-error
              :detail "XDG_RUNTIME_DIR is not set, and WAYLAND_DISPLAY is not an absolute path"))
      (t
       (format nil "~A/~A" (string-right-trim "/" runtime-dir) name)))))

;;; ---------------------------------------------------------------------------
;;; Connecting
;;; ---------------------------------------------------------------------------

(defun connect (&key display-name path)
  "Connect to the compositor named by PATH, or by the environment."
  (let ((path (or path (socket-path :display-name display-name))))
    (handler-case
        (make-display-from-fd (connect-unix-socket path))
      (io-error (condition)
        (error 'connection-failed :path path :cause condition)))))

(defun make-display-from-fd (fd &key (reactor (make-reactor)))
  "Wrap an already connected socket.  Tests use this with a socket pair.

The display takes ownership of FD and REACTOR: DISCONNECT closes both."
  (let ((display (make-instance 'display
                                :id 1
                                :interface (resolve-interface "wl_display")
                                :version 1
                                :socket fd
                                :reactor reactor)))
    (setf (proxy-display display) display)
    (setf (gethash 1 (display-objects display)) display)
    (setf (display-source display)
          (add-source reactor fd
                      :name "wayland display"
                      :interest :read
                      :on-readable
                      (lambda (source events)
                        (declare (ignore source events))
                        (receive-messages display))
                      :on-writable
                      (lambda (source events)
                        (declare (ignore source events))
                        (flush display))))
    display))

(defmacro with-open-display ((display &rest arguments) &body body)
  "Connect, run BODY, disconnect even on error."
  `(let ((,display (connect ,@arguments)))
     (unwind-protect (progn ,@body)
       (disconnect ,display))))

(defun disconnect (display)
  "Close the connection.  Idempotent; the only way a display goes away."
  (unless (display-closed-p display)
    (setf (display-closed-p display) t)
    (when (display-source display)
      (remove-source (display-reactor display) (display-source display))
      (setf (display-source display) nil))
    (close-fd (display-socket display))
    (close-reactor (display-reactor display))
    (clrhash (display-objects display))
    (setf (proxy-destroyed-p display) t))
  t)

;;; ---------------------------------------------------------------------------
;;; Outbound
;;; ---------------------------------------------------------------------------

(defun pending-output-p (display)
  (plusp (buffer-size (display-output display))))

(defun update-source-interest (display)
  "Ask epoll for writability only while there is something to write."
  (let ((source (display-source display)))
    (when source
      (set-source-interest (display-reactor display) source
                           (if (pending-output-p display) :read-write :read)))))

(defun flush (display)
  "Write as much of the out buffer as the socket accepts.

Returns true when the buffer is empty, NIL when the socket made us stop
(EAGAIN); the reactor then calls back on writability."
  (unless (display-closed-p display)
    (loop while (pending-output-p display)
          do (let ((written (flush-buffer (display-socket display)
                                          (display-output display))))
               (when (zerop written)
                 (update-source-interest display)
                 (return-from flush nil))))
    (update-source-interest display)
    t))

;;; ---------------------------------------------------------------------------
;;; Inbound
;;; ---------------------------------------------------------------------------

(defun receive-messages (display)
  "Drain the socket and dispatch every complete message it held."
  (pump (display-socket display)
        (display-input display)
        (lambda (object-id opcode reader)
          (dispatch-message display object-id opcode reader))))

(defun dispatch-message (display object-id opcode reader)
  "Decode one message and hand it to the object it names."
  (let ((object (object-for-id display object-id)))
    (unless object
      (error 'unknown-object :id object-id :opcode opcode))
    (let* ((interface (proxy-interface object))
           (event (interface-event (interface-name interface) opcode)))
      (when (eq (message-kind event) :request)
        ;; Unreachable through INTERFACE-EVENT; if it ever fires, the generated
        ;; metadata put a request in an event list and nothing above us is right.
        (error 'protocol-error
               :interface (interface-name interface)
               :message (format nil "opcode ~D of ~A is a request, not an event"
                                opcode (interface-name interface))))
      (let ((arguments (loop for argument in (message-args event)
                             collect (decode-argument argument display reader))))
        (unless (reader-done-p reader)
          (error 'protocol-error
                 :interface (interface-name interface)
                 :message (format nil "event ~A left ~D octet~:P undecoded; schema and wire disagree"
                                  (message-name event) (reader-remaining reader))))
        (handle-event display object event arguments)))))

(defun handle-event (display object event arguments)
  "The three events the connection layer owns, then the object's handlers."
  (let ((name (message-name event))
        (interface (interface-name (proxy-interface object))))
    (cond
      ;; A protocol error ends the connection, as it does in libwayland: there is
      ;; no request that can repair a client the compositor refuses to talk to.
      ((and (string= interface "wl_display") (string= name "error"))
       (destructuring-bind (object-id code message) arguments
         (error 'display-error :object-id object-id :code code :message message)))
      ;; The server destroyed an object it created for us (a sync callback, most
      ;; often); the id comes back into circulation.  Users do not see this.
      ((and (string= interface "wl_display") (string= name "delete_id"))
       (release-object display (first arguments))
       nil)
      (t
       (run-event-handlers object event arguments)))))

(defun event-keyword (event)
  "wl_registry.global_remove -> :GLOBAL-REMOVE."
  (intern (string-upcase (substitute #\- #\_ (message-name event))) :keyword))

(defun run-event-handlers (object event arguments)
  "Call the object's hooks, then a method specialised on the event function.

Both models share one schema (D8): a hook is the quick way, a method is how one
interface gets behaviour.  Hooks run first, then the method if there is one; each
event is handled once by each mechanism, never twice by the same one."
  (let ((keyword (event-keyword event)))
    (dolist (hook (proxy-hooks object))
      (apply hook keyword arguments))
    (let* ((symbol (message-symbol event))
           (function (and symbol (fboundp symbol) (fdefinition symbol))))
      (when (and function
                 (typep function 'generic-function)
                 (compute-applicable-methods function (cons object arguments)))
        (apply function object arguments))))
  nil)

;;; ---------------------------------------------------------------------------
;;; The loop
;;; ---------------------------------------------------------------------------

(defun dispatch (display &key timeout)
  "One reactor cycle: read what arrived, dispatch it, run timers and idles.

TIMEOUT is in seconds; NIL blocks until something happens."
  (unless (display-closed-p display)
    (run-once (display-reactor display) :timeout timeout)))

(defmethod wl-display.sync ((display display))
  "Ask the server for a callback, which fires after everything sent so far."
  (check-live display)
  (let ((callback (allocate-proxy display "wl_callback" :version 1)))
    (send-request display (interface-request "wl_display" 0) (proxy-id callback))
    callback))

(defun roundtrip (display &key (timeout 10))
  "Send sync and dispatch until its done event arrives.

Returns true.  Signals ROUNDTRIP-TIMEOUT if the server says nothing within
TIMEOUT seconds, and DISPLAY-ERROR if it reports a protocol error instead."
  (let* ((callback (wl-display.sync display))
         (done nil))
    (push (lambda (event &rest arguments)
            (declare (ignore arguments))
            (when (eq event :done)
              (setf done t)))
          (proxy-hooks callback))
    (flush display)
    (let ((deadline (+ (monotonic-now) timeout)))
      (loop until done
            do (let ((remaining (- deadline (monotonic-now))))
                 (when (<= remaining 0)
                   (error 'roundtrip-timeout :seconds timeout))
                 (dispatch display :timeout remaining))))
    ;; Anything a hook queued goes out now, so a caller that never touches the
    ;; socket again still gets its requests to the compositor.
    (flush display)
    t))
