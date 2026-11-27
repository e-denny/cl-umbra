;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; DRM tests: mode arithmetic, mode choice, connector naming, dumb-buffer
;;;; geometry, the release order, and the kernel's own view through sysfs (D54).
;;;;
;;;; No card is opened here.  The contract -- the functions a compositor calls --
;;;; is plain functions over a six-function protocol, so a recording device stands
;;;; in for the kernel and these tests assert the arguments and the order a real
;;;; card would have been given.  What only a real card can answer -- what is
;;;; plugged in, what the driver's pitch is, whether ADDFB is allowed without
;;;; master -- is scripts/drm-gate.lisp's business, and that is where it is
;;;; checked.
;;;;
;;;; Three levels, because three things go wrong independently:
;;;;
;;;;   * arithmetic: a refresh rate from a clock and two totals, a pixel from a
;;;;     padded pitch, a buffer's size from its pitch -- numbers a card cannot
;;;;     tell you are wrong;
;;;;   * policy: which mode a connector should be programmed with;
;;;;   * the syscall contract: what is asked for, and what is released first.

(in-package #:cl-user)

(defpackage #:wayland.test.drm
  (:use #:cl #:rove)
  (:local-nicknames (#:drm #:cf.backend.drm)
                    (#:ffi #:wayland.ffi))
  (:documentation "Tests for cf.backend.drm: pure arithmetic, policy and the
kernel-call contract (D54)."))

(in-package #:wayland.test.drm)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defvar *directory-counter* 0)

(defun make-test-directory ()
  (let ((path (format nil "/tmp/cl-wayland-drm-test-~D-~D/"
                      (get-universal-time) (incf *directory-counter*))))
    (ensure-directories-exist path)
    (ffi:chmod-path (string-right-trim "/" path) #o700)
    path))

(defmacro with-test-directory ((directory) &body body)
  (let ((path (gensym "PATH")))
    `(let ((,path (make-test-directory)))
       (unwind-protect
            (let ((,directory (pathname ,path)))
              (locally ,@body))
         (ignore-errors (uiop:delete-directory-tree (pathname ,path) :validate t))))))

(defun write-file (path text)
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output :if-exists :supersede
                               :if-does-not-exist :create)
    (write-string text stream)))

(defun make-mode (&key (name "3840x2160") (clock 594000) (width 3840) (height 2160)
                        (htotal 4400) (vtotal 2250) (type 0))
  "A mode with the fields the arithmetic uses; the sync fields are left at zero."
  (drm::%make-drm-mode :name name :clock clock
                       :hdisplay width :vdisplay height
                       :htotal htotal :vtotal vtotal :type type))

(defun make-connector (&key (name "HDMI-A-1") (id 138) (status :connected) modes)
  (drm::%make-drm-connector :id id :name name :type 11 :type-id 1
                            :status status :modes modes))

(defun make-inventory (&key connectors (crtcs '()) (encoders '()))
  (drm::%make-drm-inventory :driver-name "amdgpu" :driver-version "3.64.0"
                            :connectors connectors :crtcs crtcs :encoders encoders))

;;; ---------------------------------------------------------------------------
;;; A device that records what it was asked, and answers like a card
;;; ---------------------------------------------------------------------------

(defclass recording-drm-device (drm:drm-device)
  ((calls :initform '() :accessor recording-calls)
   (inventory :initarg :inventory :initform nil :accessor recording-inventory)
   (handle :initarg :handle :initform 7 :accessor recording-handle)
   (pitch :initarg :pitch :initform 64 :accessor recording-pitch)
   (size :initarg :size :initform 256 :accessor recording-size)
   (framebuffer :initarg :framebuffer :initform 42 :accessor recording-framebuffer)
   (mapping :initarg :mapping :initform nil :accessor recording-mapping))
  (:documentation
   "A DRM-DEVICE whose six kernel calls are recorded instead of made.

The pitch and size are the driver's answers, and they are the caller's to
choose: that is the point of the seam -- a padded pitch is a real case and a
unit test can create it."))

(defmethod drm:drm-inventory ((device recording-drm-device))
  (recording-inventory device))

(defmethod drm:drm-claim-dumb ((device recording-drm-device) width height bits-per-pixel)
  (push (list :claim-dumb width height bits-per-pixel) (recording-calls device))
  (values (recording-handle device) (recording-pitch device) (recording-size device)))

(defmethod drm:drm-map-dumb-memory ((device recording-drm-device) handle size)
  (push (list :map-dumb handle size) (recording-calls device))
  (recording-mapping device))

(defmethod drm:drm-unmap-dumb-memory ((device recording-drm-device) buffer)
  (push (list :unmap-dumb (drm:dumb-buffer-mapping buffer)) (recording-calls device)))

(defmethod drm:drm-allocate-framebuffer ((device recording-drm-device) buffer)
  (push (list :add-framebuffer
              (drm:dumb-buffer-width buffer)
              (drm:dumb-buffer-height buffer)
              (drm:dumb-buffer-depth buffer)
              (drm:dumb-buffer-bits-per-pixel buffer)
              (drm:dumb-buffer-pitch buffer)
              (drm:dumb-buffer-handle buffer))
        (recording-calls device))
  (recording-framebuffer device))

(defmethod drm:drm-release-framebuffer ((device recording-drm-device) id)
  (push (list :remove-framebuffer id) (recording-calls device)))

(defmethod drm:drm-release-dumb ((device recording-drm-device) handle)
  (push (list :release-dumb handle) (recording-calls device)))

(defun memory-device (&rest initargs)
  "A recording device: no descriptor, every kernel call recorded."
  (apply #'make-instance 'recording-drm-device :path "memory" :fd nil initargs))

(defun mapped-memory (&key (size 256))
  "A real memfd mapping of SIZE octets: (values MAPPING FD)."
  (let ((fd (ffi:memfd-create "cl-wayland-drm-test")))
    (ffi:set-file-size fd size)
    (values (ffi:map-file fd size
                          :protection (logior ffi:+prot-read+ ffi:+prot-write+))
            fd)))

;;; ---------------------------------------------------------------------------
;;; A mode's refresh is its clock and its totals
;;; ---------------------------------------------------------------------------

(deftest a-modes-refresh-comes-from-its-clock-and-its-totals
  (testing "a 3840x2160 mode at a 594 MHz clock and 4400x2250 totals is 60 Hz"
    (let ((mode (make-mode)))
      (ok (= 60000 (drm:drm-mode-refresh-milli-hz mode))
          "60000 millihertz, not 59 or 61")
      (ok (= 60.0 (drm:drm-mode-refresh mode))
          "and 60.0 Hz for printing")))
  (testing "a 59.94 Hz mode is not a 60 Hz mode"
    (let ((slow (make-mode :clock 593407))
          (fast (make-mode :clock 594000)))
      (ok (= 59940 (drm:drm-mode-refresh-milli-hz slow))
          "the same totals and a slightly lower clock is 59.940 Hz")
      (ok (/= (drm:drm-mode-refresh-milli-hz slow)
              (drm:drm-mode-refresh-milli-hz fast))
          "which is exactly the distinction a float would have lost"))))

(deftest a-mode-with-no-totals-has-no-refresh
  (let ((mode (make-mode :htotal 0 :vtotal 0)))
    (ok (= 0 (drm:drm-mode-refresh-milli-hz mode))
        "no division by zero, and no made-up rate")))

(deftest a-preferred-mode-is-the-one-the-monitor-nominated
  (ok (drm:drm-mode-preferred-p (make-mode :type #x48))
      "#x48 carries DRM_MODE_TYPE_PREFERRED (#x8) with the driver flag")
  (ok (not (drm:drm-mode-preferred-p (make-mode :type #x40)))
      "#x40 is the driver's default mode and not the preferred one"))

(deftest pick-mode-prefers-an-exact-size-then-the-monitors-choice
  (let* ((native (make-mode :name "1920x1080" :clock 148500 :width 1920 :height 1080
                            :htotal 2200 :vtotal 1125 :type #x48))
         (bigger (make-mode :name "3840x2160"))
         (smaller (make-mode :name "1280x720" :clock 74250 :width 1280 :height 720
                             :htotal 1650 :vtotal 750 :type #x40))
         (connector (make-connector :modes (list bigger native smaller))))
    (ok (eq native (drm:drm-pick-mode connector :width 1920 :height 1080))
        "the requested size wins over the larger mode")
    (ok (eq native (drm:drm-pick-mode connector))
        "with no size asked for, the preferred mode wins")
    (let ((no-preference (make-connector :modes (list smaller bigger))))
      (ok (eq bigger (drm:drm-pick-mode no-preference))
          "with nothing preferred, the largest mode wins")
      (let ((same-size-fast (make-mode :name "3840x2160" :clock 594000 :htotal 4000 :vtotal 2200))
            (same-size-slow (make-mode :name "3840x2160" :clock 594000 :htotal 4400 :vtotal 2250)))
        (ok (eq same-size-fast (drm:drm-pick-mode
                                (make-connector :modes (list same-size-fast same-size-slow))))
            "and among equals, the higher refresh")) ))
  (let ((fast (make-mode :name "A" :clock 200000 :width 100 :height 100 :htotal 1000 :vtotal 1000))
        (slow (make-mode :name "B" :clock 100000 :width 100 :height 100 :htotal 1000 :vtotal 1000)))
    (ok (eq fast (drm:drm-pick-mode (make-connector :modes (list slow fast))))
        "same area and no preferred flag: the faster one wins, deterministically")))

(deftest a-connectors-status-is-the-word-sysfs-uses
  (ok (eq :connected (drm:drm-connection-status 1)) "1 is DRM_MODE_CONNECTED")
  (ok (eq :disconnected (drm:drm-connection-status 2)) "2 is DRM_MODE_DISCONNECTED")
  (ok (eq :unknown (drm:drm-connection-status 3)) "3 is DRM_MODE_UNKNOWNCONNECTION")
  (ok (eq :unknown (drm:drm-connection-status 99)) "and anything else is unknown")
  (let ((plugged (make-connector :status :connected))
        (empty (make-connector :name "DP-1" :id 128 :status :disconnected)))
    (ok (drm:drm-connector-connected-p plugged) "a connected connector is connected")
    (ok (not (drm:drm-connector-connected-p empty)) "a disconnected one is not")
    (ok (string= "connected" (drm:drm-connector-status-string plugged))
        "and the word is the one /sys/class/drm/.../status prints")))

(deftest a-connector-is-named-the-way-the-kernel-names-it
  (ok (string= "HDMI-A" (drm:drm-connector-type-name 11)) "type 11 is HDMI-A")
  (ok (string= "DP" (drm:drm-connector-type-name 10)) "type 10 is DP, not DisplayPort")
  (ok (string= "eDP" (drm:drm-connector-type-name 14)) "type 14 is eDP")
  (ok (uiop:string-prefix-p "TYPE-" (drm:drm-connector-type-name 250))
      "a type libdrm has no name for says so instead of guessing"))

(deftest an-inventory-is-found-by-name-and-by-id
  (let* ((hdmi (make-connector :name "HDMI-A-1" :id 138 :status :connected))
         (dp (make-connector :name "DP-1" :id 128 :status :disconnected))
         (inventory (make-inventory :connectors (list hdmi dp))))
    (ok (eq hdmi (drm:drm-inventory-connector inventory "HDMI-A-1"))
        "by the name a person reads")
    (ok (eq dp (drm:drm-inventory-connector inventory 128))
        "by the id the kernel uses")
    (ok (null (drm:drm-inventory-connector inventory "DP-9")) "and nothing for a name it does not have")
    (ok (equal (list hdmi) (drm:drm-inventory-connected-connectors inventory))
        "only the connected connector is listed as present")))

;;; ---------------------------------------------------------------------------
;;; A dumb buffer is its pitch, not its width
;;; ---------------------------------------------------------------------------

(deftest a-dumb-buffers-pixels-are-addressed-through-its-pitch
  (multiple-value-bind (mapping fd) (mapped-memory :size 120)
    (unwind-protect
         (let ((buffer (make-instance 'drm:dumb-buffer
                                      :width 8 :height 3 :bits-per-pixel 32
                                      :handle 1 :pitch 40 :size 120)))
           (ok (= 120 (drm:dumb-buffer-minimum-size buffer))
               "three rows of a 40-byte pitch, not of 8 x 4")
           (setf (drm:dumb-buffer-mapping buffer) mapping)
           ;; Pixel (0,0) is 0x11223344 stored little-endian: 44 33 22 11.
           (loop for index below 4
                 do (setf (cffi:mem-aref mapping :uint8 index)
                          (aref #(#x44 #x33 #x22 #x11) index)))
           ;; Pixel (1,2) starts at 2 x 40 + 4 = 84, and the padding of row 0
           ;; (offsets 32..39) is NOT where row 1 starts.
           (loop for index below 4
                 do (setf (cffi:mem-aref mapping :uint8 (+ 84 index))
                          (aref #(#xAA #xBB #xCC #xDD) index)))
           (setf (cffi:mem-aref mapping :uint8 32) #xEE)
           (ok (= #x11223344 (drm:dumb-buffer-pixel buffer 0 0))
               "the first pixel is the four octets at row 0, column 0")
           (ok (= #xDDCCBBAA (drm:dumb-buffer-pixel buffer 1 2))
               "and (1,2) is at 2 x pitch + 4, not 2 x width x 4")
           (ok (= #xEE (cffi:mem-aref mapping :uint8 32))
               "the padding byte was never treated as a pixel")
           (let ((octets (drm:dumb-buffer-octets buffer)))
             (ok (= 120 (length octets)) "a copy of the pixels is pitch x height octets")
             (ok (= #x44 (aref octets 0)) "starting at the first pixel")
             (ok (= #xEE (aref octets 32)) "padding included, because it is memory")))
      (ffi:unmap-file mapping 120)
      (ffi:close-fd fd))))

(deftest an-unmapped-dumb-buffer-has-no-pointer
  (let ((buffer (make-instance 'drm:dumb-buffer
                               :width 4 :height 2 :bits-per-pixel 32
                               :handle 1 :pitch 16 :size 32)))
    (ok (not (drm:dumb-buffer-mapped-p buffer)) "a fresh buffer is not mapped")
    (ok (not (drm:dumb-buffer-framebuffer-p buffer)) "and has no framebuffer")
    (ok (signals (drm:dumb-buffer-pointer buffer) 'error)
        "asking for its pointer says so instead of handing back NIL")))

;;; ---------------------------------------------------------------------------
;;; The contract: what is asked for, and what is released first
;;; ---------------------------------------------------------------------------

(deftest creating-a-dumb-buffer-asks-for-32-bit-pixels
  (let ((device (memory-device :pitch 64 :size 256)))
    (let ((buffer (drm:drm-create-dumb device 16 4)))
      (ok (equal '((:claim-dumb 16 4 32)) (recording-calls device))
          "one CREATE_DUMB, with the size asked for and 32 bits per pixel")
      (ok (= 64 (drm:dumb-buffer-pitch buffer))
          "the driver's pitch is kept, not recomputed")
      (ok (= 256 (drm:dumb-buffer-size buffer))
          "and so is the driver's size"))))

(deftest a-driver-may-not-answer-a-pitch-narrower-than-the-width
  (let ((device (memory-device :pitch 32 :size 128)))
    (ok (signals (drm:drm-create-dumb device 16 2) 'error)
        "16 pixels need 64 bytes per row; a 32-byte pitch would overlay rows")))

(deftest a-framebuffer-is-added-once-and-named-by-depth-and-pitch
  (multiple-value-bind (mapping fd) (mapped-memory :size 256)
    (unwind-protect
         (let* ((device (memory-device :pitch 64 :size 256 :framebuffer 42
                                       :mapping mapping))
                (buffer (drm:drm-create-dumb device 16 4)))
           (ok (= 42 (drm:drm-add-framebuffer device buffer))
               "ADDFB answers with the id the kernel assigned")
           (ok (equal '(:add-framebuffer 16 4 24 32 64 7)
                      (first (recording-calls device)))
               "and was asked depth 24, bpp 32, the pitch and the handle")
           (ok (= 42 (drm:drm-add-framebuffer device buffer))
               "asking again answers with the same id")
           (ok (= 1 (count :add-framebuffer (recording-calls device)
                           :key (lambda (call) (first call))))
               "and does not allocate a second framebuffer"))
      (ffi:unmap-file mapping 256)
      (ffi:close-fd fd))))

(deftest destroying-a-dumb-buffer-releases-the-framebuffer-first
  (multiple-value-bind (mapping fd) (mapped-memory :size 256)
    (unwind-protect
         (let* ((device (memory-device :pitch 64 :size 256 :framebuffer 42
                                       :mapping mapping))
                (buffer (drm:drm-create-dumb device 16 4)))
           (drm:drm-map-dumb device buffer)
           (drm:drm-add-framebuffer device buffer)
           (setf (recording-calls device) '())
           (drm:drm-destroy-dumb device buffer)
           (ok (equal '((:remove-framebuffer 42) (:unmap-dumb) (:release-dumb 7))
                      (mapcar (lambda (call) (if (eq :unmap-dumb (first call))
                                                 (list :unmap-dumb)
                                                 call))
                              (reverse (recording-calls device))))
               "RMFB, then munmap, then DESTROY_DUMB -- in that order")
           (ok (not (drm:dumb-buffer-framebuffer-p buffer)) "the id is forgotten")
           (ok (not (drm:dumb-buffer-mapped-p buffer)) "the mapping is gone"))
      (ffi:unmap-file mapping 256)
      (ffi:close-fd fd))))

(deftest a-buffer-with-no-framebuffer-sends-no-rmfb
  (let* ((device (memory-device :pitch 64 :size 256))
         (buffer (drm:drm-create-dumb device 16 4)))
    (setf (recording-calls device) '())
    (drm:drm-destroy-dumb device buffer)
    (ok (equal '((:release-dumb 7)) (reverse (recording-calls device)))
        "destroying an unmapped buffer without a framebuffer is one DESTROY_DUMB")))

(deftest a-mapped-buffer-is-unmapped-before-its-memory-is-released
  (multiple-value-bind (mapping fd) (mapped-memory :size 256)
    (unwind-protect
         (let* ((device (memory-device :pitch 64 :size 256 :mapping mapping))
                (buffer (drm:drm-create-dumb device 16 4)))
           (ok (eq buffer (drm:drm-map-dumb device buffer)) "mapping answers with the buffer")
           (ok (drm:dumb-buffer-mapped-p buffer) "and the buffer knows it is mapped")
           (ok (equal (list :map-dumb 7 256) (first (recording-calls device)))
               "MAP_DUMB was asked for the handle and the size the driver gave")
           (ok (eq buffer (drm:drm-unmap-dumb device buffer)) "unmapping answers with the buffer")
           (ok (not (drm:dumb-buffer-mapped-p buffer)) "and the buffer knows it is not"))
      (ffi:unmap-file mapping 256)
      (ffi:close-fd fd))))

(deftest a-closed-device-refuses-to-be-enumerated
  (let ((device (make-instance 'drm:drm-device :path "closed" :fd nil)))
    (ok (not (drm:drm-device-open-p device)) "a device with no descriptor is closed")
    (handler-case
        (progn (drm:drm-inventory device)
               (ok nil "an inventory of a closed device must not answer"))
      (drm:drm-error (condition)
        (ok (eq :device-closed (drm:drm-error-operation condition))
            "the inventory says the device is closed")
        (ok (string= "closed" (drm:drm-error-path condition))
            "and which device")))))

(deftest opening-a-device-that-is-not-there-says-which-errno
  (handler-case
      (progn (drm:open-drm-device "/dev/dri/no-such-card-here")
             (ok nil "opening a missing card must not answer"))
    (drm:drm-error (condition)
      (ok (eq 'open (drm:drm-error-operation condition)) "the operation is open")
      (ok (= ffi:+enoent+ (drm:drm-error-errno condition)) "the errno is ENOENT")
      (ok (string= "/dev/dri/no-such-card-here" (drm:drm-error-path condition))
          "and the path is the one that was asked for"))))

;;; ---------------------------------------------------------------------------
;;; The kernel's view: sysfs
;;; ---------------------------------------------------------------------------

(deftest sysfs-cards-are-only-the-cards
  (with-test-directory (directory)
    (ensure-directories-exist (merge-pathnames "card0/" directory))
    (ensure-directories-exist (merge-pathnames "card1/" directory))
    (ensure-directories-exist (merge-pathnames "card1-HDMI-A-1/" directory))
    (ensure-directories-exist (merge-pathnames "renderD128/" directory))
    (ensure-directories-exist (merge-pathnames "version/" directory))
    (ok (equal '("card0" "card1") (drm:drm-sysfs-cards :root (namestring directory)))
        "connector directories, render nodes and the version file are not cards")))

(deftest sysfs-state-reads-what-the-files-say
  (with-test-directory (directory)
    (let ((hdmi (merge-pathnames "card1-HDMI-A-1/" directory))
          (dp (merge-pathnames "card1-DP-1/" directory)))
      (write-file (merge-pathnames "status" hdmi) (format nil "connected~%"))
      (write-file (merge-pathnames "enabled" hdmi) (format nil "enabled~%"))
      (write-file (merge-pathnames "dpms" hdmi) (format nil "On~%"))
      (write-file (merge-pathnames "modes" hdmi) (format nil "3840x2160~%1920x1080~%"))
      (write-file (merge-pathnames "status" dp) (format nil "disconnected~%"))
      (write-file (merge-pathnames "enabled" dp) (format nil "disabled~%")))
    (let ((state (drm:drm-sysfs-state "card1" :root (namestring directory))))
      (ok (= 2 (length state)) "two connectors, and only card1's")
      (let ((hdmi (find "HDMI-A-1" state :key (lambda (entry) (getf entry :name)) :test #'string=)))
        (ok (string= "connected" (getf hdmi :status)) "the status file")
        (ok (string= "enabled" (getf hdmi :enabled)) "the enabled file")
        (ok (string= "On" (getf hdmi :dpms)) "the dpms file")
        (ok (equal '("3840x2160" "1920x1080") (getf hdmi :modes))
            "the modes file, one mode per line"))
      (let ((dp (find "DP-1" state :key (lambda (entry) (getf entry :name)) :test #'string=)))
        (ok (string= "disconnected" (getf dp :status)) "and the unplugged one says so")
        (ok (null (getf dp :modes)) "with no modes, as an empty file has")))))

(deftest sysfs-state-of-a-card-that-is-not-there-is-empty
  (ok (null (drm:drm-sysfs-state "card99" :root "/sys/class/drm"))
      "no card, no connectors, no error"))

(deftest sysfs-driver-name-comes-from-the-uevent
  (with-test-directory (directory)
    (write-file (merge-pathnames "card1/device/uevent" directory)
                (format nil "DRIVER=amdgpu~%PCI_CLASS=30000~%"))
    (ok (string= "amdgpu" (drm:drm-sysfs-driver-name "card1" :root (namestring directory)))
        "the DRIVER= line, without the key")
    (ok (null (drm:drm-sysfs-driver-name "card2" :root (namestring directory)))
        "a card with no uevent answers NIL instead of guessing")))

(deftest device-paths-lists-only-card-nodes
  (with-test-directory (directory)
    (dolist (name '("card0" "card1" "controlD64" "renderD128" "by-path"))
      (write-file (merge-pathnames name directory) ""))
    (let ((paths (drm:drm-device-paths :directory (namestring directory))))
      (ok (= 2 (length paths)) "two cards and nothing else")
      (ok (uiop:string-suffix-p (first paths) "/card0") "sorted, card0 first")
      (ok (uiop:string-suffix-p (second paths) "/card1") "then card1"))))
