;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Conditions, and the one policy that matters: a client-caused failure never
;;;; reaches the debugger (D9, docs/architecture.md §6).
;;;;
;;;; Three kinds:
;;;;
;;;;   socket-condition   we could not set up or keep the socket
;;;;   wl-protocol-error  the client broke the protocol and will be disconnected
;;;;   internal-error     our bug; logged with a backtrace, client disconnected
;;;;
;;;; Everything else that a client can do -- EOF, EPIPE, a truncated descriptor
;;;; set, a malformed message -- is one of the conditions already defined in
;;;; wayland.ffi/wayland.io/wayland.wire, and the connection layer maps each of
;;;; them onto one of these three.

(in-package #:wayland.server)

;;; ---------------------------------------------------------------------------
;;; Server conditions
;;; ---------------------------------------------------------------------------

(define-condition server-error (error)
  ((detail :initarg :detail :initform nil :reader server-error-detail))
  (:report (lambda (condition stream)
             (format stream "wayland server error~@[: ~A~]"
                     (server-error-detail condition)))))

(define-condition socket-condition (server-error)
  ((path :initarg :path :reader socket-condition-path)
   (cause :initarg :cause :initform nil :reader socket-condition-cause))
  (:report (lambda (condition stream)
             (format stream "socket ~A: ~A~@[ (~A)~]"
                     (socket-condition-path condition)
                     (server-error-detail condition)
                     (socket-condition-cause condition)))))

(define-condition socket-in-use (socket-condition) ()
  (:default-initargs
   :detail "another server holds the lock; is a compositor already running?"))

(define-condition socket-path-condition (socket-condition) ())

;;; ---------------------------------------------------------------------------
;;; The wl_display.error codes (wayland.xml, wl_display.error)
;;; ---------------------------------------------------------------------------

(defconstant +error-invalid-object+ 0)
(defconstant +error-invalid-method+ 1)
(defconstant +error-no-memory+ 2)
(defconstant +error-implementation+ 3)

;;; ---------------------------------------------------------------------------
;;; Client-caused failures
;;; ---------------------------------------------------------------------------

(define-condition wl-protocol-error (server-error)
  ((client :initarg :client :reader wl-protocol-error-client)
   (object-id :initarg :object-id :initform nil :reader wl-protocol-error-object-id)
   (code :initarg :code :initform +error-invalid-method+
         :reader wl-protocol-error-code)
   (message :initarg :message :initform "" :reader wl-protocol-error-message))
  (:report (lambda (condition stream)
             (format stream "protocol error on object ~D (code ~D): ~A"
                     (or (wl-protocol-error-object-id condition) 1)
                     (wl-protocol-error-code condition)
                     (wl-protocol-error-message condition)))))

(defun protocol-error (client object-id code control &rest arguments)
  "Signal a client-caused protocol error; the connection layer turns it into
wl_display.error, a flush and a disconnect."
  (error 'wl-protocol-error
         :client client
         :object-id object-id
         :code code
         :message (apply #'format nil control arguments)))

(define-condition internal-error (server-error)
  ((client :initarg :client :initform nil :reader internal-error-client)
   (cause :initarg :cause :initform nil :reader internal-error-cause)))

;;; ---------------------------------------------------------------------------
;;; Logging
;;; ---------------------------------------------------------------------------

(defparameter *log-level* :info
  "One of :debug, :info, :warn, :error.  Nothing below this level is formatted
at all, so a hot path can log at :debug without paying for it.")

(defparameter *log-stream* *error-output*)

(defparameter +log-levels+ '((:debug . 0) (:info . 1) (:warn . 2) (:error . 3)))

(defun log-enabled-p (level)
  (>= (or (cdr (assoc level +log-levels+)) 1)
      (or (cdr (assoc *log-level* +log-levels+)) 1)))

(defun log-message (level control &rest arguments)
  "One line per event, with the level and the peer when there is one.

Formatted only when the level is enabled: a compositor at :info must not pay to
build strings for :debug messages it will throw away (docs/protocol-layer.md
§10)."
  (when (log-enabled-p level)
    (format *log-stream* "~&wayland-server [~(~A~)] ~?~%"
            level control arguments)
    (finish-output *log-stream*))
  nil)

(defun client-log (client level control &rest arguments)
  "A log line attributed to one client: its serial number and peer pid."
  (when (log-enabled-p level)
    (apply #'log-message level
           (concatenate 'string "client ~D (pid ~D): " control)
           (client-id client) (client-pid client) arguments))
  nil)
