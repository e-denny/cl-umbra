;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cf.session: the seat, through libseat (docs/framework.md §2, PLAN.md phase 4).
;;;;
;;;; A compositor on a real display does not own its own devices.  The seat
;;;; provider (logind here, seatd on a machine that runs it) hands them out, takes
;;;; them back when the VT is switched away from, and gives them back when it
;;;; returns.  libseat is the small library that speaks that protocol, and this
;;;; module is the only place in the tree that calls it (D56).
;;;;
;;;; Three facts shape everything below.
;;;;
;;;;   1. The seat is not available when you open it.  It becomes available in a
;;;;      CALLBACK -- enable_seat -- and unavailable in another one.  Between the
;;;;      two, every device fd the provider gave you may be revoked.  So opening a
;;;;      seat is not `open a file', it is `subscribe to availability', and the
;;;;      state machine is the module's real content.
;;;;
;;;;   2. A disable has to be acknowledged.  The provider expects
;;;;      libseat_disable_seat() shortly after disable_seat fires, or it revokes
;;;;      the devices itself.  The order is: close our devices, then acknowledge,
;;;;      then tell the compositor.  Doing it the other way round means the
;;;;      compositor's own state says "closed" while the kernel still holds them.
;;;;
;;;;   3. The fd is for the connection, not for a device.  libseat_dispatch() on
;;;;      the connection fd is what runs the callbacks; a compositor that never
;;;;      dispatches never learns it has a seat.  That is why the gate dispatches
;;;;      once after opening, and why a real compositor puts this fd in its
;;;;      reactor like any other source.
;;;;
;;;; What is pure here is the state machine: availability in, availability out,
;;;; devices opened and closed in between.  What needs a seat is the eight
;;;; generics at the bottom of the file, and a test can stand a recording session
;;;; in their place -- the same seam cf.backend.drm uses for a recording card.

(in-package #:cl-user)

(in-package #:cf.session)

;;; ---------------------------------------------------------------------------
;;; The library
;;; ---------------------------------------------------------------------------
;;
;; Loaded here and nowhere else (D4: CFFI for kernel and driver APIs).  libseat
;; is a leaf: it takes a listener struct of two function pointers, and everything
;; else is opaque, so there is no ABI to transcribe beyond those two slots -- which
;; are asserted at load time anyway, because a listener struct of the wrong size
;; is a callback into the wrong address rather than a link error.

(cffi:define-foreign-library libseat
  (:unix (:or "libseat.so.1" "libseat.so")))

(cffi:use-foreign-library libseat)

(cffi:defcstruct libseat-seat-listener
  (enable-seat :pointer)
  (disable-seat :pointer))

;;; ---------------------------------------------------------------------------
;;; The calls
;;; ---------------------------------------------------------------------------

(cffi:defcfun ("libseat_open_seat" %open-seat-raw) :pointer
  (listener :pointer) (userdata :pointer))

(cffi:defcfun ("libseat_close_seat" %close-seat-raw) :int
  (seat :pointer))

(cffi:defcfun ("libseat_disable_seat" %disable-seat-raw) :int
  (seat :pointer))

(cffi:defcfun ("libseat_open_device" %open-device-raw) :int
  (seat :pointer) (path :string) (fd-out :pointer))

(cffi:defcfun ("libseat_close_device" %close-device-raw) :int
  (seat :pointer) (device-id :int))

(cffi:defcfun ("libseat_get_fd" %get-fd-raw) :int
  (seat :pointer))

(cffi:defcfun ("libseat_dispatch" %dispatch-raw) :int
  (seat :pointer) (timeout :int))

(cffi:defcfun ("libseat_switch_session" %switch-session-raw) :int
  (seat :pointer) (session :int))

(cffi:defcfun ("libseat_seat_name" %seat-name-raw) :pointer
  (seat :pointer))

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition session-error (error)
  ((operation :initarg :operation :reader session-error-operation)
   (error-number :initarg :errno :initform nil :reader session-error-errno)
   (path :initarg :path :initform nil :reader session-error-path))
  (:report (lambda (condition stream)
             (format stream "session ~A~@[ ~A~] failed~@[: ~A (errno ~D)~]"
                     (session-error-operation condition)
                     (session-error-path condition)
                     (and (session-error-errno condition)
                          (ffi:strerror (session-error-errno condition)))
                     (session-error-errno condition)))))

(define-condition session-not-enabled (session-error) ()
  (:documentation
   "A device was asked for while the seat was disabled.

The provider revokes device access on a VT switch, so this is not a bug in the
caller: it is the answer to a question asked at the wrong time.  A compositor
opens its devices in its on-enabled hook, which is the only moment the seat
promises they will stay open.")
  (:default-initargs :operation "open-device"))

;;; ---------------------------------------------------------------------------
;;; The session
;;; ---------------------------------------------------------------------------
;;
;; STATE is the machine, and it only ever moves :opening -> :enabled <-> :disabled
;; -> :closed.  Nothing else changes it, and every callback is a transition rather
;; than a pile of flags: a nested enable without a disable still counts, because
;; the count is evidence and the state is the truth.

(defclass session ()
  ((id :initarg :id :reader session-id)
   (name :initarg :name :initform "seat0" :reader session-name)
   (seat :initform (cffi:null-pointer) :accessor session-seat-pointer)
   (fd :initform -1 :accessor session-fd)
   (state :initform :opening :accessor session-state)
   ;; device id -> path.  The path is kept because a compositor reopening its
   ;; devices after a VT switch needs the names, not just the fds: the ids and the
   ;; fds from before the switch are gone.
   (devices :initform (make-hash-table) :reader session-devices)
   (on-enabled :initarg :on-enabled :initform '() :accessor session-on-enabled)
   (on-disabled :initarg :on-disabled :initform '() :accessor session-on-disabled)
   (enables :initform 0 :accessor session-enable-count)
   (disables :initform 0 :accessor session-disable-count)
   (dispatches :initform 0 :accessor session-dispatch-count)
   (failed-closes :initform 0 :accessor session-failed-closes)
   (callback-errors :initform '() :accessor session-callback-errors))
  (:documentation
   "One open seat.  Slots are the state machine; the generics below are the calls.

A SESSION is not reusable: once CLOSE-SESSION has run, its seat pointer is freed
and the object only remembers what happened."))

(defvar *sessions* (make-hash-table)
  "Session id -> session, for the C callbacks.

The callbacks cannot carry a Lisp object through C, so user_data is an integer
id and this table is the way back.  Registered before the seat is opened: logind
calls enable_seat from inside libseat_open_seat, and a registry filled afterwards
would miss the first -- and for an already-active session, only -- enable.")

(defvar *next-session-id* 0)

(defvar *seat-listener* (cffi:null-pointer)
  "The one listener struct, allocated on first use and never freed.

It has no per-seat state: the two callbacks find the session through *SESSIONS*,
so a second seat needs a second id, not a second listener.")

(defun session-for-id (id)
  (gethash id *sessions*))

(defun session-for-pointer (pointer)
  (session-for-id (cffi:pointer-address pointer)))

(defun %userdata (session)
  (cffi:make-pointer (session-id session)))

;;; ---------------------------------------------------------------------------
;;; The callbacks
;;; ---------------------------------------------------------------------------
;;
;; These run inside libseat's dispatch, so an error escaping them would unwind
;; through C.  They therefore record rather than signal: a session that could not
;; close a device during a disable is a session whose state machine still worked
;; and whose accounting says so (SESSION-FAILED-CLOSES).

(cffi:defcallback %enable-seat-callback :void ((seat :pointer) (userdata :pointer))
  (declare (ignore seat))
  (let ((session (session-for-pointer userdata)))
    (when session
      (handler-case (note-seat-enabled session)
        (error (condition) (push condition (session-callback-errors session)))))))

(cffi:defcallback %disable-seat-callback :void ((seat :pointer) (userdata :pointer))
  (declare (ignore seat))
  (let ((session (session-for-pointer userdata)))
    (when session
      (handler-case (note-seat-disabled session)
        (error (condition) (push condition (session-callback-errors session)))))))

(defun listener ()
  "The listener struct, with both callbacks installed on first use."
  (when (cffi:null-pointer-p *seat-listener*)
    (let ((struct (cffi:foreign-alloc '(:struct libseat-seat-listener))))
      (setf (cffi:foreign-slot-value struct '(:struct libseat-seat-listener) 'enable-seat)
            (cffi:callback %enable-seat-callback)
            (cffi:foreign-slot-value struct '(:struct libseat-seat-listener) 'disable-seat)
            (cffi:callback %disable-seat-callback))
      ;; Every seat shares it, so it is allocated once for the image's lifetime.
      (setf *seat-listener* struct)))
  *seat-listener*)

;;; ---------------------------------------------------------------------------
;;; The state machine
;;; ---------------------------------------------------------------------------

(defun session-enabled-p (session)
  (eq (session-state session) :enabled))

(defun session-disabled-p (session)
  (eq (session-state session) :disabled))

(defun session-closed-p (session)
  (eq (session-state session) :closed))

(defun session-open-device-count (session)
  (hash-table-count (session-devices session)))

(defun session-device-paths (session)
  "The paths of the devices the seat has open, in no particular order.

A list rather than the table, because a caller reopening devices after a VT
switch walks it and the table's internal order is nobody's business."
  (loop for path being the hash-values of (session-devices session) collect path))

(defun session-state-string (session)
  (ecase (session-state session)
    (:opening "opening")
    (:enabled "enabled")
    (:disabled "disabled")
    (:closed "closed")))

(defun %call-hook (hook session)
  "Call a user hook, recording rather than propagating its error.

A hook is where a compositor reopens its devices.  If it fails, the seat is still
enabled and the session is still ours; turning that into a C-unwinding error
would lose both facts."
  (when hook
    (handler-case (funcall hook session)
      (error (condition) (push condition (session-callback-errors session))))))

(defun %call-hooks (hooks session)
  "Call every hook in HOOKS, in the order they were added, recording failures.

One hook that fails does not stop the next: a compositor whose output cannot come
back should still get its input back, and the failures are all in
SESSION-CALLBACK-ERRORS where they can be read after the switch."
  (dolist (hook hooks)
    (%call-hook hook session)))

(defun add-session-enable-hook (session function)
  "Add FUNCTION as an on-enabled hook; it runs after the ones already added.

There is more than one thing that has to happen when a seat comes back -- a
compositor's card is reprogrammed and its input devices are reopened -- and they
are different modules' business, so the hook is a list rather than a slot.  A hook
added while the seat is already enabled is not called here: the caller that adds it
checks SESSION-ENABLED-P and does the work itself, because it is the caller that
knows whether the work has been done."
  (check-type function function)
  (setf (session-on-enabled session)
        (append (session-on-enabled session) (list function)))
  session)

(defun add-session-disable-hook (session function)
  "Add FUNCTION as an on-disabled hook; it runs after the ones already added."
  (check-type function function)
  (setf (session-on-disabled session)
        (append (session-on-disabled session) (list function)))
  session)

(defun remove-session-enable-hook (session function)
  "Remove FUNCTION from the on-enabled hooks; returns T when it was there.

Only the module that added a hook removes it.  The reason to have this at all is
that the module's destructor cannot be the compositor's: the compositor keeps the
session and throws away the output."
  (let ((hooks (session-on-enabled session)))
    (setf (session-on-enabled session) (remove function hooks))
    (not (eq hooks (session-on-enabled session)))))

(defun remove-session-disable-hook (session function)
  "Remove FUNCTION from the on-disabled hooks; returns T when it was there."
  (let ((hooks (session-on-disabled session)))
    (setf (session-on-disabled session) (remove function hooks))
    (not (eq hooks (session-on-disabled session)))))

(defun note-seat-enabled (session)
  "The seat became usable: state :enabled, then the hook (which opens devices).

State first, deliberately: a hook that opens a device has to find the seat
enabled, or OPEN-SESSION-DEVICE would refuse it."
  (when (session-closed-p session)
    (return-from note-seat-enabled nil))
  (incf (session-enable-count session))
  (setf (session-state session) :enabled)
  (%call-hooks (session-on-enabled session) session)
  t)

(defun note-seat-disabled (session)
  "The seat is going away: close devices, acknowledge, then the hook.

The order matters and libseat's header says why: a disable not acknowledged
promptly is a disable the provider enforces by revoking the fds, and a device we
close after the provider revoked it is a close that reports EBADF."
  (when (session-closed-p session)
    (return-from note-seat-disabled nil))
  (incf (session-disable-count session))
  (setf (session-state session) :disabled)
  (close-all-session-devices session)
  (handler-case (%acknowledge-disable session)
    (error (condition) (push condition (session-callback-errors session))))
  (%call-hooks (session-on-disabled session) session)
  t)

(defun close-all-session-devices (session)
  "Close every device the seat holds, counting the closes that failed.

Idempotent, and safe to call on a disabled seat: it is the first thing a disable
does and the first thing a close does."
  (let ((ids '()))
    (maphash (lambda (id path) (declare (ignore path)) (push id ids))
             (session-devices session))
    (dolist (id ids)
      (close-session-device session id))
    (clrhash (session-devices session))
    ids))

;;; ---------------------------------------------------------------------------
;;; The contract
;;; ---------------------------------------------------------------------------

(defun open-session (&key (name "seat0") (dispatch-timeout 0)
                          on-enabled on-disabled (class 'session) (initargs nil))
  "Open the seat called NAME and return the session.

ON-ENABLED is called whenever the seat becomes usable -- during this call for an
already-active session, and again after every VT switch back -- and ON-DISABLED
when it goes away.  Both take the session and both are called with the state
already updated, so a hook can ask SESSION-ENABLED-P and get the truth.  Further
hooks are added with ADD-SESSION-ENABLE-HOOK and ADD-SESSION-DISABLE-HOOK; a module
that owns devices the seat hands out registers its own rather than wrapping this
one, and the last-registered hook runs last.

CLASS is the class to instantiate: 'SESSION in production, a subclass in a test
that replaces the eight calls (the same seam cf.backend.drm offers a recording
card).  INITARGS is a plist applied to that class, so a subclass can carry state
of its own from the moment the seat is opened.

DISPATCH-TIMEOUT is passed to one non-blocking dispatch before returning: the
seatd backend reports availability only through dispatch, and a caller that never
dispatches would otherwise be told nothing.  0 (the default) never waits."
  (let* ((id (incf *next-session-id*))
         (session (apply #'make-instance class
                         :id id :name name
                         :on-enabled (if on-enabled (list on-enabled) '())
                         :on-disabled (if on-disabled (list on-disabled) '())
                         initargs)))
    ;; Registered before the open call: see *SESSIONS*.
    (setf (gethash id *sessions*) session)
    (handler-case
        (progn
          (setf (session-seat-pointer session) (%open-seat session)
                (session-fd session) (%seat-fd session))
          (when (plusp dispatch-timeout)
            (dispatch-session session :timeout dispatch-timeout))
          (dispatch-session session)
          session)
      (error (condition)
        ;; A seat opened and a later step failed: the pointer is freed here, or the
        ;; seat connection outlives the object that owned it.
        (remhash id *sessions*)
        (setf (session-state session) :closed)
        (let ((seat (session-seat-pointer session)))
          (when (and seat (not (cffi:null-pointer-p seat)))
            (handler-case (%close-seat session) (error () nil))))
        (error condition)))))

(defun close-session (session)
  "Close every device, then the seat.  Idempotent."
  (unless (session-closed-p session)
    (close-all-session-devices session)
    (setf (session-state session) :closed)
    (remhash (session-id session) *sessions*)
    ;; Unconditional: a session that opened a seat has one to close, and a null
    ;; pointer here means the open already failed (the state would be :closed).
    (%close-seat session))
  t)

(defun dispatch-session (session &key (timeout 0))
  "Run the libseat connection once: :event when it did work, :none when it did not.

Callbacks fire inside this call, which is why it returns after them rather than
before: a caller that opens a device immediately after a :event dispatch knows the
enable hook has already run."
  (incf (session-dispatch-count session))
  (let ((result (%dispatch session timeout)))
    (if (plusp result) :event :none)))

(defun open-session-device (session path)
  "Open PATH through the seat; returns (values fd device-id).

Signals SESSION-NOT-ENABLED when the seat is disabled: the provider has revoked
the device and a compositor's only correct response is to wait for its on-enabled
hook."
  (unless (session-enabled-p session)
    (error 'session-not-enabled :path path :errno ffi:+ebusy+))
  (multiple-value-bind (fd id) (%open-device session path)
    (setf (gethash id (session-devices session)) path)
    (values fd id)))

(defun close-session-device (session id)
  "Close device ID through the seat.  Returns T when it was open, NIL when not.

Unknown ids are not an error: a disable may already have removed it, and a close
that arrives twice is a caller being tidy rather than a caller being wrong."
  (multiple-value-bind (path known-p) (gethash id (session-devices session))
    (declare (ignore path))
    (when known-p
      (remhash id (session-devices session))
      (handler-case (%close-device session id)
        (error () (incf (session-failed-closes session)))))
    known-p))

(defun switch-session-to (session vt)
  "Ask the provider to switch to VT VT.  The switch is not guaranteed."
  (%switch-session session vt))

;;; ---------------------------------------------------------------------------
;;; The eight calls that need a seat
;;; ---------------------------------------------------------------------------
;;
;; One generic function per libseat entry point this module uses, all dispatching
;; on the session.  A test subclasses SESSION, replaces these, and gets the state
;; machine with no library and no logind -- the same shape as
;; cf.backend.drm's kernel-call generics, and the reason the machine above has
;; unit tests at all.

(defgeneric %open-seat (session)
  (:documentation "Open the seat; return the libseat pointer or signal."))

(defgeneric %close-seat (session)
  (:documentation "Free the seat pointer."))

(defgeneric %acknowledge-disable (session)
  (:documentation "Acknowledge a disable_seat callback to the provider."))

(defgeneric %open-device (session path)
  (:documentation "Open PATH through the seat; (values fd device-id)."))

(defgeneric %close-device (session id)
  (:documentation "Close device ID through the seat."))

(defgeneric %dispatch (session timeout)
  (:documentation "Read the seat connection; positive when it did work."))

(defgeneric %switch-session (session vt)
  (:documentation "Ask for a switch to VT."))

(defgeneric %seat-fd (session)
  (:documentation "The pollable fd of the seat connection."))

;;; ---------------------------------------------------------------------------
;;; The real methods
;;; ---------------------------------------------------------------------------

(defmethod %open-seat ((session session))
  (let ((seat (%open-seat-raw (listener) (%userdata session))))
    (when (cffi:null-pointer-p seat)
      ;; ENODEV/ENOENT here is "no seat provider answered" -- no seatd socket and
      ;; no logind -- which is the skip case the gate and a compositor have to
      ;; tell apart from a permission problem.
      (error 'session-error :operation "open-seat" :errno (ffi:errno)))
    seat))

(defmethod %close-seat ((session session))
  (when (cffi:null-pointer-p (session-seat-pointer session))
    (return-from %close-seat nil))
  (when (minusp (%close-seat-raw (session-seat-pointer session)))
    (error 'session-error :operation "close-seat" :errno (ffi:errno)))
  t)

(defmethod %acknowledge-disable ((session session))
  (when (minusp (%disable-seat-raw (session-seat-pointer session)))
    (error 'session-error :operation "acknowledge-disable" :errno (ffi:errno)))
  t)

(defmethod %open-device ((session session) path)
  (cffi:with-foreign-object (fd :int)
    (let ((id (%open-device-raw (session-seat-pointer session) path fd)))
      (when (minusp id)
        (error 'session-error :operation "open-device" :path path :errno (ffi:errno)))
      (values (cffi:mem-ref fd :int) id))))

(defmethod %close-device ((session session) id)
  (when (minusp (%close-device-raw (session-seat-pointer session) id))
    (error 'session-error :operation "close-device" :errno (ffi:errno)))
  t)

(defmethod %dispatch ((session session) timeout)
  (let ((result (%dispatch-raw (session-seat-pointer session) timeout)))
    (when (minusp result)
      (error 'session-error :operation "dispatch" :errno (ffi:errno)))
    result))

(defmethod %switch-session ((session session) vt)
  (when (minusp (%switch-session-raw (session-seat-pointer session) vt))
    (error 'session-error :operation "switch-session" :errno (ffi:errno)))
  t)

(defmethod %seat-fd ((session session))
  (let ((fd (%get-fd-raw (session-seat-pointer session))))
    (when (minusp fd)
      (error 'session-error :operation "seat-fd" :errno (ffi:errno)))
    fd))

(defun session-seat-name (session)
  "The seat's name as libseat reports it, or SESSION-NAME when it cannot be read.

libseat_seat_name returns memory owned by the seat and valid only while it is
open, so it is copied here rather than kept."
  (let ((seat (session-seat-pointer session)))
    (if (or (session-closed-p session) (cffi:null-pointer-p seat))
        (session-name session)
        (let ((string (%seat-name-raw seat)))
          (if (cffi:null-pointer-p string)
              (session-name session)
              (cffi:foreign-string-to-lisp string))))))
