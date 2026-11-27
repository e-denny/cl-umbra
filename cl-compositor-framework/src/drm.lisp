;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cf.backend.drm v1: the card, what is plugged into it, a dumb buffer, and
;;;; the screen (docs/framework.md §2, PLAN.md phase 4).
;;;;
;;;; Two halves, cut where the kernel cuts them (D54, D55).
;;;;
;;;; The first half describes the card and cannot change the screen:
;;;; enumerating resources, connectors, encoders and CRTCs, picking a mode,
;;;; creating, mapping and freeing a scanout-sized dumb buffer, and adding and
;;;; removing a framebuffer all work on a card another process owns, without DRM
;;;; master, because none of it scans anything out.
;;;;
;;;; The second half owns the screen: SET MASTER, SETCRTC, PAGE FLIP, and the
;;;; events the kernel reports when a flip is retired.  Taking master is not a
;;;; side effect of a probe: a card somebody else is presenting on answers EBUSY,
;;;; and the caller has to have decided to take the display and to have kept the
;;;; state needed to give it back (DRM-OPEN-SCANOUT saves it, DRM-CLOSE-SCANOUT
;;;; restores it).  Which cards a program is willing to do that to is that
;;;; program's policy, not this module's: the gate and the demo only touch a
;;;; virtual card unless a person names a real one (D55).
;;;;
;;;; The shape is libdrm's, but the memory is ours.  Every drmMode* call hands
;;;; back C memory that the caller has to free, so each one is freed before the
;;;; next and what survives is a Lisp struct holding numbers and strings.  That is
;;;; D35's rule -- C never keeps a pointer into a Lisp object, and Lisp never
;;;; keeps a pointer into C memory -- applied to the kernel's objects instead of
;;;; pixman's.  The one exception is stated where it happens: a mapped dumb
;;;; buffer is a mapping we own for as long as the buffer exists.
;;;;
;;;; What is pure is separate from what is a syscall.  Mode selection, refresh
;;;; arithmetic, connector naming and status, dumb-buffer geometry, and the
;;;; kernel's own view of the card through sysfs are ordinary functions over
;;;; ordinary values -- which is why those are the ones with unit tests
;;;; (tests/unit/drm.lisp).  The six kernel calls are a protocol of generic
;;;; functions, and the contract above them is plain functions, so a test can
;;;; stand in a recording device and see the arguments and the teardown order a
;;;; real card would have been given.

(in-package #:cl-user)

(in-package #:cf.backend.drm)

;;; ---------------------------------------------------------------------------
;;; The library
;;; ---------------------------------------------------------------------------
;;
;; libdrm is a leaf dependency of the hardware path (D4: CFFI for kernel and
;; driver APIs only), and it is loaded here and nowhere else.  We do not compile
;; against its headers: the structs below are written out and then checked
;; against the ABI at load time, because a wrong offset is a silent misread of
;; kernel memory rather than a link error (the same reason wayland.ffi asserts
;; its socket structs).

(cffi:define-foreign-library libdrm
  (:unix (:or "libdrm.so.2" "libdrm.so")))

(cffi:use-foreign-library libdrm)

;;; ---------------------------------------------------------------------------
;;; The kernel's structs
;;; ---------------------------------------------------------------------------
;;
;; Transcribed from xf86drm.h, xf86drmMode.h and libdrm/drm_mode.h.  The field
;; order is the ABI; the names are ours.  Only the fields this slice reads are
;; listed, with the tail of each struct kept where a later field is needed, so
;; that adding a field later is adding a line rather than re-deriving the layout.

(cffi:defcstruct drm-version
  (major :int)
  (minor :int)
  (patchlevel :int)
  (name-length :int)
  (name :pointer)
  (date-length :int)
  (date :pointer)
  (description-length :int)
  (description :pointer))

(cffi:defcstruct drm-mode-info
  (clock :uint32)
  (hdisplay :uint16) (hsync-start :uint16) (hsync-end :uint16) (htotal :uint16)
  (hskew :uint16)
  (vdisplay :uint16) (vsync-start :uint16) (vsync-end :uint16) (vtotal :uint16)
  (vscan :uint16)
  (vrefresh :uint32)
  (flags :uint32)
  (type :uint32)
  (name :char :count 32))

(cffi:defcstruct drm-mode-res
  (count-framebuffers :int) (framebuffers :pointer)
  (count-crtcs :int) (crtcs :pointer)
  (count-connectors :int) (connectors :pointer)
  (count-encoders :int) (encoders :pointer)
  (min-width :uint32) (max-width :uint32)
  (min-height :uint32) (max-height :uint32))

(cffi:defcstruct drm-mode-connector
  (id :uint32)
  (encoder-id :uint32)
  (type :uint32)
  (type-id :uint32)
  (connection :int)
  (mm-width :uint32)
  (mm-height :uint32)
  (subpixel :int)
  (count-modes :int)
  (modes :pointer)
  (count-properties :int)
  (properties :pointer)
  (property-values :pointer)
  (count-encoders :int)
  (encoders :pointer))

(cffi:defcstruct drm-mode-encoder
  (id :uint32)
  (type :uint32)
  (crtc-id :uint32)
  (possible-crtcs :uint32)
  (possible-clones :uint32))

(cffi:defcstruct drm-mode-crtc
  (id :uint32)
  (buffer-id :uint32)
  (x :uint32)
  (y :uint32)
  (width :uint32)
  (height :uint32)
  (mode-valid :int)
  (mode (:struct drm-mode-info))
  (gamma-size :int))

;; What read(2) on a DRM descriptor answers after a page flip.  The kernel writes
;; a stream of these, each one a fixed-size record whose LENGTH says how big it
;; is; a flip completion carries the same payload as a vblank (the vblank struct
;; is a drm_event with four more words on the end).
(cffi:defcstruct drm-event
  (type :uint32)
  (length :uint32))

(cffi:defcstruct drm-event-vblank
  (type :uint32)
  (length :uint32)
  (user-data :uint64)
  (tv-sec :uint32)
  (tv-usec :uint32)
  (sequence :uint32)
  (crtc-id :uint32))

(defun check-layouts ()
  "Refuse to load if a transcribed struct does not match this libdrm's ABI.

The sizes and the three offsets that matter were measured against the headers on
this machine (drm_version 56, drm_mode_res 80, drm_mode_connector 88,
drm_mode_encoder 20, drm_mode_info 68, drm_mode_crtc 100, drm_event 8,
drm_event_vblank 32; mode_info.name at 36, connector.modes at 40, crtc.mode at 28,
event_vblank.user_data at 8, event_vblank.sequence at 24).  These are 64-bit
sizes, which is the same assumption wayland.ffi's socket check already makes."
  (flet ((size (type) (cffi:foreign-type-size type))
         (offset (type slot)
           (cffi:foreign-slot-offset type slot)))
    (unless (and (= 56 (size '(:struct drm-version)))
                 (= 80 (size '(:struct drm-mode-res)))
                 (= 88 (size '(:struct drm-mode-connector)))
                 (= 20 (size '(:struct drm-mode-encoder)))
                 (= 68 (size '(:struct drm-mode-info)))
                 (= 100 (size '(:struct drm-mode-crtc)))
                 (= 8 (size '(:struct drm-event)))
                 (= 32 (size '(:struct drm-event-vblank)))
                 (= 36 (offset '(:struct drm-mode-info) 'name))
                 (= 40 (offset '(:struct drm-mode-connector) 'modes))
                 (= 28 (offset '(:struct drm-mode-crtc) 'mode))
                 (= 8 (offset '(:struct drm-event-vblank) 'user-data))
                 (= 24 (offset '(:struct drm-event-vblank) 'sequence)))
      (error "cf.backend.drm: the transcribed DRM structs do not match this libdrm; check them against xf86drm.h, xf86drmMode.h and libdrm/drm_mode.h"))))

(eval-when (:load-toplevel :execute)
  (check-layouts))

;;; ---------------------------------------------------------------------------
;;; Constants the kernel defines
;;; ---------------------------------------------------------------------------

(defconstant +mode-type-preferred+ #x8
  "DRM_MODE_TYPE_PREFERRED: the mode the monitor says it wants (usually its EDID
preferred timing, and the one that is native rather than scaled).")

(defconstant +cap-dumb-buffer+ 1)
(defconstant +cap-prime+ 2)

(defconstant +dumb-buffer-bits-per-pixel+ 32
  "Dumb buffers are 32 bits per pixel: one ARGB8888 pixel per word, which is what
the pixman target already composites into.")

(defconstant +dumb-buffer-depth+ 24
  "The depth of an ARGB8888 framebuffer: 24 colour bits and 8 that XRGB8888
ignores.  The kernel wants depth and bpp separately and rejects 32/32 on some
drivers.")

; drm_event types as read(2) reports them.
(defconstant +event-vblank+ #x01)
(defconstant +event-flip-complete+ #x02)

;; The one page-flip flag this slice asks for: deliver an event when the flip is
;; retired.  Without it a flip is silent and there is nothing to wait for.
(defconstant +page-flip-event+ #x01)

;; One read(2) on a DRM descriptor is given this much room: a vblank record is 32
;; bytes and a busy display retires a frame every 16 ms, so a kibibyte is dozens
;; of events and one syscall per frame-flush instead of one per event.
(defconstant +event-buffer-size+ 1024)

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------
;;
;; One condition for the whole module, with the three things a caller needs to
;; act on: what we were doing, what the kernel said, and which device.  The errno
;; is not decoration: EACCES means this user was not given the card, ENOENT means
;; there is no card, and ENOSPC means the dumb buffer was too big -- three
;; different answers a probe must not merge into "DRM failed".

(define-condition drm-error (error)
  ((operation :initarg :operation :reader drm-error-operation)
   (errno :initarg :errno :initform nil :reader drm-error-errno)
   (path :initarg :path :initform nil :reader drm-error-path))
  (:report (lambda (condition stream)
             (format stream "~A~@[ on ~A~] failed~@[: ~A (errno ~D)~]"
                     (drm-error-operation condition)
                     (drm-error-path condition)
                     (and (drm-error-errno condition)
                          (ffi:strerror (drm-error-errno condition)))
                     (drm-error-errno condition)))))

(defun drm-failed (operation &key errno path)
  "Signal a DRM-ERROR.  ERRNO defaults to the current errno, read at the call."
  (error 'drm-error :operation operation :errno (or errno (ffi:errno)) :path path))

(defun result-errno (result)
  "The errno behind a libdrm call that returns 0 on success.

libdrm's mode helpers document `negative errno' on failure, and the ones that
wrap ioctl(2) directly return -1 with errno set.  Both spellings mean the same
thing to a caller, so both are turned into a number here rather than at each
call site."
  (let ((error-number (- result)))
    (if (= error-number 1) (ffi:errno) error-number)))

;;; ---------------------------------------------------------------------------
;;; libdrm
;;; ---------------------------------------------------------------------------
;;
;; The mode helpers are used rather than raw ioctls: they are the documented,
;; version-tolerant spelling of the same ioctls, and libdrm.so.2 is the stable
;; ABI.  Every pointer returned by a Get is freed by the matching Free in this
;; file, in the shortest possible scope.

(cffi:defcfun ("drmGetVersion" %drm-get-version) :pointer
  (fd :int))

(cffi:defcfun ("drmFreeVersion" %drm-free-version) :void
  (version :pointer))

(cffi:defcfun ("drmIsMaster" %drm-is-master) :int
  (fd :int))

(cffi:defcfun ("drmGetCap" %drm-get-cap) :int
  (fd :int) (capability :uint64) (value :pointer))

(cffi:defcfun ("drmModeGetResources" %drm-mode-get-resources) :pointer
  (fd :int))

(cffi:defcfun ("drmModeFreeResources" %drm-mode-free-resources) :void
  (resources :pointer))

(cffi:defcfun ("drmModeGetConnector" %drm-mode-get-connector) :pointer
  (fd :int) (connector-id :uint32))

(cffi:defcfun ("drmModeFreeConnector" %drm-mode-free-connector) :void
  (connector :pointer))

(cffi:defcfun ("drmModeGetEncoder" %drm-mode-get-encoder) :pointer
  (fd :int) (encoder-id :uint32))

(cffi:defcfun ("drmModeFreeEncoder" %drm-mode-free-encoder) :void
  (encoder :pointer))

(cffi:defcfun ("drmModeGetCrtc" %drm-mode-get-crtc) :pointer
  (fd :int) (crtc-id :uint32))

(cffi:defcfun ("drmModeFreeCrtc" %drm-mode-free-crtc) :void
  (crtc :pointer))

;; libdrm 2.4.111 and later.  Earlier versions had no such helper and every
;; compositor carried the table; requiring the helper is one dependency fewer
;; than carrying a copy of the kernel's enum.
(cffi:defcfun ("drmModeGetConnectorTypeName" %drm-connector-type-name) :string
  (connector-type :uint32))

(cffi:defcfun ("drmModeCreateDumbBuffer" %drm-mode-create-dumb-buffer) :int
  (fd :int) (width :uint32) (height :uint32) (bits-per-pixel :uint32)
  (flags :uint32) (handle :pointer) (pitch :pointer) (size :pointer))

(cffi:defcfun ("drmModeDestroyDumbBuffer" %drm-mode-destroy-dumb-buffer) :int
  (fd :int) (handle :uint32))

(cffi:defcfun ("drmModeMapDumbBuffer" %drm-mode-map-dumb-buffer) :int
  (fd :int) (handle :uint32) (offset :pointer))

(cffi:defcfun ("drmModeAddFB" %drm-mode-add-fb) :int
  (fd :int) (width :uint32) (height :uint32) (depth :uint8) (bits-per-pixel :uint8)
  (pitch :uint32) (handle :uint32) (id :pointer))

(cffi:defcfun ("drmModeRmFB" %drm-mode-remove-fb) :int
  (fd :int) (id :uint32))

;; The four calls that change the screen, and the master bit that allows them.
(cffi:defcfun ("drmSetMaster" %drm-set-master) :int
  (fd :int))

(cffi:defcfun ("drmDropMaster" %drm-drop-master) :int
  (fd :int))

(cffi:defcfun ("drmModeSetCrtc" %drm-mode-set-crtc) :int
  (fd :int) (crtc-id :uint32) (buffer-id :uint32)
  (x :uint32) (y :uint32)
  (connectors :pointer) (count :int) (mode :pointer))

(cffi:defcfun ("drmModePageFlip" %drm-mode-page-flip) :int
  (fd :int) (crtc-id :uint32) (framebuffer-id :uint32)
  (flags :uint32) (user-data :pointer))

;;; ---------------------------------------------------------------------------
;;; What a card says about itself
;;; ---------------------------------------------------------------------------

(defstruct (drm-mode (:constructor %make-drm-mode))
  "One mode a connector offers, as numbers and a name.

No pointers: this is what survives after drmModeFreeConnector has freed the C
array it came from."
  (name "" :type string)
  (clock 0 :type (unsigned-byte 32))
  (hdisplay 0 :type (unsigned-byte 16))
  (hsync-start 0 :type (unsigned-byte 16))
  (hsync-end 0 :type (unsigned-byte 16))
  (htotal 0 :type (unsigned-byte 16))
  (hskew 0 :type (unsigned-byte 16))
  (vdisplay 0 :type (unsigned-byte 16))
  (vsync-start 0 :type (unsigned-byte 16))
  (vsync-end 0 :type (unsigned-byte 16))
  (vtotal 0 :type (unsigned-byte 16))
  (vscan 0 :type (unsigned-byte 16))
  (vrefresh 0 :type (unsigned-byte 32))
  (flags 0 :type (unsigned-byte 32))
  (type 0 :type (unsigned-byte 32)))

(defun drm-mode-refresh-milli-hz (mode)
  "The mode's refresh rate in millihertz, from its pixel clock and totals.

The clock is in kilohertz and one frame is HTOTAL x VTOTAL pixels, so the rate
is clock x 10^6 / pixels millihertz.  Integer arithmetic rather than a float: a
59.94 Hz mode and a 60 Hz mode have to compare unequal, and this is exactly
where that gets lost.  Zero when the totals are unknown, which some virtual
modes report."
  (let ((pixels (* (drm-mode-htotal mode) (drm-mode-vtotal mode))))
    (if (zerop pixels)
        0
        (round (* 1000000 (drm-mode-clock mode)) pixels))))

(defun drm-mode-refresh (mode)
  "The mode's refresh rate in hertz, for printing."
  (/ (drm-mode-refresh-milli-hz mode) 1000.0))

(defun drm-mode-preferred-p (mode)
  "True when the monitor nominated this mode as its preferred one."
  (logtest +mode-type-preferred+ (drm-mode-type mode)))

(defstruct (drm-connector (:constructor %make-drm-connector))
  "A connector: a physical or virtual output socket, the modes it offers, and
what the kernel currently believes is plugged into it.

STATUS is :CONNECTED, :DISCONNECTED or :UNKNOWN.  NAME is the kernel's own name
for it -- `HDMI-A-1', `DP-1' -- so that a log, a /sys path and an error message
all say the same word."
  (id 0 :type (unsigned-byte 32))
  (name "" :type string)
  (type 0 :type (unsigned-byte 32))
  (type-id 0 :type (unsigned-byte 32))
  (status :unknown :type keyword)
  (mm-width 0 :type (unsigned-byte 32))
  (mm-height 0 :type (unsigned-byte 32))
  (encoder-id 0 :type (unsigned-byte 32))
  (modes '() :type list)
  (encoders '() :type list))

(defun drm-connector-connected-p (connector)
  (eq :connected (drm-connector-status connector)))

(defun drm-connector-status-string (connector)
  "The connector's status as the word sysfs uses, for cross-checking against it."
  (string-downcase (symbol-name (drm-connector-status connector))))

(defun drm-connector-preferred-mode (connector)
  "The mode the monitor nominated, or NIL."
  (find-if #'drm-mode-preferred-p (drm-connector-modes connector)))

(defun drm-pick-mode (connector &key width height)
  "The mode to program for CONNECTOR.

An exact WIDTH x HEIGHT match wins, and among those the preferred one, else the
highest refresh: a monitor offering its native size at 60, 59.94 and 50 Hz is
offering one good answer and two worse ones.  Failing an exact match the
preferred mode is the answer -- it is the timing the monitor asked for -- and if
no mode carries that flag, the largest by area, then the fastest, then the first
in name order."
  (let* ((modes (drm-connector-modes connector))
         (sized (when (and width height)
                  (remove-if-not (lambda (mode)
                                   (and (= width (drm-mode-hdisplay mode))
                                        (= height (drm-mode-vdisplay mode))))
                                 modes))))
    (cond
      ((null modes) nil)
      (sized (or (find-if #'drm-mode-preferred-p sized)
                 (first (sort (copy-list sized) #'drm-mode-better-p))))
      ((drm-connector-preferred-mode connector))
      (t (first (sort (copy-list modes) #'drm-mode-better-p))))))

(defun drm-mode-better-p (a b)
  "Choose between two modes: bigger, then faster, then the cheaper clock, then
by name -- a total order, so two runs pick the same mode."
  (let ((area-a (* (drm-mode-hdisplay a) (drm-mode-vdisplay a)))
        (area-b (* (drm-mode-hdisplay b) (drm-mode-vdisplay b)))
        (refresh-a (drm-mode-refresh-milli-hz a))
        (refresh-b (drm-mode-refresh-milli-hz b)))
    (cond ((/= area-a area-b) (> area-a area-b))
          ((/= refresh-a refresh-b) (> refresh-a refresh-b))
          ((/= (drm-mode-clock a) (drm-mode-clock b))
           (< (drm-mode-clock a) (drm-mode-clock b)))
          (t (string< (drm-mode-name a) (drm-mode-name b))))))

(defstruct (drm-encoder (:constructor %make-drm-encoder))
  "An encoder: the thing that turns a CRTC's pixels into a connector's signal.

POSSIBLE-CRTCS and POSSIBLE-CLONES are bitmasks over the *index* of a CRTC in
the resources array, which is why the encoder keeps the raw mask and the caller
compares it with a CRTC's index rather than with its id."
  (id 0 :type (unsigned-byte 32))
  (type 0 :type (unsigned-byte 32))
  (crtc-id 0 :type (unsigned-byte 32))
  (possible-crtcs 0 :type (unsigned-byte 32))
  (possible-clones 0 :type (unsigned-byte 32)))

(defstruct (drm-crtc (:constructor %make-drm-crtc))
  "A CRTC: one scanout pipeline, and what it is currently doing.

BUFFER-ID 0 means the pipeline is off.  MODE is the timing it is programmed with
and MODE-VALID-P says whether the kernel thinks that timing is real.  Reading
this needs no master, which is what makes it useful: it is the state the next
slice has to put back when it gives the screen back."
  (id 0 :type (unsigned-byte 32))
  (buffer-id 0 :type (unsigned-byte 32))
  (x 0 :type (unsigned-byte 32))
  (y 0 :type (unsigned-byte 32))
  (width 0 :type (unsigned-byte 32))
  (height 0 :type (unsigned-byte 32))
  (mode-valid-p nil)
  (mode nil))

(defstruct (drm-inventory (:constructor %make-drm-inventory))
  "Everything one enumeration of a card found, in Lisp values only."
  (driver-name "" :type string)
  (driver-version "" :type string)
  (crtcs '() :type list)
  (connectors '() :type list)
  (encoders '() :type list)
  (framebuffers '() :type list)
  (min-width 0 :type (unsigned-byte 32))
  (max-width 0 :type (unsigned-byte 32))
  (min-height 0 :type (unsigned-byte 32))
  (max-height 0 :type (unsigned-byte 32)))

(defun drm-inventory-connector (inventory name-or-id)
  "The connector called NAME-OR-ID (`HDMI-A-1' or 138), or NIL."
  (find name-or-id (drm-inventory-connectors inventory)
        :key (lambda (connector)
               (if (stringp name-or-id)
                   (drm-connector-name connector)
                   (drm-connector-id connector)))
        :test #'equal))

(defun drm-inventory-crtc (inventory id)
  (find id (drm-inventory-crtcs inventory) :key #'drm-crtc-id))

(defun drm-inventory-encoder (inventory id)
  (find id (drm-inventory-encoders inventory) :key #'drm-encoder-id))

(defun drm-inventory-connected-connectors (inventory)
  (remove-if-not #'drm-connector-connected-p (drm-inventory-connectors inventory)))

;;; ---------------------------------------------------------------------------
;;; Hotplug: the same question asked twice
;;;
;;; The kernel's hotplug is a udev change event, and this project has no udev
;;; dependency (D4 names the libraries it uses, and udev is not one).  What a card
;;; *is* willing to answer at any time, without master, is GETRESOURCES and
;;; GETCONNECTOR -- so "did a cable move?" is asked, not delivered (D62).  The
;;; answer is reduced to a value two calls compare with EQUAL.

(defun drm-mode-key (mode)
  "The part of MODE that changes what a screen looks like."
  (list (drm-mode-name mode)
        (drm-mode-hdisplay mode)
        (drm-mode-vdisplay mode)
        (drm-mode-refresh-milli-hz mode)))

(defun drm-connector-hotplug-key (connector)
  "What CONNECTOR says about its cable, as a value two polls can compare.

The name and the id say which socket it is, the status says whether anything is
plugged into it, and the modes are the monitor's own claim about itself -- so a
different monitor on the same cable is a different key even when the connector
never reports a disconnect."
  (list (drm-connector-name connector)
        (drm-connector-id connector)
        (drm-connector-status connector)
        (sort (mapcar #'drm-mode-key (drm-connector-modes connector)) #'string< :key #'car)))

(defun drm-inventory-hotplug-key (inventory)
  "Every connector in INVENTORY, sorted by name."
  (sort (mapcar #'drm-connector-hotplug-key (drm-inventory-connectors inventory))
        #'string< :key #'car))

;;; ---------------------------------------------------------------------------
;;; The device
;;; ---------------------------------------------------------------------------

(defclass drm-device ()
  ((path :initarg :path :reader drm-device-path)
   (fd :initarg :fd :accessor drm-device-fd)
   (driver-name :initarg :driver-name :initform "" :reader drm-device-driver-name)
   (version-major :initarg :version-major :initform 0 :reader drm-device-version-major)
   (version-minor :initarg :version-minor :initform 0 :reader drm-device-version-minor)
   (version-patchlevel :initarg :version-patchlevel :initform 0 :reader drm-device-version-patchlevel)
   (master-p :initarg :master-p :initform nil :accessor drm-device-master-p)
   (capabilities :initarg :capabilities :initform '() :reader drm-device-capabilities)
   (events :initform '() :accessor drm-device-events)
   (event-leftovers :initform nil :accessor drm-device-event-leftovers)
   (flips :initform 0 :accessor drm-device-flips))
  (:documentation
   "One open DRM device node: a card (or a render node) and what it says about
itself.

MASTER-P is the kernel's answer, recorded here: NIL for a card another process
is presenting on, T after DRM-TAKE-MASTER.  It is a slot and not a live query so
that a recording device can stand in for a card; DRM-REFRESH-MASTER is the call
that asks the kernel again.  CAPABILITIES is a plist of :DUMB-BUFFER and :PRIME,
because a driver without dumb buffers is not a card a compositor can use yet.

EVENTS and EVENT-LEFTOVERS are a read(2)'s worth of state: one read can deliver
several flip completions, and the last record in the buffer can be a partial one
if the kernel wrote the stream in pieces.  Consuming one event must not lose the
others, and a half event must not be parsed as a whole one."))

(defun drm-device-version (device)
  (format nil "~D.~D.~D"
          (drm-device-version-major device)
          (drm-device-version-minor device)
          (drm-device-version-patchlevel device)))

(defun drm-device-open-p (device)
  (let ((fd (drm-device-fd device)))
    (and fd (not (minusp fd)))))

(defun close-drm-device (device)
  "Close DEVICE's descriptor.  Idempotent, like every Close in this project."
  (when (drm-device-open-p device)
    (ffi:close-fd (drm-device-fd device))
    (setf (drm-device-fd device) nil))
  (values))

(defun open-drm-device (path &key (direction :io))
  "Open the DRM character device at PATH and read what it says about itself.

Signals DRM-ERROR if the node cannot be opened, and closes the descriptor again
if the version ioctl fails, so a failed open never leaves a descriptor behind."
  (let ((fd (handler-case
                (ffi:open-path path :direction direction)
              (ffi:io-error (condition)
                (drm-failed 'open :errno (ffi:io-error-errno condition) :path path)))))
    (adopt-drm-device fd path)))

(defun open-drm-device-from-fd (fd &key (path "seat") attributes)
  "Adopt an already-open DRM descriptor and read what it says about itself.

This is how a compositor gets a card that a seat holds: libseat opens the node on
its behalf and hands over the descriptor, and the compositor does not open the
node itself -- while a seat owns the session the descriptor is the only handle
that survives a VT switch, and opening the path again asks for a second,
unentitled view of the same card (D56, the TakeDevice route).  FD is taken over:
CLOSE-DRM-DEVICE closes it, and a caller closes it itself only if this signals.

PATH is what the descriptor refers to, for messages; the default says this
process did not open it by name.  ATTRIBUTES is the kernel's answer, and NIL
means ask the kernel.  A test supplies it to adopt a descriptor with no card
behind it, the same way a recording device stands in for the kernel's other
calls: what is left to prove here is the handover, and a handover is counted in
descriptors, not in driver strings."
  (unless (and (integerp fd) (not (minusp fd)))
    (drm-failed 'open-from-fd :errno ffi:+ebadf+ :path path))
  (adopt-drm-device fd path :attributes attributes))

(defun adopt-drm-device (fd path &key attributes)
  "Build a DRM-DEVICE over an open FD, closing FD if anything goes wrong.

The close is the whole reason this is one function: a caller that adopts a
seat's descriptor and then fails to describe it would otherwise leak a
descriptor the seat still believes is open, and the seat closes what it thinks
it owns."
  (handler-case
      (apply #'make-instance 'drm-device
             (append (list :path path :fd fd)
                     (or attributes (drm-describe-fd fd path))))
    (error (condition)
      (ffi:close-fd fd)
      (error condition))))

(defun drm-describe-fd (fd path)
  "The kernel's description of FD, as the initargs a DRM-DEVICE is built from.

PATH is used only by the error a driver that is not a card produces: a caller
that supplied ATTRIBUTES itself has already said what the descriptor is."
  (let ((version (%drm-get-version fd)))
    (when (cffi:null-pointer-p version)
      (drm-failed 'drm-get-version :path path))
    (unwind-protect
         (list :driver-name (version-string version 'name 'name-length)
               :version-major (cffi:foreign-slot-value version '(:struct drm-version) 'major)
               :version-minor (cffi:foreign-slot-value version '(:struct drm-version) 'minor)
               :version-patchlevel (cffi:foreign-slot-value version '(:struct drm-version) 'patchlevel)
               ;; Not asked here, deliberately: libdrm's drmIsMaster is not a query.
               ;; It calls DRM_IOCTL_SET_MASTER and answers `not EACCES', so asking it
               ;; *tries to take master* and cannot tell `I am master' from `the card
               ;; is busy' (verified by disassembling libdrm's drmIsMaster: one
               ;; SET_MASTER, then a compare against -EACCES).  A descriptor is master
               ;; when DRM-TAKE-MASTER was told so by the kernel, and not before.
               :master-p nil
               :capabilities (list :dumb-buffer (plusp (capability fd +cap-dumb-buffer+))
                                   :prime (plusp (capability fd +cap-prime+))))
      (%drm-free-version version))))

(defun version-string (version slot length-slot)
  "One of drmVersion's strings, bounded by the length the kernel reported."
  (let ((pointer (cffi:foreign-slot-value version '(:struct drm-version) slot))
        (length (cffi:foreign-slot-value version '(:struct drm-version) length-slot)))
    (if (or (cffi:null-pointer-p pointer) (not (plusp length)))
        ""
        (cffi:foreign-string-to-lisp pointer :max-chars length))))

(defun capability (fd capability)
  "The value of one DRM capability, or 0 when the kernel does not know it."
  (cffi:with-foreign-object (value :uint64)
    (setf (cffi:mem-ref value :uint64) 0)
    (if (minusp (%drm-get-cap fd capability value))
        0
        (cffi:mem-ref value :uint64))))
(defun device-fd (device)
  "DEVICE's descriptor, or a DRM-ERROR naming the device if it was closed."
  (let ((fd (drm-device-fd device)))
    (unless (and fd (not (minusp fd)))
      (drm-failed :device-closed :errno nil :path (drm-device-path device)))
    fd))

;;; ---------------------------------------------------------------------------
;;; Enumeration
;;; ---------------------------------------------------------------------------
;;
;; One pass: resources, then a connector and an encoder per id, then the current
;; state of each CRTC.  Every C object is freed inside the function that read it.
;; A connector that disappears between the resource query and its own query is
;; dropped rather than signalled: that is a hotplug, not an error, and the
;; inventory is a statement about what is there now.

(defun read-mode (modes index)
  "One drmModeModeInfo from a C array of them, as a DRM-MODE."
  (let ((mode (cffi:mem-aptr modes '(:struct drm-mode-info) index)))
    (flet ((slot (name) (cffi:foreign-slot-value mode '(:struct drm-mode-info) name)))
      (%make-drm-mode
       :name (cffi:foreign-string-to-lisp
              (cffi:foreign-slot-pointer mode '(:struct drm-mode-info) 'name)
              :max-chars 32)
       :clock (slot 'clock)
       :hdisplay (slot 'hdisplay)
       :hsync-start (slot 'hsync-start)
       :hsync-end (slot 'hsync-end)
       :htotal (slot 'htotal)
       :hskew (slot 'hskew)
       :vdisplay (slot 'vdisplay)
       :vsync-start (slot 'vsync-start)
       :vsync-end (slot 'vsync-end)
       :vtotal (slot 'vtotal)
       :vscan (slot 'vscan)
       :vrefresh (slot 'vrefresh)
       :flags (slot 'flags)
       :type (slot 'type)))))

;;; ---------------------------------------------------------------------------
;;; Writing a mode back
;;; ---------------------------------------------------------------------------
;;
;; SETCRTC takes a timing, not a name, so the mode chosen from a connector has to
;; go back into C memory.  That makes the two directions a pair worth testing as
;; one: what READ-MODE read out, WRITE-MODE-INFO must be able to write back, field
;; for field.  A struct half filled is a timing the kernel may quietly adjust or
;; refuse, and both look like "the mode did not stick".

(defun write-mode-info (mode pointer)
  "Write MODE into the ::STRUCT DRM-MODE-INFO at POINTER.

Every field is written, including the ones this slice never looks at (the sync
edges, hskew, vscan): left at whatever the allocator had, a mode is not the mode
we chose."
  (unless (cffi:pointerp pointer)
    (error "write-mode-info needs a foreign pointer, got ~S" pointer))
  (labels ((put (name value)
             (setf (cffi:foreign-slot-value pointer '(:struct drm-mode-info) name) value)))
    (put 'clock (drm-mode-clock mode))
    (put 'hdisplay (drm-mode-hdisplay mode))
    (put 'hsync-start (drm-mode-hsync-start mode))
    (put 'hsync-end (drm-mode-hsync-end mode))
    (put 'htotal (drm-mode-htotal mode))
    (put 'hskew (drm-mode-hskew mode))
    (put 'vdisplay (drm-mode-vdisplay mode))
    (put 'vsync-start (drm-mode-vsync-start mode))
    (put 'vsync-end (drm-mode-vsync-end mode))
    (put 'vtotal (drm-mode-vtotal mode))
    (put 'vscan (drm-mode-vscan mode))
    (put 'vrefresh (drm-mode-vrefresh mode))
    (put 'flags (drm-mode-flags mode))
    (put 'type (drm-mode-type mode))
    (loop with name = (drm-mode-name mode)
          with string = (cffi:foreign-slot-pointer pointer '(:struct drm-mode-info) 'name)
          for index below 32
          do (setf (cffi:mem-aref string :uint8 index)
                   (if (< index (min 31 (length name)))
                       (char-code (char name index))
                       0))))
  pointer)

(defun read-mode-info (mode-info)
  "The DRM-MODE at the ::STRUCT DRM-MODE-INFO MODE-INFO points at.

The inverse of WRITE-MODE-INFO, and the same reader enumeration uses: a write
followed by a read has to give an equal mode back."
  (read-mode mode-info 0))

(defun drm-connection-status (value)
  "The kernel's DRM-MODE-CONNECTION number as a keyword.

The numbers are spelled out here on purpose: this is the one place the kernel's
encoding is translated, so a test can call it with 1, 2 and 3 without a card and
without a constant that might itself be wrong."
  (case value
    (1 :connected)
    (2 :disconnected)
    (t :unknown)))

(defun uint32-list (pointer count)
  "COUNT uint32s from a C array, as a Lisp list."
  (loop for index below count
        collect (cffi:mem-aref pointer :uint32 index)))

(defun read-connector (fd id)
  "One connector as a DRM-CONNECTOR, or NIL if it went away while we looked."
  (let ((connector (%drm-mode-get-connector fd id)))
    (when (cffi:null-pointer-p connector)
      (return-from read-connector nil))
    (unwind-protect
         (flet ((slot (name)
                  (cffi:foreign-slot-value connector '(:struct drm-mode-connector) name)))
           (let ((type (slot 'type))
                 (type-id (slot 'type-id))
                 (count-modes (slot 'count-modes))
                 (modes (slot 'modes)))
             (%make-drm-connector
              :id id
              :name (format nil "~A-~D" (drm-connector-type-name type) type-id)
              :type type
              :type-id type-id
              :status (drm-connection-status (slot 'connection))
              :mm-width (slot 'mm-width)
              :mm-height (slot 'mm-height)
              :encoder-id (slot 'encoder-id)
              :modes (loop for index below count-modes
                           collect (read-mode modes index))
              :encoders (uint32-list (slot 'encoders) (slot 'count-encoders)))))
      (%drm-mode-free-connector connector))))

(defun drm-connector-type-name (type)
  "The kernel's name for a connector type: `HDMI-A', `DP', `eDP'."
  (let ((name (%drm-connector-type-name type)))
    (or name (format nil "TYPE-~D" type))))

(defun read-encoder (fd id)
  (let ((encoder (%drm-mode-get-encoder fd id)))
    (when (cffi:null-pointer-p encoder)
      (return-from read-encoder nil))
    (unwind-protect
         (flet ((slot (name)
                  (cffi:foreign-slot-value encoder '(:struct drm-mode-encoder) name)))
           (%make-drm-encoder
            :id id
            :type (slot 'type)
            :crtc-id (slot 'crtc-id)
            :possible-crtcs (slot 'possible-crtcs)
            :possible-clones (slot 'possible-clones)))
      (%drm-mode-free-encoder encoder))))

(defun read-crtc (fd id)
  "What CRTC ID is doing now.  Read-only, and allowed without master."
  (let ((crtc (%drm-mode-get-crtc fd id)))
    (when (cffi:null-pointer-p crtc)
      (return-from read-crtc (%make-drm-crtc :id id)))
    (unwind-protect
         (flet ((slot (name)
                  (cffi:foreign-slot-value crtc '(:struct drm-mode-crtc) name)))
           (let ((valid (slot 'mode-valid)))
             (%make-drm-crtc
              :id id
              :buffer-id (slot 'buffer-id)
              :x (slot 'x)
              :y (slot 'y)
              :width (slot 'width)
              :height (slot 'height)
              :mode-valid-p (not (zerop valid))
              :mode (when (not (zerop valid))
                      (read-mode (cffi:foreign-slot-pointer
                                  crtc '(:struct drm-mode-crtc) 'mode)
                                 0)))))
      (%drm-mode-free-crtc crtc))))

(defun read-inventory (device)
  "Enumerate DEVICE.  Signals DRM-ERROR when the resource query fails."
  (let ((resources (%drm-mode-get-resources (device-fd device))))
    (when (cffi:null-pointer-p resources)
      (drm-failed 'drm-mode-get-resources :path (drm-device-path device)))
    (unwind-protect
         (flet ((slot (name)
                  (cffi:foreign-slot-value resources '(:struct drm-mode-res) name)))
           (let ((fd (device-fd device)))
             (%make-drm-inventory
              :driver-name (drm-device-driver-name device)
              :driver-version (drm-device-version device)
              :crtcs (loop for id in (uint32-list (slot 'crtcs) (slot 'count-crtcs))
                           collect (read-crtc fd id))
              :connectors (loop for id in (uint32-list (slot 'connectors) (slot 'count-connectors))
                                for connector = (read-connector fd id)
                                when connector collect connector)
              :encoders (loop for id in (uint32-list (slot 'encoders) (slot 'count-encoders))
                              for encoder = (read-encoder fd id)
                              when encoder collect encoder)
              :framebuffers (uint32-list (slot 'framebuffers) (slot 'count-framebuffers))
              :min-width (slot 'min-width)
              :max-width (slot 'max-width)
              :min-height (slot 'min-height)
              :max-height (slot 'max-height))))
      (%drm-mode-free-resources resources))))

;;; ---------------------------------------------------------------------------
;;; Dumb buffers
;;; ---------------------------------------------------------------------------
;;
;; A dumb buffer is the only kind of framebuffer a card without a GPU driver (or
;; without EGL) needs: the kernel allocates a linear chunk of memory, hands back
;; a handle, a pitch and a size, and lets us mmap it.  Then the pixels are ours
;; to write with pixman, and a framebuffer object names that memory so a CRTC
;; can scan it out.
;;
;; Three resources, and the order they are released in is the contract:
;;
;;   the mapping   munmap, ours
;;   the fb id     RMFB, a name the CRTC may still be using
;;   the handle    DESTROY_DUMB, which frees the memory the fb pointed at
;;
;; Getting that order wrong is not a leak, it is a use-after-free the kernel has
;; to reject (or worse, does not).  DRM-DESTROY-DUMB does all three in that
;; order, which is why it exists rather than a set of independent calls.

(defclass dumb-buffer ()
  ((device :initarg :device :initform nil :reader dumb-buffer-device)
   (width :initarg :width :reader dumb-buffer-width)
   (height :initarg :height :reader dumb-buffer-height)
   (bits-per-pixel :initarg :bits-per-pixel :reader dumb-buffer-bits-per-pixel)
   (handle :initarg :handle :reader dumb-buffer-handle)
   (pitch :initarg :pitch :reader dumb-buffer-pitch)
   (size :initarg :size :reader dumb-buffer-size)
   (mapping :initform nil :accessor dumb-buffer-mapping)
   (framebuffer-id :initform nil :accessor dumb-buffer-framebuffer-id))
  (:documentation
   "A linear 32-bit image the kernel allocated for us, its mapping, and the
framebuffer id that names it to a CRTC if one was made.

PITCH is the driver's answer, not WIDTH x 4: a driver may pad rows, and every
pixel access goes through PITCH for that reason.  SIZE is the driver's answer
too, and is never smaller than PITCH x HEIGHT."))

(defun dumb-buffer-depth (buffer)
  "The framebuffer depth for BUFFER: 24 for a 32-bit buffer (see +DUMB-BUFFER-DEPTH+)."
  (declare (ignore buffer))
  +dumb-buffer-depth+)

(defun dumb-buffer-mapped-p (buffer)
  (not (null (dumb-buffer-mapping buffer))))

(defun dumb-buffer-framebuffer-p (buffer)
  (not (null (dumb-buffer-framebuffer-id buffer))))

(defun dumb-buffer-minimum-size (buffer)
  "The bytes BUFFER must have to hold every pixel: pitch x height."
  (* (dumb-buffer-pitch buffer) (dumb-buffer-height buffer)))

(defun dumb-buffer-pointer (buffer)
  "The mapping, for a renderer to draw into."
  (or (dumb-buffer-mapping buffer)
      (error "dumb buffer ~Dx~D is not mapped" (dumb-buffer-width buffer) (dumb-buffer-height buffer))))

(defun dumb-buffer-pixel (buffer x y)
  "The ARGB8888 word at (X, Y) in BUFFER's mapping, read for tests and probes.

One pixel at a time through CFFI: this is not the render path, it is the thing a
probe checks the render path's output with."
  (let ((offset (+ (* y (dumb-buffer-pitch buffer)) (* x 4))))
    (logior (cffi:mem-aref (dumb-buffer-pointer buffer) :uint8 offset)
            (ash (cffi:mem-aref (dumb-buffer-pointer buffer) :uint8 (+ offset 1)) 8)
            (ash (cffi:mem-aref (dumb-buffer-pointer buffer) :uint8 (+ offset 2)) 16)
            (ash (cffi:mem-aref (dumb-buffer-pointer buffer) :uint8 (+ offset 3)) 24))))

(defun dumb-buffer-octets (buffer)
  "A fresh vector holding BUFFER's pixels: pitch x height octets from the start
of the mapping.

For probes and tests only: a frame's worth of pixels copied through CFFI one
byte at a time is exactly the thing the renderer exists to avoid."
  (ffi:mapped-octets (dumb-buffer-pointer buffer) 0 (dumb-buffer-minimum-size buffer)))

;;; ---------------------------------------------------------------------------
;;; Events
;;; ---------------------------------------------------------------------------
;;
;; A page flip is asynchronous: the ioctl queues it, and the kernel answers on the
;; same descriptor when the display has retired it.  What comes back is a byte
;; stream of fixed-size records -- an 8-byte header saying kind and size, then for
;; a flip or a vblank a 24-byte payload with the frame's sequence number and
;; timestamp.  Parsing is a pure function over octets, so the awkward cases
;; (several events in one read, an unknown kind, a record cut in half) are unit
;; tests rather than things discovered mid-flip.

(defun drm-event-type (code)
  "The kernel's drm_event type as a keyword: :vblank, :flip-complete, :other.

The numbers are spelled out here for the same reason DRM-CONNECTION-STATUS spells
out its own: this is the one place the encoding is translated."
  (case code
    (1 :vblank)
    (2 :flip-complete)
    (t :other)))

(defun parse-drm-events-from-pointer (pointer length)
  "Parse whole drm_event records from the LENGTH octets at POINTER.

Returns (values events consumed).  EVENTS is in arrival order, and CONSUMED is the
number of octets that formed whole records: a caller reading a stream keeps the
remaining tail for the next read instead of dropping it.  A record whose LENGTH is
smaller than its own header stops the parse -- otherwise a corrupt length is an
infinite loop."
  (let ((offset 0)
        (events '()))
    (loop
      (when (> (+ offset 8) length) (return))
      (let* ((start (cffi:inc-pointer pointer offset))
             (type (cffi:mem-ref start :uint32))
             (record-length (cffi:mem-ref (cffi:inc-pointer start 4) :uint32)))
        (when (or (< record-length 8) (> (+ offset record-length) length))
          (return))
        (let* ((kind (drm-event-type type))
               (complete (and (not (eq kind :other)) (>= record-length 32)))
               (event (if complete
                          (list :type kind
                                :length record-length
                                :user-data (cffi:mem-ref (cffi:inc-pointer start 8) :uint64)
                                :tv-sec (cffi:mem-ref (cffi:inc-pointer start 16) :uint32)
                                :tv-usec (cffi:mem-ref (cffi:inc-pointer start 20) :uint32)
                                :sequence (cffi:mem-ref (cffi:inc-pointer start 24) :uint32)
                                :crtc-id (cffi:mem-ref (cffi:inc-pointer start 28) :uint32))
                          (list :type kind :code type :length record-length))))
          (push event events)
          (incf offset record-length))))
    (values (nreverse events) offset)))

(defun parse-drm-events (octets &key (start 0) (end (length octets)))
  "Parse whole drm_event records from OCTETS[START:END]; see the pointer version."
  (cffi:with-pointer-to-vector-data (data octets)
    (parse-drm-events-from-pointer (cffi:inc-pointer data start) (- end start))))

;;; ---------------------------------------------------------------------------
;;; The kernel calls, as a protocol of twelve functions
;;; ---------------------------------------------------------------------------
;;
;; Two layers, on purpose.  The generic functions below are the *only* place in
;; the project that calls these ioctls and this read, and each one is a single
;; call with its arguments in kernel order: CREATE_DUMB, MAP_DUMB plus mmap,
;; munmap, ADDFB, RMFB, DESTROY_DUMB, IS_MASTER, SET_MASTER, DROP_MASTER, SETCRTC,
;; PAGE_FLIP, and read(2) on the descriptor.  Everything above them -- DRM-CREATE-DUMB,
;; DRM-SET-MODE, DRM-PAGE-FLIP, DRM-OPEN-SCANOUT and the rest -- is the contract:
;; it checks arguments, records what it made, and releases things in the one order
;; that is safe.
;;
;; The split exists so that a unit test can stand in a recording device: it
;; overrides these and sees exactly the arguments and the order a real card would
;; have been given, without a card, a kernel, or root (D7: generic functions where
;; wlroots has vtables).

(defgeneric drm-inventory (device)
  (:documentation "Enumerate DEVICE.  Returns a DRM-INVENTORY of Lisp values."))

(defgeneric drm-claim-dumb (device width height bits-per-pixel)
  (:documentation "CREATE_DUMB.  Returns (values handle pitch size-bytes)."))

(defgeneric drm-map-dumb-memory (device handle size)
  (:documentation "MAP_DUMB and mmap.  Returns the mapping, read-write."))

(defgeneric drm-unmap-dumb-memory (device buffer)
  (:documentation "munmap BUFFER's mapping."))

(defgeneric drm-allocate-framebuffer (device buffer)
  (:documentation "ADDFB.  Returns the framebuffer id the kernel assigned."))

(defgeneric drm-release-framebuffer (device id)
  (:documentation "RMFB."))

(defgeneric drm-release-dumb (device handle)
  (:documentation "DESTROY_DUMB: frees the memory the handle names."))

(defgeneric drm-query-master (device)
  (:documentation "IS_MASTER: is DEVICE master right now?  A recording device
answers from its own slot, which is why the contract asks rather than calling
DRM-IS-MASTER itself."))

(defgeneric drm-request-master (device)
  (:documentation "SET_MASTER.  A card another client is presenting on answers
EBUSY, which is the kernel's way of refusing to take the screen from it."))

(defgeneric drm-release-master (device)
  (:documentation "DROP_MASTER: give the card back."))

(defgeneric drm-program-crtc (device crtc-id framebuffer-id x y connector-ids mode)
  (:documentation "SETCRTC with CONNECTOR-IDS and MODE, or with neither (which
switches the CRTC off)."))

(defgeneric drm-queue-page-flip (device crtc-id framebuffer-id user-data)
  (:documentation "PAGE_FLIP, asking for the completion event.  Returns before the
flip is retired: DRM-AWAIT-FLIP is what waits."))

(defgeneric drm-read-events (device &key timeout-ms)
  (:documentation "The next events the kernel has for DEVICE, as plists, or NIL
after TIMEOUT-MS.

One read(2) can hold several events, so what is not consumed is kept on the
device; a partial record at the end of a read is kept as octets and prepended to
the next one."))

;;; ---------------------------------------------------------------------------
;;; The contract
;;; ---------------------------------------------------------------------------

(defun drm-create-dumb (device width height &key (bits-per-pixel +dumb-buffer-bits-per-pixel+))
  "Ask DEVICE for a WIDTH x HEIGHT linear buffer: unmapped, and with no
framebuffer id yet.

The driver chooses the pitch, and a pitch below WIDTH x 4 is refused here rather
than trusted: every pixel access multiplies by it, so a driver answering with a
narrower pitch would have us write one row over another."
  (unless (and (plusp width) (plusp height))
    (error "a dumb buffer needs a positive size, got ~Dx~D" width height))
  (multiple-value-bind (handle pitch size) (drm-claim-dumb device width height bits-per-pixel)
    (when (< pitch (* width 4))
      (error "the driver answered a ~D-byte pitch for a ~D-pixel-wide buffer" pitch width))
    (make-instance 'dumb-buffer
                   :device device
                   :width width
                   :height height
                   :bits-per-pixel bits-per-pixel
                   :handle handle
                   :pitch pitch
                   :size (max size (* pitch height)))))

(defun drm-map-dumb (device buffer)
  "Map BUFFER read-write.  Idempotent: mapping a mapped buffer returns it."
  (unless (dumb-buffer-mapped-p buffer)
    (setf (dumb-buffer-mapping buffer)
          (drm-map-dumb-memory device (dumb-buffer-handle buffer) (dumb-buffer-size buffer))))
  buffer)

(defun drm-unmap-dumb (device buffer)
  "Unmap BUFFER if it is mapped.  Idempotent."
  (when (dumb-buffer-mapped-p buffer)
    (drm-unmap-dumb-memory device buffer)
    (setf (dumb-buffer-mapping buffer) nil))
  buffer)

(defun drm-add-framebuffer (device buffer)
  "Name BUFFER's memory to a CRTC.  Returns the framebuffer id, which is also
recorded on the buffer so that DRM-DESTROY-DUMB can release it first."
  (unless (dumb-buffer-framebuffer-p buffer)
    (setf (dumb-buffer-framebuffer-id buffer) (drm-allocate-framebuffer device buffer)))
  (dumb-buffer-framebuffer-id buffer))

(defun drm-remove-framebuffer (device buffer)
  "Drop BUFFER's framebuffer id if it has one.  Idempotent."
  (when (dumb-buffer-framebuffer-p buffer)
    (drm-release-framebuffer device (dumb-buffer-framebuffer-id buffer))
    (setf (dumb-buffer-framebuffer-id buffer) nil))
  buffer)

(defun drm-destroy-dumb (device buffer)
  "Release BUFFER, in the order KMS requires: the framebuffer that names the
memory, then the mapping, then the memory itself.

A framebuffer left behind would keep the memory alive after DESTROY_DUMB (a leak
the driver may only report at close), and a mapping left behind would be a
SIGBUS waiting for the next render."
  (drm-remove-framebuffer device buffer)
  (drm-unmap-dumb device buffer)
  (drm-release-dumb device (dumb-buffer-handle buffer))
  (values))

;;; ---------------------------------------------------------------------------
;;; Master, and the state that has to be given back
;;; ---------------------------------------------------------------------------
;;
;; A program that sets a mode is a program that took the screen, and taking the
;; screen obliges it to put back what it found.  DRM-OPEN-SCANOUT reads the CRTC's
;; state before it changes it and DRM-CLOSE-SCANOUT writes that state back before
;; it releases a single buffer: a framebuffer still on screen cannot be removed
;; (the kernel answers EBUSY), and one that is removed while scanned out would be
;; a screen showing freed memory.

(defun drm-refresh-master (device)
  "What was recorded about DEVICE's master state; the kernel is not asked.

There is no side-effect-free way to ask: the kernel has no `am I master' ioctl, and
libdrm's drmIsMaster tries to take master.  So the state is what DRM-TAKE-MASTER and
DRM-DROP-MASTER recorded -- which is also the only thing closing a scanout needs to
know, and the reason a refused SET MASTER is not an error this function can hide."
  (drm-device-master-p device))

(defun drm-take-master (device)
  "Ask the kernel to make DEVICE's descriptor master, and record its answer.

Signals DRM-ERROR with the ioctl's own errno when it refuses: EBUSY when another
client holds the card, EACCES when this descriptor was never granted the right -- a
seat hands out a descriptor, not the right, and logind is the one that grants it (or
does not).  T means the kernel agreed.

The record is the kernel's answer and nothing else, which is why DRM-REFRESH-MASTER
is not called here: it used to ask libdrm's drmIsMaster, and that is a SET MASTER call
in disguise, so the `answer' could be yes for a card that had just refused us."
  (drm-request-master device)
  (setf (drm-device-master-p device) t)
  t)

(defun drm-drop-master (device)
  "Give DEVICE back, and record that we did.  Idempotent.

The record is cleared only after the kernel accepted the drop, so a drop that failed
leaves the device marked master -- which is the truth."
  (when (drm-device-master-p device)
    (drm-release-master device)
    (setf (drm-device-master-p device) nil))
  (values))

(defun drm-crtc-connectors (inventory crtc-id)
  "The connector ids currently driven through CRTC-ID.

SETCRTC with a mode and *no* connectors is EINVAL -- the kernel will not put a
timing on a CRTC without being told what it feeds -- so a restore has to name the
connectors again, and this is what names them: every connector whose attached
encoder says it is feeding this CRTC."
  (loop for connector in (drm-inventory-connectors inventory)
        for encoder = (drm-inventory-encoder inventory
                                             (drm-connector-encoder-id connector))
        when (and encoder (= crtc-id (drm-encoder-crtc-id encoder)))
          collect (drm-connector-id connector)))

(defun drm-crtc-state (device crtc-id)
  "What CRTC-ID is doing right now, as a fresh DRM-CRTC.

Read through the same enumeration a probe uses, so the state a scanout saves and
the state a probe prints are the same kind of value: the framebuffer that was on
screen and the mode it was programmed with, which is all SETCRTC needs to restore
it."
  (let ((crtc (drm-inventory-crtc (drm-inventory device) crtc-id)))
    (unless crtc
      (error "the card has no CRTC ~D" crtc-id))
    crtc))

(defun drm-set-mode (device crtc-id connector framebuffer-id &key mode)
  "Program CRTC-ID with FRAMEBUFFER-ID and the mode MODE (the connector's choice
when MODE is NIL), driven through CONNECTOR.  Returns the mode it used."
  (let ((mode (or mode (drm-pick-mode connector))))
    (unless mode
      (error "connector ~A has no modes to set" (drm-connector-name connector)))
    (drm-program-crtc device crtc-id framebuffer-id 0 0
                      (list (drm-connector-id connector)) mode)
    mode))

(defun drm-restore-crtc (device state &key connector-ids)
  "Put CRTC-ID back the way DRM-CRTC-STATE found it, driven through CONNECTOR-IDS.

Both branches are real and only one of them takes connectors:

  * a saved state with a framebuffer is a CRTC that was showing something, and
    restoring it needs the connectors it was showing it through -- SETCRTC with a
    mode and an empty connector list is EINVAL, measured on vkms;
  * a saved state with no framebuffer is a CRTC that was off, and restoring it
    means switching it off: no framebuffer, no connectors, no mode.

A state that is inconsistent -- a mode with no framebuffer -- is restored as off,
because that is the nearest legal state to it and the kernel will not accept the
combination we read."
  (let ((buffer-id (drm-crtc-buffer-id state))
        (mode (and (drm-crtc-mode-valid-p state) (drm-crtc-mode state))))
    (if (and (plusp buffer-id) connector-ids)
        (drm-program-crtc device (drm-crtc-id state) buffer-id
                          (drm-crtc-x state) (drm-crtc-y state)
                          connector-ids mode)
        (drm-program-crtc device (drm-crtc-id state) 0 0 0 '() nil))
    state))

;;; ---------------------------------------------------------------------------
;;; Flips, and waiting for them
;;; ---------------------------------------------------------------------------
;;
;; PAGE_FLIP queues a flip and returns; the display retires it at the next vblank
;; and the kernel then writes a completion event.  Waiting for that event is what
;; makes double buffering honest: the buffer just replaced is not drawn into again
;; until the display has stopped reading it.

(defun drm-next-event (device &key (timeout-ms -1))
  "The next single event, or NIL after TIMEOUT-MS.

One read can deliver several events; the ones this call does not hand out stay on
the device for the next call, so waiting for one event never throws the others
away."
  (let ((queued (drm-device-events device)))
    (if queued
        (pop (drm-device-events device))
        (let ((events (drm-read-events device :timeout-ms timeout-ms)))
          (when events
            (setf (drm-device-events device) (rest events))
            (first events))))))

(defun drm-await-flip (device crtc-id &key (timeout-ms 1000))
  "Wait for the completion of the flip queued for CRTC-ID.

Signals DRM-ERROR (with no errno: nothing failed, time passed) after TIMEOUT-MS.
Events for other CRTCs are skipped and stay on the device: they were never ours
to consume."
  (let ((deadline (and timeout-ms (+ (ffi:monotonic-seconds) (/ timeout-ms 1000)))))
    (loop
      (let ((remaining (if deadline
                           (max 0 (round (* 1000 (- deadline (ffi:monotonic-seconds)))))
                           -1)))
        (let ((event (drm-next-event device :timeout-ms remaining)))
          (cond ((null event)
                 (when (or (null deadline) (<= deadline (ffi:monotonic-seconds)))
                   (error 'drm-error :operation :await-flip :errno nil
                                      :path (drm-device-path device))))
                ((and (eq :flip-complete (getf event :type))
                      (= crtc-id (getf event :crtc-id)))
                 (return event))))))))

(defun drm-page-flip (device crtc-id framebuffer-id &key (timeout-ms 1000))
  "Queue a flip of CRTC-ID to FRAMEBUFFER-ID, wait for it to be retired, and return
the completion event: :SEQUENCE, :TV-SEC, :TV-USEC, :CRTC-ID and :USER-DATA.

The user-data is a per-device flip counter, so the event can be told apart from
somebody else's and the sequence numbers a caller sees can be checked for being
the kernel's and not ours."
  (let ((user-data (incf (drm-device-flips device))))
    (drm-queue-page-flip device crtc-id framebuffer-id user-data)
    (drm-await-flip device crtc-id :timeout-ms timeout-ms)))

;;; ---------------------------------------------------------------------------
;;; A scanout: a CRTC taken, two frames, and the state to give back
;;; ---------------------------------------------------------------------------
;;
;; The unit a compositor scans out with.  It owns the things that have to be
;; released in the right order -- master, the buffers, the CRTC's previous state --
;; and it owns them for exactly as long as it is open, so giving the screen back is
;; closing it and not a checklist a caller has to remember.
;;
;; Two buffers, not one: a single framebuffer can only be redrawn while the
;; display is not reading it, which is the tear double buffering exists to avoid.

(defun drm-virtual-driver-p (name)
  "Is NAME a DRM driver whose scanout reaches no physical display?

vkms is the kernel's virtual KMS: a card with a connector, modes, flips and
vblank, and no screen on the other end.  It is the only card this project's gate
and demo will take master from without being told to (D55); a real driver is a
person's decision, because taking it takes their screen."
  (member (string-downcase (or name "")) '("vkms") :test #'string=))

(defun drm-connector-crtcs (inventory connector)
  "The CRTC ids CONNECTOR can be driven by, from its encoders' possible-CRTC masks.

The mask is over the *index* of a CRTC in the resources array, which is the order
DRM-INVENTORY keeps, so the index is what makes the mask mean an id."
  (let ((crtcs (coerce (drm-inventory-crtcs inventory) 'vector))
        (ids '()))
    (dolist (encoder-id (drm-connector-encoders connector))
      (let ((encoder (drm-inventory-encoder inventory encoder-id)))
        (when encoder
          (loop for index below (length crtcs)
                when (logbitp index (drm-encoder-possible-crtcs encoder))
                  do (pushnew (drm-crtc-id (aref crtcs index)) ids)))))
    (nreverse ids)))

(defun drm-scanout-crtc (inventory connector &key crtc-id)
  "The CRTC to program for CONNECTOR: CRTC-ID when it is possible, otherwise a
CRTC that is currently off, otherwise the first one this connector's encoders
allow.

A CRTC already scanning something out is not stolen: on a card with more than one
output, taking an idle CRTC is what keeps the other screen working.  Multi-head
assignment (the rest of the masks, and what happens when nothing is idle) is phase
5's problem; this is the single-output case, checked rather than assumed."
  (let* ((possible (or (drm-connector-crtcs inventory connector)
                       (mapcar #'drm-crtc-id (drm-inventory-crtcs inventory)))))
    (when crtc-id
      (unless (member crtc-id possible)
        (error "CRTC ~D cannot drive connector ~A (possible: ~{~D~^, ~})"
               crtc-id (drm-connector-name connector) possible))
      (return-from drm-scanout-crtc crtc-id))
    (or (loop for id in possible
              for crtc = (drm-inventory-crtc inventory id)
              when (and crtc (zerop (drm-crtc-buffer-id crtc)))
                return id)
        (first possible)
        (error "the card has no CRTC to program"))))

(defclass drm-scanout ()
  ((device :initarg :device :reader drm-scanout-device)
   (crtc-id :initarg :crtc-id :reader drm-scanout-crtc-id)
   (connector :initarg :connector :reader drm-scanout-connector)
   (mode :initarg :mode :reader drm-scanout-mode)
   (buffers :initarg :buffers :reader drm-scanout-buffers)   ; a vector, one per frame
   (saved-state :initarg :saved-state :reader drm-scanout-saved-state)
   (saved-connectors :initarg :saved-connectors :initform '()
                     :reader drm-scanout-saved-connectors)
   (front :initform 0 :accessor drm-scanout-front)
   (frames :initform 0 :accessor drm-scanout-frames)
   (master-p :initarg :master-p :initform nil :accessor drm-scanout-master-p)
   (last-event :initform nil :accessor drm-scanout-last-event)
   (open-p :initform t :accessor drm-scanout-open-p))
  (:documentation
   "A CRTC we took, the connector it drives, the mode it is programmed with, and
the buffers we flip between.

FRAMES counts completed flips, so it is the frame number the next buffer is chosen
with.  SAVED-STATE is the CRTC as it was before this object existed -- the thing
DRM-CLOSE-SCANOUT puts back.  OPEN-P is false once closing has begun, which makes
closing idempotent and makes presenting a closed scanout an error rather than a
flip into nowhere."))

(defun drm-scanout-width (scanout)
  (drm-mode-hdisplay (drm-scanout-mode scanout)))

(defun drm-scanout-height (scanout)
  (drm-mode-vdisplay (drm-scanout-mode scanout)))

(defun drm-scanout-buffer (scanout index)
  "One of SCANOUT's buffers, for a renderer to draw the next frame into."
  (aref (drm-scanout-buffers scanout) index))

(defun drm-scanout-buffer-count (scanout)
  (length (drm-scanout-buffers scanout)))

(defun drm-scanout-next-buffer (scanout)
  "The buffer the next frame should be drawn into: FRAMES modulo the count."
  (drm-scanout-buffer scanout (mod (drm-scanout-frames scanout)
                                   (drm-scanout-buffer-count scanout))))

(defun drm-open-scanout (device &key connector crtc-id mode (buffer-count 2))
  "Take DEVICE's screen for a CONNECTOR at MODE and return the DRM-SCANOUT.

In this order and no other: become master, save the CRTC's state, allocate, map and
name BUFFER-COUNT buffers, program the CRTC with the first.  An error anywhere in
the middle undoes what was done -- restore, destroy, drop master -- and re-signals,
so a failed open never leaves a card taken.

CONNECTOR is a DRM-CONNECTOR or a name such as `Virtual-1'; the first connected
connector is used when it is NIL.  MODE defaults to the connector's choice."
  (unless (<= 1 buffer-count 4)
    (error "a scanout wants one to four buffers, not ~D" buffer-count))
  (let* ((inventory (drm-inventory device))
         (connector (if (stringp connector)
                        (or (drm-inventory-connector inventory connector)
                            (error "the card has no connector called ~A" connector))
                        (or connector
                            (first (drm-inventory-connected-connectors inventory))
                            (error "no connector is connected"))))
         (crtc-id (drm-scanout-crtc inventory connector :crtc-id crtc-id))
         (mode (or mode (drm-pick-mode connector)
                  (error "connector ~A has no modes" (drm-connector-name connector))))
         (width (drm-mode-hdisplay mode))
         (height (drm-mode-vdisplay mode))
         (saved-state nil)
         (saved-connectors '())
         (buffers '())
         (took-master nil)
         (opened nil))
    (unwind-protect
         (progn
           ;; Master is best effort here, and the reason is measured (D59): a VT
           ;; seat hands over a descriptor and logind may not have granted the right,
           ;; so SET MASTER answers EACCES on a card nobody else is using; wlroots
           ;; carries on and lets the modeset decide, and so does this.  EBUSY (another
           ;; client owns the card) is tolerated the same way: the CRTC programming is
           ;; where the kernel says no, and that error is the honest one.
           (handler-case (drm-take-master device)
             (drm-error (condition)
               (unless (member (drm-error-errno condition)
                               (list ffi:+eacces+ ffi:+ebusy+))
                 (error condition))))
           (setf took-master (drm-device-master-p device)
                 saved-state (drm-crtc-state device crtc-id)
                 ;; What the CRTC was feeding, so a later restore can name it.
                 saved-connectors (drm-crtc-connectors
                                   (drm-inventory device) crtc-id))
           (dotimes (index buffer-count)
             (let ((buffer (drm-create-dumb device width height)))
               (push buffer buffers)
               (drm-map-dumb device buffer)
               (drm-add-framebuffer device buffer)))
           (setf buffers (nreverse buffers))
           (drm-set-mode device crtc-id connector
                         (dumb-buffer-framebuffer-id (first buffers))
                         :mode mode)
           (setf opened t)
           (make-instance 'drm-scanout
                          :device device :crtc-id crtc-id :connector connector
                          :mode mode :buffers (coerce buffers 'vector)
                          :saved-state saved-state
                          :saved-connectors saved-connectors
                          :master-p (drm-device-master-p device)))
      ;; A failed open: undo what was done, newest first, without letting one
      ;; failure hide the next.  On success OPENED is true and the scanout owns
      ;; all of this -- the only reason not to leave it is a bug in MAKE-INSTANCE.
      (unless opened
        (dolist (buffer buffers)
          (ignore-errors (drm-destroy-dumb device buffer)))
        (when saved-state
          (ignore-errors (drm-restore-crtc device saved-state
                                           :connector-ids saved-connectors)))
        (when (and took-master (drm-device-open-p device)
                   (drm-device-master-p device))
          (ignore-errors (drm-drop-master device)))))))

(defun drm-scanout-present (scanout buffer &key (timeout-ms 1000))
  "Flip SCANOUT to BUFFER and wait until the display has retired it.

Returns the completion event.  Drawing into BUFFER again before this returns would
be drawing into the frame the display is still reading, which is why there is no
version of this that does not wait."
  (unless (drm-scanout-open-p scanout)
    (error "this scanout is closed"))
  (let* ((device (drm-scanout-device scanout))
         (event (drm-page-flip device (drm-scanout-crtc-id scanout)
                               (drm-add-framebuffer device buffer)
                               :timeout-ms timeout-ms)))
    (setf (drm-scanout-front scanout)
          (or (position buffer (drm-scanout-buffers scanout) :test #'eq)
              (drm-scanout-front scanout)))
    (incf (drm-scanout-frames scanout))
    (setf (drm-scanout-last-event scanout) event)
    event))

(defun drm-scanout-present-next (scanout &key (timeout-ms 1000))
  "Draw into DRM-SCANOUT-NEXT-BUFFER, then present it."
  (drm-scanout-present scanout (drm-scanout-next-buffer scanout) :timeout-ms timeout-ms))

(defun drm-close-scanout (scanout)
  "Give the screen back and release everything, in the order KMS allows.

Restore the CRTC's saved state, destroy the buffers (RMFB cannot remove a
framebuffer a CRTC is still scanning), then drop master.  Each step is attempted
even if an earlier one failed, and the first failure is signalled afterwards: a
restore that fails must not also leak the buffers, and a buffer that will not go
away must not leave the card taken.

Idempotent: a second call does nothing."
  (when (drm-scanout-open-p scanout)
    (setf (drm-scanout-open-p scanout) nil)
    (let ((device (drm-scanout-device scanout))
          (failures '()))
      (flet ((attempt (thunk)
               (handler-case (funcall thunk)
                 (error (condition) (push condition failures)))))
        ;; Attempted even when the scanout is not master: if the CRTC was
        ;; programmed, the state has to go back, and a refusal is reported rather
        ;; than skipped.  Master itself is dropped only when it was taken.
        (when (drm-scanout-saved-state scanout)
          (attempt (lambda ()
                     (drm-restore-crtc device (drm-scanout-saved-state scanout)
                                       :connector-ids
                                       (drm-scanout-saved-connectors scanout)))))
        (loop for buffer across (drm-scanout-buffers scanout)
              do (attempt (lambda () (drm-destroy-dumb device buffer))))
        (when (drm-scanout-master-p scanout)
          (attempt (lambda () (drm-drop-master device)))
          (setf (drm-scanout-master-p scanout) nil)))
      (when failures
        (error (first (last failures))))))
  (values))

;;; ---------------------------------------------------------------------------
;;; The cursor is in the frame: rendering into the scanout (D58)
;;; ---------------------------------------------------------------------------
;;
;; There is no cursor plane here and no overlay plane: the pointer is drawn into the
;; same mapping the CRTC scans out of, as the last thing the scene draws.  Two facts
;; make that a function of its own rather than a line in a compositor.
;;
;;   1. The buffer's pitch is the driver's, not the width's.  A dumb buffer at
;;      3840x2160 on this monitor has pitch 15360 (= width * 4), but the kernel is
;;      allowed to pad it, and every write goes through the target's stride.  A
;;      picture drawn as if stride were width * 4 is a sheared picture, and a clip
;;      that ignores the padding writes into a row it does not own -- D55's fill-rect
;;      bug in a different coat.
;;   2. The scene already draws the cursor last, at the output's scale, with the
;;      client's image or the built-in arrow (D40, D41).  So "the cursor in the
;;      scanout" is not a second renderer: it is the same scene render, given a
;;      target over the scanout buffer instead of an in-memory one.  This is the
;;      function that says so, and the only place that knows both halves.

(defun drm-scanout-target (buffer)
  "A pixman target over BUFFER's mapping, at the driver's pitch.

The mapping stays ours: the target borrows it, and DESTROY-TARGET frees only the
pixman image.  That is the contract MAKE-TARGET-OVER-POINTER states, and it is why
this can be done per frame without copying 33 MB."
  (render:make-target-over-pointer (dumb-buffer-mapping buffer)
                                   (dumb-buffer-width buffer)
                                   (dumb-buffer-height buffer)
                                   :stride (dumb-buffer-pitch buffer)))

(defun drm-scanout-render (scanout scene buffer &key damage (background #xFF000000))
  "Draw SCENE into BUFFER (one of SCANOUT's) and return the surfaces to release.

DAMAGE is a region in device pixels, or NIL for the whole buffer.  The background is
painted only on a full repaint: a damaged frame must leave the rest of the buffer as
it was, or the buffer's age stops meaning anything (D50).  The cursor is drawn by the
scene, last, into this mapping -- a software cursor in the scanout, because this
design has no hardware cursor plane.

Nothing is presented here.  DRM-SCANOUT-PRESENT is what flips and waits for the
kernel's vblank: drawing and presenting are separate so a compositor can draw the
next frame while the last is being scanned out, and so a test can read the pixels
back from the mapping before they ever reach a display."
  (declare (ignore scanout))
  (let ((target (drm-scanout-target buffer)))
    (unwind-protect
         (progn
           (unless damage
             (render:fill-target target background))
           (scene:scene-render-items scene target :damage damage))
      (render:destroy-target target))))

;;; ---------------------------------------------------------------------------
;;; The kernel calls
;;; ---------------------------------------------------------------------------

(defmethod drm-inventory ((device drm-device))
  (read-inventory device))

(defun drm-hotplug-key (device)
  "What is plugged into DEVICE now, from a fresh enumeration.

Read-only, and allowed without master, which is what makes it usable as a poll while
a compositor is presenting on the card."
  (drm-inventory-hotplug-key (drm-inventory device)))

(defmethod drm-claim-dumb ((device drm-device) width height bits-per-pixel)
  (cffi:with-foreign-objects ((handle :uint32) (pitch :uint32) (size :uint64))
    (setf (cffi:mem-ref handle :uint32) 0
          (cffi:mem-ref pitch :uint32) 0
          (cffi:mem-ref size :uint64) 0)
    (let ((result (%drm-mode-create-dumb-buffer (device-fd device) width height
                                               bits-per-pixel 0 handle pitch size)))
      (when (minusp result)
        (drm-failed 'drm-mode-create-dumb-buffer
                    :errno (result-errno result) :path (drm-device-path device)))
      (values (cffi:mem-ref handle :uint32)
              (cffi:mem-ref pitch :uint32)
              (cffi:mem-ref size :uint64)))))

(defmethod drm-map-dumb-memory ((device drm-device) handle size)
  (cffi:with-foreign-object (offset :uint64)
    (setf (cffi:mem-ref offset :uint64) 0)
    (let ((result (%drm-mode-map-dumb-buffer (device-fd device) handle offset)))
      (when (minusp result)
        (drm-failed 'drm-mode-map-dumb-buffer
                    :errno (result-errno result) :path (drm-device-path device)))
      (handler-case
          (ffi:map-file (device-fd device) size
                        :offset (cffi:mem-ref offset :uint64)
                        :protection (logior ffi:+prot-read+ ffi:+prot-write+))
        (ffi:io-error (condition)
          (drm-failed 'mmap :errno (ffi:io-error-errno condition)
                            :path (drm-device-path device)))))))

(defmethod drm-unmap-dumb-memory ((device drm-device) (buffer dumb-buffer))
  (declare (ignore device))
  (ffi:unmap-file (dumb-buffer-mapping buffer) (dumb-buffer-size buffer)))

(defmethod drm-allocate-framebuffer ((device drm-device) (buffer dumb-buffer))
  (cffi:with-foreign-object (id :uint32)
    (setf (cffi:mem-ref id :uint32) 0)
    (let ((result (%drm-mode-add-fb (device-fd device)
                                    (dumb-buffer-width buffer)
                                    (dumb-buffer-height buffer)
                                    (dumb-buffer-depth buffer)
                                    (dumb-buffer-bits-per-pixel buffer)
                                    (dumb-buffer-pitch buffer)
                                    (dumb-buffer-handle buffer)
                                    id)))
      (when (minusp result)
        (drm-failed 'drm-mode-add-fb
                    :errno (result-errno result) :path (drm-device-path device)))
      (cffi:mem-ref id :uint32))))

(defmethod drm-release-framebuffer ((device drm-device) id)
  (let ((result (%drm-mode-remove-fb (device-fd device) id)))
    (when (minusp result)
      (drm-failed 'drm-mode-rmfb
                  :errno (result-errno result) :path (drm-device-path device))))
  (values))

(defmethod drm-release-dumb ((device drm-device) handle)
  (let ((result (%drm-mode-destroy-dumb-buffer (device-fd device) handle)))
    (when (minusp result)
      (drm-failed 'drm-mode-destroy-dumb-buffer
                  :errno (result-errno result) :path (drm-device-path device))))
  (values))

;;; The four calls that change the screen, and the one that waits for them.

(defmethod drm-query-master ((device drm-device))
  "What was recorded, for a device that is still open -- see DRM-REFRESH-MASTER.

The kernel is not asked: libdrm's drmIsMaster would try to take master as its way of
answering, and this project does not take a screen to ask a question about one."
  (and (drm-device-open-p device)
       (drm-device-master-p device)))

(defmethod drm-request-master ((device drm-device))
  (let ((result (%drm-set-master (device-fd device))))
    (when (minusp result)
      (drm-failed :take-master
                  :errno (result-errno result) :path (drm-device-path device))))
  (values))

(defmethod drm-release-master ((device drm-device))
  (let ((result (%drm-drop-master (device-fd device))))
    (when (minusp result)
      (drm-failed :drop-master
                  :errno (result-errno result) :path (drm-device-path device))))
  (values))

(defmethod drm-program-crtc ((device drm-device) crtc-id framebuffer-id x y connector-ids mode)
  "SETCRTC.  CONNECTOR-IDS NIL and MODE NIL is the kernel's way of switching a
CRTC off, which is a state a restore has to be able to ask for."
  (cffi:with-foreign-object (mode-info '(:struct drm-mode-info))
    (let ((mode-pointer (cffi:null-pointer))
          (connectors (cffi:null-pointer))
          (count 0))
      (when mode
        (write-mode-info mode mode-info)
        (setf mode-pointer mode-info))
      (unwind-protect
           (progn
             (when (plusp (length connector-ids))
               (setf count (length connector-ids)
                     connectors (cffi:foreign-alloc :uint32 :count count))
               (loop for id in connector-ids
                     for index from 0
                     do (setf (cffi:mem-aref connectors :uint32 index) id)))
             (let ((result (%drm-mode-set-crtc (device-fd device) crtc-id framebuffer-id
                                               x y connectors count mode-pointer)))
               (when (minusp result)
                 (drm-failed :program-crtc
                             :errno (result-errno result)
                             :path (drm-device-path device)))))
        (unless (cffi:null-pointer-p connectors)
          (cffi:foreign-free connectors))))))

(defmethod drm-queue-page-flip ((device drm-device) crtc-id framebuffer-id user-data)
  (let ((result (%drm-mode-page-flip (device-fd device) crtc-id framebuffer-id
                                     +page-flip-event+
                                     (cffi:make-pointer (or user-data 0)))))
    (when (minusp result)
      (drm-failed :queue-page-flip
                  :errno (result-errno result) :path (drm-device-path device))))
  (values))

(defmethod drm-read-events ((device drm-device) &key (timeout-ms -1))
  "One read(2)'s worth of events, parsed.  Waits at most TIMEOUT-MS for the
descriptor to be readable; -1 waits until it is."
  (let ((wait (ffi:poll-fd (device-fd device) :timeout-ms timeout-ms)))
    (case wait
      (:read
       (cffi:with-foreign-object (buffer :uint8 +event-buffer-size+)
         (multiple-value-bind (count eof)
             (ffi:read-into-pointer (device-fd device) buffer +event-buffer-size+)
           (declare (ignore eof))
           (let* ((fresh (ffi:mapped-octets buffer 0 count))
                  (leftover (drm-device-event-leftovers device))
                  (octets (if leftover
                              (concatenate '(vector (unsigned-byte 8)) leftover fresh)
                              fresh)))
             (multiple-value-bind (events consumed) (parse-drm-events octets)
               (setf (drm-device-event-leftovers device)
                     (if (< consumed (length octets))
                         (subseq octets consumed)
                         nil))
               events)))))
      (:timeout '())
      (t (error 'drm-error :operation :read-events :errno nil
                             :path (drm-device-path device))))))

;;; ---------------------------------------------------------------------------
;;; The kernel's own view: sysfs
;;; ---------------------------------------------------------------------------
;;
;; libdrm's view of the card and the kernel's are two independent witnesses, and
;; the gate compares them.  Reading sysfs is also how a probe answers questions
;; about a card it cannot open at all, which is the case on a machine whose
;; session has not given us the node.

(defun read-file-or-nil (path)
  (let ((file (uiop:probe-file* path)))
    (when file
      (string-trim '(#\Newline #\Space #\Tab #\Return)
                   (uiop:read-file-string file)))))

(defun directory-name (directory)
  "The last component of DIRECTORY's pathname: `card1-HDMI-A-1', `card1'."
  (let ((parts (pathname-directory (uiop:ensure-directory-pathname directory))))
    (and parts (car (last parts)))))

(defun drm-sysfs-cards (&key (root "/sys/class/drm"))
  "The cards under ROOT, as names such as `card1'.

Connector directories (`card1-HDMI-A-1') and render nodes are not cards: a card
is the node whose name is `card' followed only by digits."
  (let ((directory (uiop:probe-file* (uiop:ensure-directory-pathname root))))
    (sort (loop for entry in (and directory (uiop:subdirectories directory))
                for name = (directory-name entry)
                when (and name (> (length name) 4)
                          (uiop:string-prefix-p "card" name)
                          (every #'digit-char-p (subseq name 4)))
                  collect name)
          #'string<)))

(defun drm-sysfs-state (card &key (root "/sys/class/drm"))
  "The kernel's view of CARD's connectors: one plist per connector.

Each plist has :NAME, :STATUS, :ENABLED, :DPMS and :MODES as the files spell
them, so that comparing it with libdrm's view compares two witnesses instead of
asking our own arithmetic the same question twice."
  (let ((directory (uiop:probe-file* (uiop:ensure-directory-pathname root)))
        (prefix (concatenate 'string card "-")))
    (loop for entry in (and directory (uiop:subdirectories directory))
          for name = (directory-name entry)
          when (and name (> (length name) (length prefix))
                    (uiop:string-prefix-p prefix name))
            collect (let ((connector (subseq name (length prefix))))
                      (flet ((file (file-name)
                               (merge-pathnames file-name
                                                (uiop:ensure-directory-pathname entry))))
                        (list :name connector
                              :status (read-file-or-nil (file "status"))
                              :enabled (read-file-or-nil (file "enabled"))
                              :dpms (read-file-or-nil (file "dpms"))
                              :modes (let ((text (read-file-or-nil (file "modes"))))
                                       (if (or (null text) (zerop (length text)))
                                           '()
                                           (uiop:split-string text :separator '(#\Newline))))))))))

(defun drm-sysfs-driver-name (card &key (root "/sys/class/drm"))
  "The driver the kernel bound to CARD, from its uevent: `amdgpu', `i915'.

A second witness for what drmGetVersion calls the driver name, and the one a
person can read without opening anything.  NIL when the card has no uevent (a
virtual or leased device may not)."
  (let ((text (read-file-or-nil (format nil "~A/~A/device/uevent"
                                        (string-right-trim "/" root) card))))
    (loop for line in (and text (uiop:split-string text :separator '(#\Newline)))
          when (uiop:string-prefix-p "DRIVER=" line)
            return (subseq line (length "DRIVER=")))))

(defun drm-driver-at (path)
  "The driver's own name for the card at PATH (`vkms', `amdgpu'), opening and
closing it.

The kernel's uevent is not always the same answer: vkms presents as a faux device
and /sys reports `faux_driver', while libdrm and the driver itself say `vkms'.
A program deciding whether a card is a test bed or somebody's screen needs the
name the driver answers to, so this asks the card (D55)."
  (let ((device (open-drm-device path)))
    (unwind-protect (drm-device-driver-name device)
      (close-drm-device device))))

(defun drm-device-paths (&key (directory "/dev/dri"))
  "The card nodes in DIRECTORY, sorted: `card0', `card1'.

Not render nodes and not control nodes: this slice programs CRTCs, and a render
node has none."
  (let ((path (uiop:probe-file* (uiop:ensure-directory-pathname directory))))
    (sort (loop for entry in (and path (uiop:directory-files path))
                for name = (file-namestring entry)
                when (and (uiop:string-prefix-p "card" name)
                          (> (length name) 4)
                          (every #'digit-char-p (subseq name 4)))
                  collect (namestring entry))
          #'string<)))
