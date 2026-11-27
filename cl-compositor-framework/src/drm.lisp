;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cf.backend.drm v0: the card, what is plugged into it, and a dumb buffer
;;;; (docs/framework.md §2, PLAN.md phase 4).
;;;;
;;;; This is the first half of the DRM backend, and deliberately the half that
;;;; cannot change the screen.  Enumerating resources, connectors, encoders and
;;;; CRTCs, picking a mode, creating, mapping and freeing a scanout-sized dumb
;;;; buffer, and adding and removing a framebuffer all work on a card another
;;;; process owns, without DRM master, because none of it scans anything out.
;;;; SETCRTC and PAGE_FLIP do need master, and they are the next slice: taking
;;;; the display away from the session that owns it is a decision with a recovery
;;;; plan, not a side effect of a probe (D54).
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

(defun check-layouts ()
  "Refuse to load if a transcribed struct does not match this libdrm's ABI.

The sizes and the three offsets that matter were measured against the headers on
this machine (drm_version 56, drm_mode_res 80, drm_mode_connector 88,
drm_mode_encoder 20, drm_mode_info 68, drm_mode_crtc 100; mode_info.name at 36,
connector.modes at 40, crtc.mode at 28).  These are 64-bit sizes, which is the
same assumption wayland.ffi's socket check already makes."
  (flet ((size (type) (cffi:foreign-type-size type))
         (offset (type slot)
           (cffi:foreign-slot-offset type slot)))
    (unless (and (= 56 (size '(:struct drm-version)))
                 (= 80 (size '(:struct drm-mode-res)))
                 (= 88 (size '(:struct drm-mode-connector)))
                 (= 20 (size '(:struct drm-mode-encoder)))
                 (= 68 (size '(:struct drm-mode-info)))
                 (= 100 (size '(:struct drm-mode-crtc)))
                 (= 36 (offset '(:struct drm-mode-info) 'name))
                 (= 40 (offset '(:struct drm-mode-connector) 'modes))
                 (= 28 (offset '(:struct drm-mode-crtc) 'mode)))
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
;;; The device
;;; ---------------------------------------------------------------------------

(defclass drm-device ()
  ((path :initarg :path :reader drm-device-path)
   (fd :initarg :fd :accessor drm-device-fd)
   (driver-name :initarg :driver-name :initform "" :reader drm-device-driver-name)
   (version-major :initarg :version-major :initform 0 :reader drm-device-version-major)
   (version-minor :initarg :version-minor :initform 0 :reader drm-device-version-minor)
   (version-patchlevel :initarg :version-patchlevel :initform 0 :reader drm-device-version-patchlevel)
   (master-p :initarg :master-p :initform nil :reader drm-device-master-p)
   (capabilities :initarg :capabilities :initform '() :reader drm-device-capabilities))
  (:documentation
   "One open DRM device node: a card (or a render node) and what it says about
itself.

MASTER-P is what the kernel answered when we opened it, not what we want it to
be: a compositor that opens the card its own session already presents on gets
NIL, and that is the state this slice runs in (D54).  CAPABILITIES is a plist of
:DUMB-BUFFER and :PRIME, because a driver without dumb buffers is not a card a
compositor can use yet."))

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
    (handler-case
        (let ((version (%drm-get-version fd)))
          (when (cffi:null-pointer-p version)
            (drm-failed 'drm-get-version :path path))
          (unwind-protect
               (let ((capabilities
                       (list :dumb-buffer (plusp (capability fd +cap-dumb-buffer+))
                             :prime (plusp (capability fd +cap-prime+)))))
                 (make-instance 'drm-device
                                :path path
                                :fd fd
                                :driver-name (version-string version 'name 'name-length)
                                :version-major (cffi:foreign-slot-value version '(:struct drm-version) 'major)
                                :version-minor (cffi:foreign-slot-value version '(:struct drm-version) 'minor)
                                :version-patchlevel (cffi:foreign-slot-value version '(:struct drm-version) 'patchlevel)
                                :master-p (not (zerop (%drm-is-master fd)))
                                :capabilities capabilities))
            (%drm-free-version version)))
      (error (condition)
        (ffi:close-fd fd)
        (error condition)))))

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
;;; The kernel calls, as a six-function protocol
;;; ---------------------------------------------------------------------------
;;
;; Two layers, on purpose.  The six generic functions below are the *only* place
;; in the project that calls these ioctls, and each one is a single call with its
;; arguments in kernel order: CREATE_DUMB, MAP_DUMB plus mmap, munmap, ADDFB,
;; RMFB, DESTROY_DUMB.  Everything above them -- DRM-CREATE-DUMB, DRM-MAP-DUMB,
;; DRM-DESTROY-DUMB and the rest -- is the contract: it checks arguments, records
;; what it made, and releases things in the one order that is safe.
;;
;; The split exists so that a unit test can stand in a recording device: it
;; overrides the six and sees exactly the arguments and the order a real card
;; would have been given, without a card, a kernel, or root (D7: generic
;; functions where wlroots has vtables).

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
;;; The kernel calls
;;; ---------------------------------------------------------------------------

(defmethod drm-inventory ((device drm-device))
  (read-inventory device))

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
