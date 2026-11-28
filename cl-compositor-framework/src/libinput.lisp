;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cf.backend.libinput: devices into events, events into the seat
;;;; (docs/framework.md §2, PLAN.md phase 4).
;;;;
;;;; libinput is the part of the stack that knows what a trackpad is.  It owns
;;;; the heuristics -- acceleration, tap-to-click, disable-while-typing, the
;;;; button that means "middle" on a two-button touchpad -- and it hands back one
;;;; flat stream of events: a key with its evdev code, a motion delta, a button, a
;;;; scroll value.  Everything above it works in output coordinates, keysym names
;;;; and Wayland serials, so this module is exactly the translation between the
;;;; two, plus the two pieces of state a translation needs (where the pointer is,
;;;; and which devices are open).
;;;;
;;;; Three facts shape it.
;;;;
;;;;   1. libinput does not open devices itself; it calls back.  open_restricted
;;;;      returns a descriptor (or a negative errno), close_restricted gives it
;;;;      back.  That is the hook a seat plugs into (cf.session), and it is also
;;;;      why this module works without one: with the `input' group, opening the
;;;;      path directly is the same call to open(2), and libinput cannot tell.
;;;;
;;;;   2. The context has a descriptor, not the devices.  libinput_get_fd() is
;;;;      pollable, and libinput_dispatch() moves events from the devices into the
;;;;      queue; only then does libinput_get_event() return anything, and every
;;;;      event returned has to be destroyed.  A compositor that never dispatches
;;;;      gets no input at all, which is the same shape as the seat connection.
;;;;
;;;;   3. Deltas are not positions.  A mouse reports how far it moved; the
;;;;      compositor's seat wants where the pointer is, in output pixels.  The
;;;;      accumulation and the clamp to the output are therefore ours, and they are
;;;;      the part with unit tests (tests/unit/libinput.lisp) because they are
;;;;      arithmetic, not a device.
;;;;
;;;; What is deliberate here, and stated again in D56: the legacy
;;;; LIBINPUT_EVENT_POINTER_AXIS is ignored.  Since libinput 1.19 every scroll is
;;;; also delivered as one of SCROLL_WHEEL / SCROLL_FINGER / SCROLL_CONTINUOUS,
;;;; and the legacy event is documented as sent *in addition* to them, so reading
;;;; both means scrolling twice as fast as the finger moved.

(in-package #:cl-user)

(in-package #:cf.backend.libinput)

;;; ---------------------------------------------------------------------------
;;; The libraries
;;; ---------------------------------------------------------------------------
;;
;; libinput is loaded here and nowhere else.  libudev is loaded on first use
;; rather than at load time: a path context (libinput_path_create_context) does
;; not need udev at all, and a machine without it can still run a compositor
;; against a named device -- which is what the gate's virtual keyboard uses.

(cffi:define-foreign-library libinput
  (:unix (:or "libinput.so.10" "libinput.so")))

(cffi:define-foreign-library libudev
  (:unix (:or "libudev.so.1" "libudev.so")))

(cffi:use-foreign-library libinput)

;;; ---------------------------------------------------------------------------
;;; Structs and constants
;;; ---------------------------------------------------------------------------
;;
;; Both are two slots of one field each; the sizes are asserted at load time
;; because an interface struct of the wrong shape is a callback into whatever
;; follows it in memory.

(cffi:defcstruct libinput-interface
  (open-restricted :pointer)
  (close-restricted :pointer))

;; The event-type numbers are libinput's ABI: stable, documented in
;; libinput.h, and never renumbered.  Only the ones this module reads are listed.
(defconstant +event-none+ 0)
(defconstant +event-device-added+ 1)
(defconstant +event-device-removed+ 2)
(defconstant +event-keyboard-key+ 300)
(defconstant +event-pointer-motion+ 400)
(defconstant +event-pointer-motion-absolute+ 401)
(defconstant +event-pointer-button+ 402)
(defconstant +event-pointer-axis+ 403)
(defconstant +event-pointer-scroll-wheel+ 404)
(defconstant +event-pointer-scroll-finger+ 405)
(defconstant +event-pointer-scroll-continuous+ 406)

(defconstant +cap-keyboard+ 0)
(defconstant +cap-pointer+ 1)
(defconstant +cap-touch+ 2)

(defconstant +key-released+ 0)
(defconstant +key-pressed+ 1)
(defconstant +button-released+ 0)
(defconstant +button-pressed+ 1)

(defconstant +axis-vertical+ 0)
(defconstant +axis-horizontal+ 1)

(defconstant +tap-disabled+ 0)
(defconstant +tap-enabled+ 1)

;;; ---------------------------------------------------------------------------
;;; The calls
;;; ---------------------------------------------------------------------------

;; contexts
(cffi:defcfun ("libinput_udev_create_context" %udev-create-context) :pointer
  (interface :pointer) (userdata :pointer) (udev :pointer))

(cffi:defcfun ("libinput_udev_assign_seat" %udev-assign-seat) :int
  (context :pointer) (seat-id :string))

(cffi:defcfun ("libinput_path_create_context" %path-create-context) :pointer
  (interface :pointer) (userdata :pointer))

(cffi:defcfun ("libinput_path_add_device" %path-add-device) :pointer
  (context :pointer) (path :string))

(cffi:defcfun ("libinput_get_fd" %get-fd) :int
  (context :pointer))

(cffi:defcfun ("libinput_dispatch" %dispatch) :int
  (context :pointer))

(cffi:defcfun ("libinput_get_event" %get-event) :pointer
  (context :pointer))

(cffi:defcfun ("libinput_event_get_type" %event-get-type) :int
  (event :pointer))

(cffi:defcfun ("libinput_event_destroy" %event-destroy) :void
  (event :pointer))

;; libinput 1.x frees a context by dropping the last reference; there is no
;; libinput_destroy any more, and its absence is a link error rather than a
;; silent behavioural difference.
(cffi:defcfun ("libinput_unref" %unref) :pointer
  (context :pointer))

(cffi:defcfun ("libinput_suspend" %suspend) :void
  (context :pointer))

(cffi:defcfun ("libinput_resume" %resume) :int
  (context :pointer))

;; devices
(cffi:defcfun ("libinput_event_get_device" %event-get-device) :pointer
  (event :pointer))

(cffi:defcfun ("libinput_device_get_name" %device-get-name) :pointer
  (device :pointer))

(cffi:defcfun ("libinput_device_get_sysname" %device-get-sysname) :pointer
  (device :pointer))

(cffi:defcfun ("libinput_device_get_id_vendor" %device-get-id-vendor) :uint
  (device :pointer))

(cffi:defcfun ("libinput_device_get_id_product" %device-get-id-product) :uint
  (device :pointer))

(cffi:defcfun ("libinput_device_has_capability" %device-has-capability) :int
  (device :pointer) (capability :int))

(cffi:defcfun ("libinput_device_config_tap_get_finger_count"
               %device-tap-get-finger-count) :int
  (device :pointer))

(cffi:defcfun ("libinput_device_config_tap_set_enabled" %device-tap-set-enabled) :int
  (device :pointer) (state :int))

(cffi:defcfun ("libinput_device_config_scroll_has_natural_scroll"
               %device-has-natural-scroll) :int
  (device :pointer))

(cffi:defcfun ("libinput_device_config_scroll_set_natural_scroll_enabled"
               %device-set-natural-scroll) :int
  (device :pointer) (enabled :int))

;; keyboard events
(cffi:defcfun ("libinput_event_keyboard_get_key" %keyboard-get-key) :uint
  (event :pointer))

(cffi:defcfun ("libinput_event_keyboard_get_key_state" %keyboard-get-key-state) :int
  (event :pointer))

;; pointer events
(cffi:defcfun ("libinput_event_pointer_get_dx" %pointer-get-dx) :double
  (event :pointer))

(cffi:defcfun ("libinput_event_pointer_get_dy" %pointer-get-dy) :double
  (event :pointer))

(cffi:defcfun ("libinput_event_pointer_get_absolute_x_transformed"
               %pointer-get-absolute-x) :double
  (event :pointer) (width :uint32))

(cffi:defcfun ("libinput_event_pointer_get_absolute_y_transformed"
               %pointer-get-absolute-y) :double
  (event :pointer) (height :uint32))

(cffi:defcfun ("libinput_event_pointer_get_button" %pointer-get-button) :uint
  (event :pointer))

(cffi:defcfun ("libinput_event_pointer_get_button_state"
               %pointer-get-button-state) :int
  (event :pointer))

(cffi:defcfun ("libinput_event_pointer_has_axis" %pointer-has-axis) :int
  (event :pointer) (axis :int))

(cffi:defcfun ("libinput_event_pointer_get_scroll_value" %pointer-get-scroll-value) :double
  (event :pointer) (axis :int))

;; udev
(cffi:defcfun ("udev_new" %udev-new) :pointer)
(cffi:defcfun ("udev_unref" %udev-unref) :pointer (udev :pointer))

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition input-error (error)
  ((operation :initarg :operation :reader input-error-operation)
   (detail :initarg :detail :initform nil :reader input-error-detail))
  (:report (lambda (condition stream)
             (format stream "input: ~A failed~@[: ~A~]"
                     (input-error-operation condition)
                     (input-error-detail condition)))))

;;; ---------------------------------------------------------------------------
;;; The pure half: event classification
;;; ---------------------------------------------------------------------------

(defparameter +event-kinds+
  '((1 . :device-added)
    (2 . :device-removed)
    (300 . :keyboard-key)
    (400 . :motion)
    (401 . :motion-absolute)
    (402 . :button)
    ;; 403 is the legacy axis event, deliberately absent: since libinput 1.19 the
    ;; same scroll also arrives as 404-406, and the header says the legacy event is
    ;; sent in addition.  Both would scroll twice as far as the finger moved.
    (404 . :scroll-wheel)
    (405 . :scroll-finger)
    (406 . :scroll-continuous))
  "libinput event type -> what this module does with it.  Unlisted types are
counted as ignored, not as errors: a device may report touch, gestures or
switches that this slice does not decode yet.")

(defun event-kind (type)
  "The keyword for a libinput event TYPE, or NIL when the type is not decoded."
  (cdr (assoc type +event-kinds+)))

(defparameter +buttons+
  '((#x110 . :left) (#x111 . :right) (#x112 . :middle)
    (#x113 . :side) (#x114 . :extra))
  "evdev button code -> the name a composer's policy switches on.")

(defun button-name (code)
  "The keyword for an evdev button CODE, or CODE itself when it has no name."
  (or (cdr (assoc code +buttons+)) code))

(defun key-state-keyword (state)
  (if (= state +key-pressed+) :pressed :released))

(defun button-state-keyword (state)
  (if (= state +button-pressed+) :pressed :released))

(defun axis-keyword (axis)
  "The keyword for a scroll AXIS number: 0 vertical, 1 horizontal (libinput's ABI)."
  (case axis
    (0 :vertical)
    (1 :horizontal)
    (t nil)))

(defstruct (raw-event (:constructor make-raw-event))
  "One libinput event, read out of C and translated into Lisp terms.

This is the boundary the unit tests stand on: everything downstream of it (pointer
accumulation, clamping, key naming, what the sink is told) is ordinary Lisp, and a
test can construct these without a device, a descriptor or a library."
  (type 0 :type integer)
  (kind nil)
  (key 0 :type integer)
  (key-state nil)
  (dx 0d0 :type double-float)
  (dy 0d0 :type double-float)
  (absolute-x 0d0 :type double-float)
  (absolute-y 0d0 :type double-float)
  (button 0 :type integer)
  (button-state nil)
  (axis nil)
  (value 0d0 :type double-float)
  (device nil))

;;; ---------------------------------------------------------------------------
;;; Where the pointer is
;;; ---------------------------------------------------------------------------

(defun clamp-coordinate (value limit)
  "Clamp VALUE into [0, LIMIT-1] as an integer, or 0 when there is no output yet.

The same rule as the framework's own clamp (D47), applied to the position the
device implies rather than to a grab's copy of it."
  (if (or (null limit) (not (plusp limit)))
      0
      (max 0 (min (round value) (1- limit)))))

(defun accumulate-pointer (driver dx dy)
  "Move the driver's pointer by (DX, DY) and return the clamped position.

Clamped to the output, not allowed to wander: a pointer pushed past an edge and
brought back must come back from the edge, not from 3000 pixels outside it, or the
first motion after a long drag teleports."
  (let* ((width (input-driver-width driver))
         (height (input-driver-height driver))
         (x (clamp-coordinate (+ (input-driver-pointer-x driver) dx) width))
         (y (clamp-coordinate (+ (input-driver-pointer-y driver) dy) height)))
    (setf (input-driver-pointer-x driver) x
          (input-driver-pointer-y driver) y)
    (values x y)))

;;; ---------------------------------------------------------------------------
;;; The driver
;;; ---------------------------------------------------------------------------

(defclass input-driver ()
  ((id :initarg :id :reader input-driver-id)
   (compositor :initarg :compositor :initform nil :reader input-driver-compositor)
   (context :initform (cffi:null-pointer) :accessor input-driver-context)
   (udev :initform (cffi:null-pointer) :accessor input-driver-udev)
   (interface :initform (cffi:null-pointer) :accessor input-driver-interface)
   ;; A cf.session:session when devices are opened through a seat, NIL when they
   ;; are opened directly.  Both are the same open(2) to libinput.
   (session :initarg :session :initform nil :accessor input-driver-session)
   (sink :initarg :sink :accessor input-driver-sink
         :documentation "Function of (kind payload); see DELIVER.")
   (width :initarg :width :initform 0 :accessor input-driver-width)
   (height :initarg :height :initform 0 :accessor input-driver-height)
   (pointer-x :initform 0 :accessor input-driver-pointer-x)
   (pointer-y :initform 0 :accessor input-driver-pointer-y)
   (devices :initform (make-hash-table :test #'equal) :reader input-driver-devices)
   ;; fd -> device id (through a seat) or T (opened directly).  close_restricted
   ;; only gets the fd back, so this is the only way to a seat's device id.
   (open-fds :initform (make-hash-table) :reader input-driver-open-fds)
   (source :initform nil :accessor input-driver-source)
   (suspended-p :initform nil :accessor input-driver-suspended-p)
   (events :initform 0 :accessor input-driver-event-count)
   (keys :initform 0 :accessor input-driver-key-count)
   (motions :initform 0 :accessor input-driver-motion-count)
   (buttons :initform 0 :accessor input-driver-button-count)
   (axes :initform 0 :accessor input-driver-axis-count)
   (ignored :initform 0 :accessor input-driver-ignored-count)
   (unknown-keys :initform 0 :accessor input-driver-unknown-key-count)
   (added :initform 0 :accessor input-driver-device-added-count)
   (removed :initform 0 :accessor input-driver-device-removed-count)
   (config-applied :initform 0 :accessor input-driver-config-applied-count)
   (callback-errors :initform '() :accessor input-driver-callback-errors))
  (:documentation
   "A libinput context and the state that turns its stream into seat traffic.

One driver per seat.  DEVICES maps a device's sysname to what was learned about
it, and the order of the plist in that table is the order the log prints."))

(defvar *drivers* (make-hash-table)
  "Driver id -> driver, for the two interface callbacks.  Same trick as
cf.session's *SESSIONS*: an integer travels through C as user_data.")

(defvar *next-driver-id* 0)

(defun driver-for-pointer (pointer)
  (gethash (cffi:pointer-address pointer) *drivers*))

(defun %driver-userdata (driver)
  (cffi:make-pointer (input-driver-id driver)))

;;; ---------------------------------------------------------------------------
;;; The interface libinput calls back into
;;; ---------------------------------------------------------------------------

(defun %open-restricted (driver path flags)
  "Open PATH for libinput and return a descriptor, or a negative errno.

libinput's contract: on failure return -errno rather than signalling.  Through a
seat the descriptor belongs to the seat; directly it is ours, and either way
close_restricted gets only the fd back, so the fd -> what-opened-it map is kept
here."
  (handler-case
      (let ((fd (if (and (input-driver-session driver)
                         (session:session-enabled-p (input-driver-session driver)))
                    (multiple-value-bind (fd id)
                        (session:open-session-device (input-driver-session driver) path)
                      (setf (gethash fd (input-driver-open-fds driver)) id)
                      fd)
                    (let ((fd (ffi:open-path path :direction :io :nonblock t)))
                      (setf (gethash fd (input-driver-open-fds driver)) t)
                      fd))))
        (declare (ignore flags))
        fd)
    (ffi:io-error (condition)
      (- (ffi:io-error-errno condition)))
    (session:session-error (condition)
      (- (or (session:session-error-errno condition) ffi:+eacces+)))))

(defun %close-restricted (driver fd)
  "Give a descriptor back: to the seat when it came from one, to close(2) when not."
  (multiple-value-bind (owner known-p) (gethash fd (input-driver-open-fds driver))
    (when known-p
      (remhash fd (input-driver-open-fds driver))
      (if (eq owner t)
          (handler-case (ffi:close-fd fd) (error () nil))
          (when (and (input-driver-session driver)
                     (session:session-enabled-p (input-driver-session driver)))
            (session:close-session-device (input-driver-session driver) owner))))))

(defun %interface ()
  "A fresh interface struct, with both callbacks installed.

Allocated per driver, even though the two callbacks are the same functions: the
user_data pointer that tells them which driver is calling comes from the context,
not from the struct, so nothing about the struct is per-driver -- but a shared one
would be freed by the first driver to close."
  (let ((struct (cffi:foreign-alloc '(:struct libinput-interface))))
    (setf (cffi:foreign-slot-value struct '(:struct libinput-interface) 'open-restricted)
          (cffi:get-callback 'open-restricted-callback)
          (cffi:foreign-slot-value struct '(:struct libinput-interface) 'close-restricted)
          (cffi:get-callback 'close-restricted-callback))
    struct))

(cffi:defcallback open-restricted-callback :int
    ((path :pointer) (flags :int) (userdata :pointer))
  (let ((driver (driver-for-pointer userdata)))
    (if (null driver)
        (- ffi:+eacces+)
        (handler-case
            (%open-restricted driver (cffi:foreign-string-to-lisp path) flags)
          (error (condition)
            (push condition (input-driver-callback-errors driver))
            (- ffi:+eacces+))))))

(cffi:defcallback close-restricted-callback :void ((fd :int) (userdata :pointer))
  (let ((driver (driver-for-pointer userdata)))
    (when driver
      (handler-case (%close-restricted driver fd)
        (error (condition) (push condition (input-driver-callback-errors driver)))))))

;;; ---------------------------------------------------------------------------
;;; What an event becomes
;;; ---------------------------------------------------------------------------

(defun deliver (driver kind payload)
  "Hand KIND and PAYLOAD to the driver's sink.

The sink is a function, not a generic function, because it is a *policy* seam (a
compositor's seat, a test's recording list) rather than an implementation seam
like the kernel calls.  A sink that signals is recorded, not propagated: input
decoding must not stop because a compositor's policy objected to one event."
  (handler-case (funcall (input-driver-sink driver) kind payload)
    (error (condition) (push condition (input-driver-callback-errors driver))))
  kind)

(defun device-info (device)
  "A plist describing a libinput device, copied out while the event is alive.

Nothing here keeps the device pointer: libinput's device objects are refcounted,
and the event that carried this one is destroyed as soon as the handler returns."
  (let ((name (%device-get-name device))
        (sysname (%device-get-sysname device))
        (caps '()))
    (when (plusp (%device-has-capability device +cap-keyboard+)) (push :keyboard caps))
    (when (plusp (%device-has-capability device +cap-pointer+)) (push :pointer caps))
    (when (plusp (%device-has-capability device +cap-touch+)) (push :touch caps))
    (list :name (if (cffi:null-pointer-p name) "" (cffi:foreign-string-to-lisp name))
          :sysname (if (cffi:null-pointer-p sysname) "" (cffi:foreign-string-to-lisp sysname))
          :vendor (%device-get-id-vendor device)
          :product (%device-get-id-product device)
          :caps (nreverse caps))))

(defun configure-device (driver device)
  "Apply the framework's defaults to DEVICE: tap-to-click and natural scrolling.

Both are `enabled when the device can', which is libinput's own default for taps
on touchpads and the opposite of its default for natural scrolling.  The finger count
is asked first: libinput documents it as the only honest way to know whether a
device supports tapping at all, and calling the setter on a device that does not is
a call with no effect rather than an error.

The device pointer is only valid while the DEVICE_ADDED event that carried it is
alive, which is why this runs from the event loop and not later."
  (incf (input-driver-config-applied-count driver))
  (when (plusp (%device-tap-get-finger-count device))
    (%device-tap-set-enabled device +tap-enabled+))
  (when (plusp (%device-has-natural-scroll device))
    (%device-set-natural-scroll device 1)))

(defun note-device (driver plist)
  "Record a device's identity and return it."
  (setf (gethash (getf plist :sysname) (input-driver-devices driver)) plist)
  plist)

(defun apply-raw-event (driver raw)
  "Act on one decoded event.

This is the whole policy of the module, in one COND: a key becomes a keysym name
(the seat speaks keysym names, the device speaks evdev codes), a delta becomes a
position, a button becomes a name, a scroll value becomes an axis.  Everything it
calls is either arithmetic or DELIVER, which is why the unit tests can drive it
with a list and no hardware."
  (incf (input-driver-event-count driver))
  (let ((kind (raw-event-kind raw)))
    (case kind
      (:keyboard-key
       (incf (input-driver-key-count driver))
       (let ((name (input:key-name-for-code (raw-event-key raw))))
         (if name
             (deliver driver :key (list :name name
                                        :code (raw-event-key raw)
                                        :state (raw-event-key-state raw)))
             (progn
               ;; A multimedia key, a keypad key, or a key the phase-3 table does
               ;; not name.  Dropping it silently would make "nothing happened" and
               ;; "no such key" the same report (D54's rule about skips).
               (incf (input-driver-unknown-key-count driver))
               (deliver driver :unknown-key (list :code (raw-event-key raw)))))))
      (:motion
       (incf (input-driver-motion-count driver))
       (multiple-value-bind (x y) (accumulate-pointer driver
                                                      (raw-event-dx raw)
                                                      (raw-event-dy raw))
         (deliver driver :motion (list :x x :y y
                                       :dx (raw-event-dx raw)
                                       :dy (raw-event-dy raw)))))
      (:motion-absolute
       (incf (input-driver-motion-count driver))
       (let ((x (clamp-coordinate (raw-event-absolute-x raw) (input-driver-width driver)))
             (y (clamp-coordinate (raw-event-absolute-y raw) (input-driver-height driver))))
         (setf (input-driver-pointer-x driver) x
               (input-driver-pointer-y driver) y)
         (deliver driver :motion (list :x x :y y :dx 0d0 :dy 0d0))))
      (:button
       (incf (input-driver-button-count driver))
       (deliver driver :button (list :button (button-name (raw-event-button raw))
                                     :code (raw-event-button raw)
                                     :state (raw-event-button-state raw))))
      ((:scroll-wheel :scroll-finger :scroll-continuous)
       (incf (input-driver-axis-count driver))
       (deliver driver :axis (list :axis (raw-event-axis raw)
                                   :value (raw-event-value raw)
                                   :source kind)))
      (:device-added
       (incf (input-driver-device-added-count driver))
       (deliver driver :device-added (note-device driver (raw-event-device raw))))
      (:device-removed
       (incf (input-driver-device-removed-count driver))
       (let ((plist (raw-event-device raw)))
         (remhash (getf plist :sysname) (input-driver-devices driver))
         (deliver driver :device-removed plist)))
      (t
       (incf (input-driver-ignored-count driver))
       nil))))

;;; ---------------------------------------------------------------------------
;;; Reading events out of C
;;; ---------------------------------------------------------------------------

(defun read-event (driver event type)
  "Translate one libinput event pointer into a RAW-EVENT, or NIL when the type is
not one this module decodes."
  (let ((kind (event-kind type)))
    (when kind
      (let ((raw (make-raw-event :type type :kind kind)))
        (case kind
          (:keyboard-key
           (setf (raw-event-key raw) (%keyboard-get-key event)
                 (raw-event-key-state raw) (key-state-keyword (%keyboard-get-key-state event))))
          (:motion
           (setf (raw-event-dx raw) (%pointer-get-dx event)
                 (raw-event-dy raw) (%pointer-get-dy event)))
          (:motion-absolute
           (setf (raw-event-absolute-x raw)
                 (%pointer-get-absolute-x event (max 1 (input-driver-width driver)))
                 (raw-event-absolute-y raw)
                 (%pointer-get-absolute-y event (max 1 (input-driver-height driver)))))
          (:button
           (setf (raw-event-button raw) (%pointer-get-button event)
                 (raw-event-button-state raw)
                 (button-state-keyword (%pointer-get-button-state event))))
          ((:scroll-wheel :scroll-finger :scroll-continuous)
           ;; A scroll event carries one axis per event, and the axis that has no value
           ;; must not be read: libinput's header requires HAS_AXIS first, and reading an
           ;; unset axis is a client bug it logs -- which is how the soak found this
           ;; (`client bug: value requested for unset axis', thirteen times on one
           ;; scroll).  Horizontal when it is the only axis set, vertical otherwise.
           (let ((horizontal-p (plusp (%pointer-has-axis event +axis-horizontal+)))
                 (vertical-p (plusp (%pointer-has-axis event +axis-vertical+))))
             (cond
               ((and horizontal-p (not vertical-p))
                (setf (raw-event-axis raw) :horizontal
                      (raw-event-value raw) (%pointer-get-scroll-value
                                            event +axis-horizontal+)))
               (t
                (setf (raw-event-axis raw) :vertical
                      (raw-event-value raw)
                      (if vertical-p
                          (%pointer-get-scroll-value event +axis-vertical+)
                          0d0))))))
          ((:device-added :device-removed)
           (setf (raw-event-device raw) (device-info (%event-get-device event)))))
        raw))))

(defun handle-event (driver event)
  "Decode and act on one event pointer."
  (let* ((type (%event-get-type event))
         (kind (event-kind type)))
    (cond
      ((eq kind :device-added)
       (let ((device (%event-get-device event)))
         (configure-device driver device)
         (apply-raw-event driver (make-raw-event
                                  :type type :kind :device-added
                                  :device (device-info device)))))
      ((eq kind :device-removed)
       (apply-raw-event driver (make-raw-event
                                :type type :kind :device-removed
                                :device (device-info (%event-get-device event)))))
      (t
       (let ((raw (read-event driver event type)))
         (when raw (apply-raw-event driver raw))
         (unless raw (incf (input-driver-ignored-count driver))))))))

(defun poll-input (driver)
  "Dispatch once and drain the queue.  Returns the number of events handled.

Every event returned by libinput_get_event has to be destroyed, including the ones
this module ignores, so the destroy is in an UNWIND-PROTECT around the handler
rather than after it."
  (when (input-driver-suspended-p driver)
    (return-from poll-input 0))
  (let ((context (input-driver-context driver)))
    (when (minusp (%dispatch context))
      (error 'input-error :operation "dispatch" :detail (ffi:errno)))
    (loop for count from 0
          for event = (%get-event context)
          when (cffi:null-pointer-p event)
            do (return count)
          do (unwind-protect (handle-event driver event)
               (%event-destroy event)))))

;;; ---------------------------------------------------------------------------
;;; Creating and destroying a driver
;;; ---------------------------------------------------------------------------

(defun make-udev ()
  "A udev context, loading libudev on first use.  Signals INPUT-ERROR when absent."
  (handler-case (cffi:use-foreign-library libudev)
    (error (condition)
      (error 'input-error :operation "load-libudev" :detail (princ-to-string condition))))
  (let ((udev (%udev-new)))
    (when (cffi:null-pointer-p udev)
      (error 'input-error :operation "udev-new"))
    udev))

(defun make-input-driver (&key compositor sink (width 0) (height 0) session)
  "An unopened driver.  OPEN-INPUT is what makes a context for it."
  (let ((driver (make-instance 'input-driver
                               :id (incf *next-driver-id*)
                               :compositor compositor
                               :sink (or sink (constantly nil))
                               :width width
                               :height height
                               :session session)))
    (setf (input-driver-interface driver) (%interface))
    (setf (gethash (input-driver-id driver) *drivers*) driver)
    driver))

(defun open-input (driver &key (seat-name "seat0") (udev t))
  "Create the context: a udev context assigned to SEAT-NAME, or a path context.

A path context has no hotplug and no seat: devices are added by name with
ADD-INPUT-DEVICE, which is what the gate's virtual keyboard uses and what a
compositor on a machine without udev can still run with."
  (let ((context (if udev
                     (progn
                       (setf (input-driver-udev driver) (make-udev))
                       (%udev-create-context (input-driver-interface driver)
                                             (%driver-userdata driver)
                                             (input-driver-udev driver)))
                     (%path-create-context (input-driver-interface driver)
                                           (%driver-userdata driver)))))
    (when (cffi:null-pointer-p context)
      (error 'input-error :operation "create-context"))
    (setf (input-driver-context driver) context)
    (when udev
      (when (minusp (%udev-assign-seat context seat-name))
        (error 'input-error :operation "assign-seat" :detail seat-name)))
    driver))

(defun input-driver-open-count (driver)
  "How many descriptors libinput currently holds for DRIVER.

A function rather than a slot: the map is the truth, and a counter beside it is
one more thing that can disagree with it after a failed close."
  (hash-table-count (input-driver-open-fds driver)))

(defun add-input-device (driver path)
  "Add one device by path (path contexts only).  Returns the device pointer or NIL.

A device that cannot be opened is NIL, not an error: libinput logs the errno and a
caller enumerating /dev/input must be able to skip a node somebody else has."
  (%path-add-device (input-driver-context driver) path))

(defun input-fd (driver) (%get-fd (input-driver-context driver)))

(defun suspend-input (driver)
  "Stop reading (a VT switch away).  libinput_resume is required to start again."
  (unless (input-driver-suspended-p driver)
    (%suspend (input-driver-context driver))
    (setf (input-driver-suspended-p driver) t))
  t)

(defun resume-input (driver)
  "Start reading again after SUSPEND-INPUT, reopening the devices through the seat."
  (when (input-driver-suspended-p driver)
    (%resume (input-driver-context driver))
    (setf (input-driver-suspended-p driver) nil))
  t)

(defun close-input (driver)
  "Remove the reactor source, destroy the context, unref udev, forget the driver.

libinput_unref closes every device through close_restricted, so the fd map is
emptied by that call rather than by a loop here."
  (when (input-driver-source driver)
    (handler-case (reactor:remove-source
                   (srv:display-reactor (cf:compositor-display (input-driver-compositor driver)))
                   (input-driver-source driver))
      (error () nil))
    (setf (input-driver-source driver) nil))
  (unless (cffi:null-pointer-p (input-driver-context driver))
    (%unref (input-driver-context driver))
    (setf (input-driver-context driver) (cffi:null-pointer)))
  (unless (cffi:null-pointer-p (input-driver-interface driver))
    (cffi:foreign-free (input-driver-interface driver))
    (setf (input-driver-interface driver) (cffi:null-pointer)))
  ;; libinput closed the descriptors it opened; anything left belongs to a seat
  ;; that was disabled mid-close, and close_session_device is idempotent.
  (when (input-driver-session driver)
    (maphash (lambda (fd owner) (declare (ignore fd))
               (unless (eq owner t)
                 (session:close-session-device (input-driver-session driver) owner)))
             (input-driver-open-fds driver)))
  (clrhash (input-driver-open-fds driver))
  (unless (cffi:null-pointer-p (input-driver-udev driver))
    (%udev-unref (input-driver-udev driver))
    (setf (input-driver-udev driver) (cffi:null-pointer)))
  (remhash (input-driver-id driver) *drivers*)
  (clrhash (input-driver-devices driver))
  t)

;;; ---------------------------------------------------------------------------
;;; The compositor's sink
;;; ---------------------------------------------------------------------------

(defun compositor-sink (compositor)
  "The sink that feeds COMPOSITOR's seat, which is what a backend's events are for.

The four calls are the same ones the nested backend and the test harnesses use
(INJECT-KEY and friends), so a key from a real keyboard takes exactly the path a key
from a test does: through the keybindings, the grabs and the switcher before the
focused client."
  (lambda (kind payload)
    (macrolet ((field (key) `(getf payload ,key)))
      (case kind
        (:key (cf:inject-key compositor (field :name) (field :state)))
        (:motion (cf:inject-pointer-motion compositor (field :x) (field :y)))
        (:button (cf:inject-pointer-button compositor (field :button) (field :state)))
        (:axis (cf:inject-pointer-axis compositor (field :axis) (field :value)))
        (t nil)))))

(defun start-input (compositor &key (seat-name "seat0") (udev t) session sink)
  "Create a driver for COMPOSITOR, open it, and watch its fd in the reactor.

Returns the driver; STOP-INPUT is its undo.  SESSION, when given, is a
cf.session:session and devices are opened through it; otherwise they are opened
directly, which needs read access to the device nodes."
  (let* ((reactor (srv:display-reactor (cf:compositor-display compositor)))
         (driver (make-input-driver :compositor compositor
                                    :session session
                                    :sink (or sink (compositor-sink compositor))
                                    :width (cf:compositor-width compositor)
                                    :height (cf:compositor-height compositor))))
    (open-input driver :seat-name seat-name :udev udev)
    (setf (input-driver-source driver)
          (reactor:add-source
           reactor (input-fd driver)
           :on-readable (lambda (source events)
                          (declare (ignore source events))
                          (poll-input driver))
           :name "libinput"))
    driver))

(defun stop-input (driver)
  "The undo of START-INPUT."
  (close-input driver))

(defun input-driver-device-names (driver)
  (sort (loop for sysname being the hash-keys of (input-driver-devices driver)
              collect sysname)
        #'string<))
