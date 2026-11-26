;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Proxies: the client's objects, its id range, and the wire codec for
;;;; requests.
;;;;
;;;; A proxy is the client-side handle for an object that lives on the server.
;;;; The client chooses the id, so the id is the client's to allocate and to
;;;; reuse: ids start at 2 (1 is wl_display), run to +CLIENT-ID-MAX+, and come
;;;; back into circulation when the server says wl_display.delete_id
;;;; (docs/protocol-layer.md §3).
;;;;
;;;; Everything here is per message and per argument: the schema says what the
;;;; bytes are, this file turns Lisp values into them and back.

(in-package #:wayland.client)

;;; ---------------------------------------------------------------------------
;;; The client id range
;;; ---------------------------------------------------------------------------


;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition client-error (error)
  ((detail :initarg :detail :initform nil :reader client-error-detail))
  (:report (lambda (condition stream)
             (format stream "wayland client error~@[: ~A~]"
                     (client-error-detail condition)))))

(define-condition connection-failed (client-error)
  ((path :initarg :path :reader connection-failed-path)
   (cause :initarg :cause :reader connection-failed-cause))
  (:report (lambda (condition stream)
             (format stream "cannot connect to ~A: ~A"
                     (connection-failed-path condition)
                     (connection-failed-cause condition)))))

(define-condition protocol-error (client-error)
  ((interface :initarg :interface :initform nil :reader protocol-error-interface)
   (message :initarg :message :initform nil :reader protocol-error-message))
  (:report (lambda (condition stream)
             (format stream "protocol mismatch~@[ on ~A~]~@[: ~A~]"
                     (protocol-error-interface condition)
                     (protocol-error-message condition)))))

(define-condition display-error (client-error)
  ((object-id :initarg :object-id :reader display-error-object-id)
   (code :initarg :code :reader display-error-code)
   (message :initarg :message :reader display-error-message))
  (:report (lambda (condition stream)
             (format stream "compositor reported a protocol error: object ~D, code ~D: ~A"
                     (display-error-object-id condition)
                     (display-error-code condition)
                     (display-error-message condition)))))

(define-condition unknown-object (client-error)
  ((id :initarg :id :reader unknown-object-id)
   (opcode :initarg :opcode :initform nil :reader unknown-object-opcode))
  (:report (lambda (condition stream)
             (format stream
                     "event for object id ~D, which this client does not have~@[ (opcode ~D)~]"
                     (unknown-object-id condition)
                     (unknown-object-opcode condition)))))

(define-condition unknown-message (protocol-error) ())

(define-condition id-exhausted (client-error) ()
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream
                     "the client id range (2 .. ~D) is exhausted; the server never sent delete_id"
                     +client-id-max+))))

(define-condition destroyed-proxy (client-error)
  ((object :initarg :object :reader destroyed-proxy-object))
  (:report (lambda (condition stream)
             (format stream "object ~D (~A) was destroyed by the server"
                     (proxy-id (destroyed-proxy-object condition))
                     (interface-name (proxy-interface (destroyed-proxy-object condition)))))))

(define-condition roundtrip-timeout (client-error)
  ((seconds :initarg :seconds :reader roundtrip-timeout-seconds))
  (:report (lambda (condition stream)
             (format stream "no reply to the sync within ~,3F s"
                     (roundtrip-timeout-seconds condition)))))

;;; ---------------------------------------------------------------------------
;;; Which Lisp class speaks for an interface
;;; ---------------------------------------------------------------------------
;;
;; A bound global is a PROXY unless some client module says otherwise: wl_surface
;; has state and methods, wl_shm does not.  The table is keyed by wire name, and a
;; module registers itself at load time (there is no per-interface DEFCLASS the
;; schema could generate, because a class is behaviour, not schema).

(defvar *proxy-classes* (make-hash-table :test #'equal)
  "wire interface name -> the class REGISTER-PROXY instantiates for it.")

(defun register-proxy-class (interface class)
  "Make instances of INTERFACE (a name or a WL-INTERFACE) be of CLASS."
  (setf (gethash (interface-name (ensure-interface interface)) *proxy-classes*) class)
  class)

(defun proxy-class-for (interface)
  "The class a proxy for INTERFACE is made of: PROXY unless registered."
  (gethash (interface-name (ensure-interface interface)) *proxy-classes* 'proxy))

;;; ---------------------------------------------------------------------------
;;; The proxy
;;; ---------------------------------------------------------------------------

(defclass proxy ()
  ((display :initarg :display :initform nil :accessor proxy-display)
   (id :initarg :id :reader proxy-id)
   (interface :initarg :interface :reader proxy-interface)
   (version :initarg :version :initform 1 :reader proxy-version)
   ;; Handlers called as (HOOK EVENT-KEYWORD &rest ARGS); push onto this list.
   (hooks :initarg :hooks :initform nil :accessor proxy-hooks)
   (destroyed-p :initform nil :accessor proxy-destroyed-p))
  (:documentation
   "A client-side object.  Subclass it to give an interface behaviour; the
schema still owns the wire, so a subclass only adds state."))

(defun object-for-id (display id)
  "The proxy for ID, or NIL."
  (object-table-ref (display-objects display) id))

(defun clamp-version (interface version)
  "The version to speak: between 1 and the interface's own maximum.

libwayland keeps the version a client asked for and refuses anything above the
interface's; clamping is friendlier and is what wayflan does, so a client written
against a newer XML keeps working against an older compositor."
  (unless (and (integerp version) (plusp version))
    (error 'client-error
           :detail (format nil "interface version must be a positive integer, got ~S"
                           version)))
  (min version (interface-version interface)))

(defun ensure-interface (designator)
  "A WL-INTERFACE from a name, a symbol or an interface already resolved."
  (if (typep designator 'wl-interface)
      designator
      (resolve-interface designator)))

(defun register-proxy (display id interface &key (version 1) class)
  "Install a proxy for ID, whatever chose it.

An id the *server* introduced (wl_data_device.data_offer) carries no negotiated
version anywhere on the wire; DECODE-ARGUMENT passes the interface's own maximum,
which the server cannot exceed either.  CLASS defaults to what the interface
registered, so a server-chosen wl_pointer becomes a POINTER and not a bare proxy."
  (let* ((interface (ensure-interface interface))
         (class (or class (proxy-class-for interface)))
         (object (make-instance class
                                :display display
                                :id id
                                :interface interface
                                :version version)))
    (object-table-set (display-objects display) id object)
    object))

(defun allocate-id (display)
  "The lowest free client id: a returned one first, then the counter."
  (handler-case
      (allocate-client-id (display-objects display))
    (wayland.object:id-space-exhausted ()
      (error 'id-exhausted))))

(defun check-live (object)
  "Signal DESTROYED-PROXY unless OBJECT is still usable.

Request methods call this before allocating an id, so a call on a dead proxy
cannot leave a proxy behind in the table for an id the server has already
reused."
  (when (proxy-destroyed-p object)
    (error 'destroyed-proxy :object object))
  object)

(defun allocate-proxy (display interface &key (version 1) class)
  "Create a proxy for INTERFACE with a freshly allocated id."
  (let* ((interface (ensure-interface interface))
         (version (clamp-version interface version))
         (id (allocate-id display)))
    (register-proxy display id interface :version version :class class)))

(defun release-object (display id)
  "Forget the proxy for ID and offer the id for reuse.

Called on wl_display.delete_id, which the server sends after it has destroyed
an object the client created; after that event nothing may arrive for it again."
  (let ((object (object-table-remove (display-objects display) id)))
    (when object
      (setf (proxy-destroyed-p object) t)
      ;; Only the client's half is recyclable; RELEASE-CLIENT-ID checks the
      ;; range itself, so a server-chosen id can never collide with ours.
      (release-client-id (display-objects display) id)
      object)))

;;; ---------------------------------------------------------------------------
;;; The schema has the opcodes; these two read them safely
;;; ---------------------------------------------------------------------------

(defun interface-request (interface opcode)
  (let* ((interface (ensure-interface interface))
         (requests (interface-requests interface)))
    (or (and (< opcode (length requests)) (nth opcode requests))
        (error 'unknown-message
               :interface (interface-name interface)
               :message (format nil "no request with opcode ~D" opcode)))))

(defun interface-event (interface opcode)
  (let* ((interface (ensure-interface interface))
         (events (interface-events interface)))
    (or (and (< opcode (length events)) (nth opcode events))
        (error 'unknown-message
               :interface (interface-name interface)
               :message (format nil "no event with opcode ~D" opcode)))))

;;; ---------------------------------------------------------------------------
;;; Encoding a request
;;; ---------------------------------------------------------------------------

(defun encode-argument (buffer argument value)
  "Write VALUE for ARGUMENT into BUFFER, checking what the XML promised.

The checks are the ones the wire cannot make for us: a null object or string
where the protocol says non-null, a proxy where an id belongs, an array that is
not octets.  A wrong type here is a client bug, and finding it at the call site
beats decoding our own message from the compositor's error event."
  (let ((type (arg-type argument)))
    (ecase type
      (:int (put-int buffer value))
      (:uint (put-uint buffer value))
      (:fixed (put-fixed buffer value))
      (:string
       (unless (or (stringp value) (and (null value) (arg-allow-null argument)))
         (error 'client-error
                :detail (format nil "argument ~A: ~S is not a string~@[, and null is not allowed here~]"
                                (arg-name argument) value (null value))))
       (put-string buffer value))
      (:object
       (unless (or value (arg-allow-null argument))
         (error 'client-error
                :detail (format nil "argument ~A: null object, but the protocol says non-null"
                                (arg-name argument))))
       (put-object buffer (object-id-of value)))
      (:new-id
       (put-new-id buffer (object-id-of value)))
      (:array
       (put-array buffer (coerce-array value argument)))
      (:fd
       (unless (integerp value)
         (error 'client-error
                :detail (format nil "argument ~A: a file descriptor must be an integer, got ~S"
                                (arg-name argument) value)))
       (put-fd buffer value)))))

(defgeneric object-id-of (value)
  (:documentation
   "A proxy, a client-side buffer, or a raw id, as the u32 the wire wants.

A generic function rather than an ETYPECASE so that a module can teach the
encoder about the object it owns: a CLIENT-BUFFER is not a proxy, but attaching it
has to put its wl_buffer id on the wire, and the caller should not have to say so.")
  (:method ((value null)) nil)
  (:method ((value proxy)) (proxy-id value))
  (:method ((value integer)) value))

(defun coerce-array (value argument)
  (etypecase value
    (null nil)
    (vector value)
    (list
     (unless (every (lambda (octet) (typep octet '(unsigned-byte 8))) value)
       (error 'client-error
              :detail (format nil "argument ~A: array elements must be octets, got ~S"
                              (arg-name argument) value)))
     (coerce value '(vector (unsigned-byte 8))))))

(defun send-request (object request &rest arguments)
  "Encode REQUEST on OBJECT with wire ARGUMENTS, including any new_id.

Callers are the generated request methods (registry.lisp); they allocate ids
before calling, so the wire argument list is complete here."
  (check-live object)
  (let* ((display (proxy-display object))
         (buffer (display-output display))
         (specs (message-args request)))
    (unless (= (length specs) (length arguments))
      (error 'client-error
             :detail (format nil "~A.~A takes ~D argument~:P, got ~D"
                             (interface-name (proxy-interface object))
                             (message-name request)
                             (length specs) (length arguments))))
    (let ((start (begin-message buffer (proxy-id object) (message-opcode request))))
      (loop for spec in specs
            for value in arguments
            do (encode-argument buffer spec value))
      (end-message buffer start))
    request))

;;; ---------------------------------------------------------------------------
;;; Decoding an event
;;; ---------------------------------------------------------------------------

(defun decode-argument (argument display reader)
  "Read one event argument.

Object ids become proxies; an id this client does not know (the server may still
reference an object we have forgotten) is passed through as an integer, which a
hook can inspect and a method can compare with NIL-means-null.  A new_id becomes
a proxy registered under the id the server chose."
  (ecase (arg-type argument)
    (:int (read-int reader))
    (:uint (read-uint reader))
    (:fixed (read-fixed reader))
    (:string (read-string reader))
    (:object
     (let ((id (read-object reader)))
       (and id (or (object-for-id display id) id))))
    (:new-id
     ;; The server picked this id, so the object is created here rather than
     ;; allocated; see REGISTER-PROXY for why the version is the maximum.
     (let ((id (read-uint reader)))
       (unless (arg-interface argument)
         (error 'protocol-error
                :interface nil
                :message (format nil "event argument ~A is a new_id with no interface"
                                 (arg-name argument))))
       (register-proxy display id (arg-interface argument)
                       :version (interface-version
                                 (resolve-interface (arg-interface argument))))))
    (:array (read-array reader))
    (:fd (read-fd reader))))
