;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The screen half of the DRM backend: taking master, programming a CRTC,
;;;; flipping between two frames, and giving the card back (D55).
;;;;
;;;; No card is opened here, and that is the point: the kernel calls are generic
;;;; functions, so a recording device answers them and these tests assert the
;;;; arguments and the order a real card would have been given.  What only a card
;;;; can answer -- whether SETCRTC and PAGE_FLIP are allowed, what a real flip
;;;; event's sequence numbers do -- is scripts/drm-modeset-gate.lisp's business,
;;;; and that runs against a virtual card.
;;;;
;;;; Three levels again, because three things go wrong independently:
;;;;
;;;;   * the two directions of a mode: what READ-MODE read, WRITE-MODE-INFO has
;;;;     to write back, field for field, into the ABI struct SETCRTC takes;
;;;;   * the event stream: several completions in one read, a record cut in half,
;;;;     an unknown kind -- a parser that loops or drops is a flip that hangs;
;;;;   * the order: master, saved state, buffers, SETCRTC; and on the way out,
;;;;     restore, destroy, drop master, because RMFB on a scanned-out framebuffer
;;;;     is EBUSY and a dropped master with a mode set is a screen nobody owns.

(in-package #:cl-user)

(defpackage #:wayland.test.drm-modeset
  (:use #:cl #:rove)
  (:local-nicknames (#:drm #:cf.backend.drm)
                    (#:ffi #:wayland.ffi))
  (:documentation "Tests for the DRM screen path: modes written back, events
parsed, and a scanout's order (D55)."))

(in-package #:wayland.test.drm-modeset)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defun make-mode (&key (name "1024x768") (clock 65000) (width 1024) (height 768)
                        (htotal 1344) (vtotal 806) (vrefresh 60) (flags 0)
                        (type 8))
  (drm::%make-drm-mode :name name :clock clock
                       :hdisplay width :hsync-start (+ width 24)
                       :hsync-end (+ width 136) :htotal htotal :hskew 0
                       :vdisplay height :vsync-start (+ height 3)
                       :vsync-end (+ height 6) :vtotal vtotal :vscan 0
                       :vrefresh vrefresh :flags flags :type type))

(defun make-connector (&key (name "Virtual-1") (id 7) (status :connected)
                            modes (encoders '(5)) (encoder-id 5))
  "A connector attached to ENCODER-ID by default: a connector with no encoder is
not lit on any CRTC, and restoring a CRTC's mode needs the connector that was
lighting it."
  (drm::%make-drm-connector :id id :name name :type 0 :type-id 1
                            :status status :mm-width 0 :mm-height 0
                            :encoder-id encoder-id :modes modes :encoders encoders))

(defun make-crtc (&key (id 33) (buffer-id 0) mode)
  (drm::%make-drm-crtc :id id :buffer-id buffer-id :x 0 :y 0
                       :width (if mode (drm:drm-mode-hdisplay mode) 0)
                       :height (if mode (drm:drm-mode-vdisplay mode) 0)
                       :mode-valid-p (not (null mode))
                       :mode mode))

(defun make-encoder (&key (id 5) (crtc-id 33) (possible-crtcs 1))
  (drm::%make-drm-encoder :id id :type 0 :crtc-id crtc-id
                          :possible-crtcs possible-crtcs :possible-clones 0))

(defun make-inventory (&key connector crtcs encoder)
  (drm::%make-drm-inventory
   :driver-name "vkms" :driver-version "1.0.0"
   :connectors (list (or connector (make-connector :modes (list (make-mode)))))
   :crtcs (or crtcs (list (make-crtc)))
   :encoders (list (or encoder (make-encoder)))))

(defun flip-event (&key (crtc-id 33) (sequence 10) (user-data 1))
  (list :type :flip-complete :length 32 :user-data user-data
        :tv-sec 5 :tv-usec 250000 :sequence sequence :crtc-id crtc-id))

(defun vblank-event (&key (crtc-id 33) (sequence 9))
  (list :type :vblank :length 32 :user-data 0
        :tv-sec 5 :tv-usec 240000 :sequence sequence :crtc-id crtc-id))

;;; ---------------------------------------------------------------------------
;;; A device that records the screen calls instead of making them
;;; ---------------------------------------------------------------------------

(defclass recording-screen-device (drm:drm-device)
  ((calls :initform '() :accessor recording-calls)
   (inventory :initarg :inventory :initform nil :accessor recording-inventory)
   (master :initform nil :accessor recording-master)
   (master-error :initarg :master-error :initform nil :accessor recording-master-error)
   (events :initarg :events :initform '() :accessor recording-events)
   (flip-error :initarg :flip-error :initform nil :accessor recording-flip-error)
   (fail-add-on :initarg :fail-add-on :initform nil :accessor recording-fail-add-on)
   (add-count :initform 0 :accessor recording-add-count)
   (framebuffer :initform 0 :accessor recording-framebuffer)
   (handle :initform 0 :accessor recording-handle))
  (:documentation
   "A DRM-DEVICE whose kernel calls are recorded.

MASTER-ERROR makes taking master fail the way a card somebody is presenting on
fails: EBUSY.  EVENTS are what the next read answers.  FAIL-ADD-ON makes the Nth
ADDFB fail, which is how a half-built scanout is exercised."))

(defun new-screen-device (&rest initargs)
  "A recording device with a fake descriptor, so DRM-DEVICE-OPEN-P is true.

The descriptor number is never used: every method that would touch it is one of
the recorded ones."
  (apply #'make-instance 'recording-screen-device
         :fd 5 :path "fake" :driver-name "vkms"
         (if (getf initargs :inventory)
             initargs
             (append initargs (list :inventory (make-inventory))))))

(defun recorded (device)
  "The calls DEVICE recorded, oldest first."
  (reverse (recording-calls device)))

(defmethod drm:drm-query-master ((device recording-screen-device))
  (recording-master device))

(defmethod drm:drm-request-master ((device recording-screen-device))
  (push :take-master (recording-calls device))
  (when (recording-master-error device)
    (error 'drm:drm-error :operation :take-master
                          :errno ffi:+ebusy+ :path (drm:drm-device-path device)))
  (setf (recording-master device) t)
  (values))

(defmethod drm:drm-release-master ((device recording-screen-device))
  (push :drop-master (recording-calls device))
  (setf (recording-master device) nil)
  (values))

(defmethod drm:drm-inventory ((device recording-screen-device))
  (recording-inventory device))

(defmethod drm:drm-program-crtc ((device recording-screen-device)
                                 crtc-id framebuffer-id x y connector-ids mode)
  (push (list :set-crtc crtc-id framebuffer-id x y
              (copy-list connector-ids)
              (and mode (drm:drm-mode-name mode)))
        (recording-calls device))
  (values))

(defmethod drm:drm-queue-page-flip ((device recording-screen-device)
                                    crtc-id framebuffer-id user-data)
  (push (list :flip crtc-id framebuffer-id user-data) (recording-calls device))
  (when (recording-flip-error device)
    (error 'drm:drm-error :operation :queue-page-flip
                          :errno 22 :path (drm:drm-device-path device)))
  (values))

(defmethod drm:drm-read-events ((device recording-screen-device) &key timeout-ms)
  (declare (ignore timeout-ms))
  (push :read-events (recording-calls device))
  (let ((events (recording-events device)))
    (setf (recording-events device) '())
    events))

(defmethod drm:drm-claim-dumb ((device recording-screen-device) width height bits-per-pixel)
  (push (list :create-dumb width height bits-per-pixel) (recording-calls device))
  (let ((pitch (* width 4)))
    (values (incf (recording-handle device)) pitch (* pitch height))))

(defmethod drm:drm-map-dumb-memory ((device recording-screen-device) handle size)
  (push (list :map-dumb handle size) (recording-calls device))
  :fake-mapping)

(defmethod drm:drm-unmap-dumb-memory ((device recording-screen-device) buffer)
  (push (list :unmap-dumb (drm:dumb-buffer-handle buffer)) (recording-calls device))
  (values))

(defmethod drm:drm-allocate-framebuffer ((device recording-screen-device) buffer)
  (incf (recording-add-count device))
  (push (list :add-framebuffer (drm:dumb-buffer-width buffer)
              (drm:dumb-buffer-height buffer) (drm:dumb-buffer-handle buffer))
        (recording-calls device))
  (when (and (recording-fail-add-on device)
             (= (recording-fail-add-on device) (recording-add-count device)))
    (error 'drm:drm-error :operation :add-framebuffer :errno 12
                          :path (drm:drm-device-path device)))
  (incf (recording-framebuffer device)))

(defmethod drm:drm-release-framebuffer ((device recording-screen-device) id)
  (push (list :remove-framebuffer id) (recording-calls device))
  (values))

(defmethod drm:drm-release-dumb ((device recording-screen-device) handle)
  (push (list :destroy-dumb handle) (recording-calls device))
  (values))

(defun find-call (device kind)
  "The first recorded call of KIND, or NIL; the chronological order, not the stack."
  (find-if (lambda (call) (and (consp call) (eq kind (first call)))) (recorded device)))

(defun find-calls (device kind)
  "Every recorded call of KIND, oldest first."
  (remove-if-not (lambda (call) (and (consp call) (eq kind (first call)))) (recorded device)))

(defun call-kinds (device)
  "Just the head of each recorded call, oldest first: the shape of the order."
  (mapcar (lambda (call) (if (consp call) (first call) call))
          (recorded device)))

;;; ---------------------------------------------------------------------------
;;; A mode written back
;;; ---------------------------------------------------------------------------

(deftest a-mode-written-and-read-back-is-the-same-mode
  ;; SETCRTC takes a timing, not a name: every field has to survive the C round
  ;; trip, or the kernel is asked to program something we did not choose.
  (let ((mode (make-mode :name "1920x1080" :clock 148500 :width 1920 :height 1080
                         :htotal 2200 :vtotal 1125 :vrefresh 60
                         :flags #x5 :type #x9)))
    (cffi:with-foreign-object (info '(:struct drm:drm-mode-info))
      (drm:write-mode-info mode info)
      (let ((back (drm:read-mode-info info)))
        (ok (= (drm:drm-mode-clock mode) (drm:drm-mode-clock back)))
        (ok (= (drm:drm-mode-hdisplay mode) (drm:drm-mode-hdisplay back)))
        (ok (= (drm:drm-mode-hsync-start mode) (drm:drm-mode-hsync-start back)))
        (ok (= (drm:drm-mode-hsync-end mode) (drm:drm-mode-hsync-end back)))
        (ok (= (drm:drm-mode-htotal mode) (drm:drm-mode-htotal back)))
        (ok (= (drm:drm-mode-vdisplay mode) (drm:drm-mode-vdisplay back)))
        (ok (= (drm:drm-mode-vsync-start mode) (drm:drm-mode-vsync-start back)))
        (ok (= (drm:drm-mode-vsync-end mode) (drm:drm-mode-vsync-end back)))
        (ok (= (drm:drm-mode-vtotal mode) (drm:drm-mode-vtotal back)))
        (ok (= (drm:drm-mode-vrefresh mode) (drm:drm-mode-vrefresh back)))
        (ok (= (drm:drm-mode-flags mode) (drm:drm-mode-flags back)))
        (ok (= (drm:drm-mode-type mode) (drm:drm-mode-type back)))
        (ok (string= (drm:drm-mode-name mode) (drm:drm-mode-name back)))
        (ok (string= "1920x1080" (drm:drm-mode-name back)))))))

(deftest a-name-too-long-for-the-struct-is-cut-at-thirty-one-characters
  ;; drmModeModeInfo.name is 32 bytes with the terminating NUL: a 40-character
  ;; name has to arrive as 31 characters, not as a mode with no NUL in it.
  (let ((mode (make-mode :name (make-string 40 :initial-element #\x))))
    (cffi:with-foreign-object (info '(:struct drm:drm-mode-info))
      (drm:write-mode-info mode info)
      (ok (= 31 (length (drm:drm-mode-name (drm:read-mode-info info))))))))

(deftest writing-a-mode-needs-a-pointer
  (let ((mode (make-mode)))
    (ok (signals (drm:write-mode-info mode 42) 'error))))

;;; ---------------------------------------------------------------------------
;;; The event stream
;;; ---------------------------------------------------------------------------

(defun put-event (octets offset type length &key (signature 1) (sequence 7) (crtc-id 33))
  "Write one drm_event record at OFFSET in OCTETS.  A length of 8 writes only the
header, which is how an unknown event looks."
  (labels ((put32 (at value) (setf (aref octets at) (logand value #xFF)
                                (aref octets (+ at 1)) (logand (ash value -8) #xFF)
                                (aref octets (+ at 2)) (logand (ash value -16) #xFF)
                                (aref octets (+ at 3)) (logand (ash value -24) #xFF)))
         (put64 (at value)
           (put32 at (logand value #xFFFFFFFF))
           (put32 (+ at 4) (ash value -32))))
    (put32 offset type)
    (put32 (+ offset 4) length)
    (when (>= length 32)
      (put64 (+ offset 8) signature)
      (put32 (+ offset 16) 5)
      (put32 (+ offset 20) 123456)
      (put32 (+ offset 24) sequence)
      (put32 (+ offset 28) crtc-id)))
  octets)

(deftest a-flip-completion-is-parsed-as-a-flip-completion
  (let ((octets (put-event (make-array 32 :element-type '(unsigned-byte 8)) 0
                           2 32 :signature 99 :sequence 41 :crtc-id 33)))
    (multiple-value-bind (events consumed) (drm:parse-drm-events octets)
      (ok (= 32 consumed))
      (ok (= 1 (length events)))
      (let ((event (first events)))
        (ok (eq :flip-complete (getf event :type)))
        (ok (= 41 (getf event :sequence)))
        (ok (= 33 (getf event :crtc-id)))
        (ok (= 99 (getf event :user-data)))))))

(deftest a-vblank-is-parsed-and-told-apart-from-a-flip
  (let ((octets (put-event (make-array 32 :element-type '(unsigned-byte 8)) 0 1 32)))
    (let ((events (drm:parse-drm-events octets)))
      (ok (eq :vblank (getf (first events) :type))))))

(deftest two-events-in-one-read-both-come-out-in-order
  (let ((octets (make-array 64 :element-type '(unsigned-byte 8))))
    (put-event octets 0 2 32 :sequence 1)
    (put-event octets 32 2 32 :sequence 2)
    (multiple-value-bind (events consumed) (drm:parse-drm-events octets)
      (ok (= 64 consumed))
      (ok (equal '(1 2) (mapcar (lambda (event) (getf event :sequence)) events))))))

(deftest a-record-cut-in-half-is-left-for-the-next-read
  ;; The kernel writes whole records, but a length field is data: if a record does
  ;; not fit, the parse must stop at the last whole one and say how much it used.
  (let ((octets (make-array 64 :element-type '(unsigned-byte 8))))
    (put-event octets 0 2 32 :sequence 3)
    (put-event octets 32 2 32 :sequence 4)
    (multiple-value-bind (events consumed)
        (drm:parse-drm-events octets :end 40)
      (ok (= 32 consumed))
      (ok (equal '(3) (mapcar (lambda (event) (getf event :sequence)) events))))))

(deftest an-unknown-event-is-reported-with-its-code
  (let ((octets (put-event (make-array 32 :element-type '(unsigned-byte 8)) 0 #x77 8)))
    (let ((event (first (drm:parse-drm-events octets))))
      (ok (eq :other (getf event :type)))
      (ok (= #x77 (getf event :code)))
      (ok (= 8 (getf event :length))))))

(deftest a-record-too-short-to-hold-its-own-header-stops-the-parse
  ;; Without this rule a corrupt length is an infinite loop: the parse must give up
  ;; rather than trust the field it just read.
  (let ((octets (put-event (make-array 32 :element-type '(unsigned-byte 8)) 0 2 4)))
    (multiple-value-bind (events consumed) (drm:parse-drm-events octets)
      (ok (null events))
      (ok (zerop consumed)))))

(deftest a-length-that-runs-past-the-buffer-stops-the-parse
  (let ((octets (put-event (make-array 32 :element-type '(unsigned-byte 8)) 0 2 64)))
    (multiple-value-bind (events consumed) (drm:parse-drm-events octets)
      (ok (null events))
      (ok (zerop consumed)))))

(deftest event-types-are-translated-in-one-place
  (ok (eq :vblank (drm:drm-event-type 1)))
  (ok (eq :flip-complete (drm:drm-event-type 2)))
  (ok (eq :other (drm:drm-event-type 99))))

(deftest only-vkms-is-a-virtual-card
  (ok (drm:drm-virtual-driver-p "vkms"))
  (ok (drm:drm-virtual-driver-p "VKMS"))
  (ok (not (drm:drm-virtual-driver-p "amdgpu")))
  (ok (not (drm:drm-virtual-driver-p nil))))

;;; ---------------------------------------------------------------------------
;;; Choosing a CRTC
;;; ---------------------------------------------------------------------------

(deftest a-connector-can-drive-the-crtcs-its-encoders-allow
  (let* ((inventory (make-inventory :crtcs (list (make-crtc :id 33) (make-crtc :id 40))
                                    :encoder (make-encoder :possible-crtcs #b10)))
         (connector (first (drm:drm-inventory-connectors inventory))))
    (ok (equal '(40) (drm:drm-connector-crtcs inventory connector)))))

(deftest an-idle-crtc-is-preferred-to-one-that-is-scanning
  ;; Taking a CRTC that already has a framebuffer is taking somebody's picture away.
  (let* ((inventory (make-inventory :crtcs (list (make-crtc :id 33 :buffer-id 44)
                                                  (make-crtc :id 40))
                                    :encoder (make-encoder :possible-crtcs #b11)))
         (connector (first (drm:drm-inventory-connectors inventory))))
    (ok (= 40 (drm:drm-scanout-crtc inventory connector)))))

(deftest a-crtc-that-cannot-drive-the-connector-is-refused
  (let* ((inventory (make-inventory :crtcs (list (make-crtc :id 33))
                                    :encoder (make-encoder :possible-crtcs 0)))
         (connector (first (drm:drm-inventory-connectors inventory))))
    (ok (signals (drm:drm-scanout-crtc inventory connector :crtc-id 99) 'error))))

;;; ---------------------------------------------------------------------------
;;; Opening a scanout: what is asked for, and in what order
;;; ---------------------------------------------------------------------------

(deftest opening-a-scanout-takes-master-first-and-gives-it-back-last
  (let* ((device (new-screen-device))
         (scanout (drm:drm-open-scanout device)))
    (unwind-protect
         (let ((kinds (call-kinds device)))
           (ok (eq :take-master (first kinds)))
           (ok (eq :set-crtc (eighth kinds)))
           (ok (= 2 (count :create-dumb kinds)))
           (ok (= 2 (count :map-dumb kinds)))
           (ok (= 2 (count :add-framebuffer kinds)))
           (ok (drm:drm-scanout-master-p scanout))
           (ok (= 33 (drm:drm-scanout-crtc-id scanout)))
           (ok (string= "Virtual-1" (drm:drm-connector-name
                                     (drm:drm-scanout-connector scanout)))))
      (drm:drm-close-scanout scanout))
    (let ((kinds (call-kinds device)))
      (ok (eq :drop-master (car (last kinds))))
      (ok (= 2 (count :set-crtc kinds)))
      (ok (not (drm:drm-device-master-p device))))))

(deftest a-scanout-programs-the-crtc-with-its-first-buffer-and-connector
  (let* ((device (new-screen-device))
         (scanout (drm:drm-open-scanout device)))
    (unwind-protect
         (let ((call (find-call device :set-crtc)))
           (ok (= 33 (second call)))
           (ok (= 1 (third call)))       ; the first framebuffer id the fake handed out
           (ok (equal '(7) (sixth call))) ; the connector's kernel id
           (ok (string= "1024x768" (seventh call))))
      (drm:drm-close-scanout scanout))))

(deftest a-scanout-remembers-what-the-crtc-was-doing-before
  ;; The state to restore is read before SETCRTC and lives on the scanout: this is
  ;; the whole reason a later close can put the screen back.
  (let* ((old-mode (make-mode :name "640x480" :width 640 :height 480
                              :htotal 800 :vtotal 525))
         (inventory (make-inventory :crtcs (list (make-crtc :id 33 :buffer-id 99
                                                            :mode old-mode))))
         (device (new-screen-device :inventory inventory))
         (scanout (drm:drm-open-scanout device)))
    (unwind-protect
         (let ((saved (drm:drm-scanout-saved-state scanout)))
           (ok (= 99 (drm:drm-crtc-buffer-id saved)))
           (ok (string= "640x480" (drm:drm-mode-name (drm:drm-crtc-mode saved)))))
      (drm:drm-close-scanout scanout))
    ;; And closing writes that state back, with no connectors: the kernel's way of
    ;; saying "this CRTC keeps doing what it was doing".
    (let ((restore (car (last (find-calls device :set-crtc)))))
      (ok (= 99 (third restore)))
      (ok (equal '(7) (sixth restore)))
      (ok (string= "640x480" (seventh restore))))))

(deftest a-scanout-records-which-connectors-the-crtc-was-feeding
  ;; What has to be put back is not only the framebuffer and the mode: SETCRTC with
  ;; a mode and no connectors is EINVAL, so the connectors are part of the state.
  (let* ((inventory (make-inventory :crtcs (list (make-crtc :id 33 :buffer-id 99
                                                            :mode (make-mode)))))
         (device (new-screen-device :inventory inventory))
         (scanout (drm:drm-open-scanout device)))
    (unwind-protect
         (ok (equal '(7) (drm:drm-scanout-saved-connectors scanout)))
      (drm:drm-close-scanout scanout))))

(deftest a-crtc-that-was-off-is-restored-by-switching-it-off
  ;; No framebuffer, no connectors, no mode: the only legal way to say "off".
  (let* ((device (new-screen-device))
         (scanout (drm:drm-open-scanout device)))
    (drm:drm-close-scanout scanout)
    (let ((restore (car (last (find-calls device :set-crtc)))))
      (ok (= 0 (third restore)) "the restore names no framebuffer")
      (ok (equal '() (sixth restore)) "and no connectors")
      (ok (null (seventh restore)) "and no mode"))))

(deftest an-inconsistent-saved-state-is-restored-as-off
  ;; A mode with no framebuffer is a state the kernel will not accept back, so the
  ;; nearest legal state is used rather than an EINVAL that leaves a CRTC half set.
  (let* ((mode (make-mode :name "swallowed" :width 640 :height 480))
         (inventory (make-inventory :crtcs (list (make-crtc :id 33 :buffer-id 0
                                                            :mode mode))))
         (device (new-screen-device :inventory inventory))
         (state (drm:drm-crtc-state device 33))
         (saved (recorded device)))
    (declare (ignore saved))
    (drm:drm-restore-crtc device state :connector-ids '(7))
    (let ((call (first (find-calls device :set-crtc))))
      (ok (= 0 (third call)))
      (ok (null (seventh call))))))

(deftest restoring-a-lit-crtc-names-its-connectors-and-its-mode
  (let* ((mode (make-mode :name "800x600" :width 800 :height 600))
         (inventory (make-inventory :crtcs (list (make-crtc :id 33 :buffer-id 77
                                                            :mode mode))))
         (device (new-screen-device :inventory inventory)))
    (drm:drm-restore-crtc device (drm:drm-crtc-state device 33)
                          :connector-ids (drm:drm-crtc-connectors inventory 33))
    (let ((call (first (find-calls device :set-crtc))))
      (ok (= 77 (third call)))
      (ok (equal '(7) (sixth call)))
      (ok (string= "800x600" (seventh call))))))

(deftest only-connectors-lit-through-a-crtc-belong-to-it
  (let ((inventory (make-inventory
                    :crtcs (list (make-crtc :id 33) (make-crtc :id 40))
                    :encoder (make-encoder :id 5 :crtc-id 40))))
    (ok (equal '() (drm:drm-crtc-connectors inventory 33)))
    (ok (equal '(7) (drm:drm-crtc-connectors inventory 40)))))

(deftest a-scanout-can-be-opened-with-a-connector-name-and-a-mode
  (let* ((device (new-screen-device))
         (mode (make-mode :name "800x600" :width 800 :height 600
                          :htotal 1056 :vtotal 628))
         (scanout (drm:drm-open-scanout device :connector "Virtual-1" :mode mode)))
    (unwind-protect
         (progn
           (ok (string= "800x600" (drm:drm-mode-name (drm:drm-scanout-mode scanout))))
           (ok (= 800 (drm:drm-scanout-width scanout)))
           (ok (= 600 (drm:drm-scanout-height scanout))))
      (drm:drm-close-scanout scanout))))

(deftest opening-a-scanout-on-an-unknown-connector-fails-before-taking-master
  (let ((device (new-screen-device)))
    (ok (signals (drm:drm-open-scanout device :connector "HDMI-A-9") 'error))
    (ok (null (recorded device)))))

(deftest a-scanout-wants-one-to-four-buffers
  (let ((device (new-screen-device)))
    (ok (signals (drm:drm-open-scanout device :buffer-count 0) 'error))
    (ok (signals (drm:drm-open-scanout device :buffer-count 5) 'error))
    (ok (null (recorded device)))))

;;; ---------------------------------------------------------------------------
;;; Presenting
;;; ---------------------------------------------------------------------------

(deftest presenting-a-buffer-flips-to-it-and-waits-for-the-completion
  (let* ((device (new-screen-device :events (list (flip-event :sequence 12))))
         (scanout (drm:drm-open-scanout device)))
    (unwind-protect
         (let ((event (drm:drm-scanout-present scanout (drm:drm-scanout-buffer scanout 1))))
           (ok (= 12 (getf event :sequence)))
           (ok (= 1 (drm:drm-scanout-frames scanout)))
           (ok (= 1 (drm:drm-scanout-front scanout)))
           ;; The flip names the second framebuffer, the one we presented.
           (ok (= 2 (third (find-call device :flip)))))
      (drm:drm-close-scanout scanout))))

(deftest the-next-buffer-alternates-as-frames-complete
  (let* ((device (new-screen-device :events (list (flip-event)
                                                 (flip-event :sequence 11)
                                                 (flip-event :sequence 12))))
         (scanout (drm:drm-open-scanout device)))
    (unwind-protect
         (progn
           (ok (= 0 (drm:drm-scanout-front scanout)))
           (ok (eq (drm:drm-scanout-buffer scanout 0)
                   (drm:drm-scanout-next-buffer scanout)))
           (drm:drm-scanout-present-next scanout)
           (ok (= 1 (drm:drm-scanout-frames scanout)))
           (ok (eq (drm:drm-scanout-buffer scanout 1)
                   (drm:drm-scanout-next-buffer scanout))))
      (drm:drm-close-scanout scanout))))

(deftest a-flip-for-another-crtc-is-not-mistaken-for-ours
  (let* ((device (new-screen-device
                  :events (list (flip-event :crtc-id 999 :sequence 1)
                                (vblank-event :crtc-id 33 :sequence 2)
                                (flip-event :crtc-id 33 :sequence 3))))
         (scanout (drm:drm-open-scanout device)))
    (unwind-protect
         (ok (= 3 (getf (drm:drm-scanout-present scanout
                                                (drm:drm-scanout-buffer scanout 1))
                        :sequence)))
      (drm:drm-close-scanout scanout))))

(deftest a-flip-that-is-never-retired-times-out
  ;; No events at all: this has to be a DRM-ERROR about time, not a hang and not a
  ;; flip into a buffer the display might still be reading.
  (let* ((device (new-screen-device :events '()))
         (scanout (drm:drm-open-scanout device)))
    (unwind-protect
         (let ((condition (handler-case
                              (drm:drm-scanout-present scanout
                                                       (drm:drm-scanout-buffer scanout 1)
                                                       :timeout-ms 0)
                            (drm:drm-error (condition) condition))))
           (ok (typep condition 'drm:drm-error))
           (ok (eq :await-flip (drm:drm-error-operation condition)))
           (ok (null (drm:drm-error-errno condition)))
           (ok (zerop (drm:drm-scanout-frames scanout))))
      (drm:drm-close-scanout scanout))))

(deftest each-flip-carries-a-new-user-data
  ;; The event the kernel sends back carries what PAGE_FLIP was given, so a stale
  ;; completion can be told from the one that belongs to the newest flip.
  (let* ((device (new-screen-device :events (list (flip-event)
                                                 (flip-event :sequence 11))))
         (scanout (drm:drm-open-scanout device)))
    (unwind-protect
         (progn
           (drm:drm-scanout-present scanout (drm:drm-scanout-buffer scanout 1))
           (drm:drm-scanout-present scanout (drm:drm-scanout-buffer scanout 0))
           (let ((user-data (mapcar #'fourth (find-calls device :flip))))
             (ok (= 2 (length user-data)))
             (ok (< (first user-data) (second user-data)))
             (ok (= 1 (first user-data)))))
      (drm:drm-close-scanout scanout))))

(deftest presenting-a-closed-scanout-is-an-error
  (let* ((device (new-screen-device))
         (scanout (drm:drm-open-scanout device)))
    (drm:drm-close-scanout scanout)
    (ok (signals (drm:drm-scanout-present scanout
                                          (drm:drm-scanout-buffer scanout 0))
                 'error))))

;;; ---------------------------------------------------------------------------
;;; Giving the screen back
;;; ---------------------------------------------------------------------------

(deftest closing-restores-then-releases-then-drops-master
  ;; The order is the contract: RMFB on a framebuffer a CRTC is scanning is EBUSY,
  ;; and a card left taken with a mode set is a screen nobody owns.
  (let* ((device (new-screen-device))
         (scanout (drm:drm-open-scanout device)))
    (drm:drm-close-scanout scanout)
    (let ((calls (recorded device)))
      (ok (= 2 (length (find-calls device :set-crtc))))     ; programmed, restored
      (ok (= 2 (length (find-calls device :remove-framebuffer))))
      (ok (= 2 (length (find-calls device :unmap-dumb))))
      (ok (= 2 (length (find-calls device :destroy-dumb))))
      (ok (equal (mapcar (lambda (call) (if (consp call) (first call) call))
                         (last calls 8))
                 '(:set-crtc :remove-framebuffer :unmap-dumb :destroy-dumb
                   :remove-framebuffer :unmap-dumb :destroy-dumb :drop-master))))))

(deftest closing-twice-does-nothing-the-second-time
  (let* ((device (new-screen-device))
         (scanout (drm:drm-open-scanout device)))
    (drm:drm-close-scanout scanout)
    (let ((count (length (recorded device))))
      (drm:drm-close-scanout scanout)
      (ok (= count (length (recorded device))))
      (ok (not (drm:drm-scanout-open-p scanout))))))

(deftest a-card-somebody-is-presenting-on-refuses-to-be-taken
  ;; EBUSY is the kernel's answer when another master owns the card; the scanout
  ;; must not have created, mapped or framed a single buffer when it happens.
  (let ((device (new-screen-device :master-error t)))
    (let ((condition (handler-case (drm:drm-open-scanout device)
                       (drm:drm-error (condition) condition))))
      (ok (typep condition 'drm:drm-error))
      (ok (eq :take-master (drm:drm-error-operation condition)))
      (ok (= ffi:+ebusy+ (drm:drm-error-errno condition)))
      (ok (equal '(:take-master) (call-kinds device)))
      (ok (not (drm:drm-device-master-p device))))))

(deftest a-scanout-that-fails-half-built-undoes-what-it-did
  ;; The second ADDFB fails: the first buffer must be destroyed, the CRTC put back,
  ;; and the card given up -- in that order, none of them skipped.
  (let ((device (new-screen-device :fail-add-on 2)))
    (ok (signals (drm:drm-open-scanout device) 'drm:drm-error))
    (let ((kinds (call-kinds device)))
      (ok (eq :take-master (first kinds)))
      (ok (= 2 (count :destroy-dumb kinds)))
      (ok (eq :set-crtc (car (last kinds 2))))
      (ok (eq :drop-master (car (last kinds))))
      (ok (not (drm:drm-device-master-p device))))))

(deftest dropping-master-when-not-master-does-not-call-the-kernel
  (let ((device (new-screen-device)))
    (drm:drm-drop-master device)
    (ok (null (recorded device)))
    (ok (not (drm:drm-device-master-p device)))))

(deftest a-closed-device-is-not-master
  (let ((device (new-screen-device)))
    (drm:drm-refresh-master device)
    (ok (not (drm:drm-device-master-p device)))))
