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
                    (#:session #:cf.session)
                    (#:vt #:cf.backend.vt)
                    (#:headless #:cf.backend.headless)
                    (#:render #:cf.render.pixman)
                    (#:srv #:wayland.server)
                    (#:ffi #:wayland.ffi))
  (:documentation "Tests for the DRM screen path: modes written back, events
parsed, a scanout's order (D55), and the screen a seat hands out (4d-3)."))

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
   (program-error :initarg :program-error :initform nil :accessor recording-program-error)
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
  (when (recording-program-error device)
    (error 'drm:drm-error :operation :program-crtc :errno ffi:+eacces+
                          :path (drm:drm-device-path device)))
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
           ;; OPEN-SCANOUT programmed the CRTC with buffer 0, so buffer 0 is on the
           ;; screen and the first frame belongs in buffer 1.  This test used to
           ;; assert the opposite -- that the first frame went into the buffer the
           ;; display was reading -- which is the tear D64's walk found on the VT.
           (ok (= 0 (drm:drm-scanout-front scanout)))
           (ok (eq (drm:drm-scanout-buffer scanout 1)
                   (drm:drm-scanout-next-buffer scanout)))
           (drm:drm-scanout-present-next scanout)
           (ok (= 1 (drm:drm-scanout-frames scanout)))
           (ok (= 1 (drm:drm-scanout-front scanout))
               "the buffer that was drawn is the one presented")
           (ok (eq (drm:drm-scanout-buffer scanout 0)
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

(deftest a-card-whose-master-cannot-be-taken-is-programmed-anyway
  ;; Measured on a VT (D59): logind hands over a descriptor but not the right, so SET
  ;; MASTER answers EACCES even on a card nobody is using, and wlroots carries on.
  ;; So does this: the CRTC programming is where the kernel says no, and the scanout
  ;; records that it does not hold master, which is what closing it needs to know.
  (let ((device (new-screen-device :master-error t)))
    (let ((scanout (drm:drm-open-scanout device)))
      (unwind-protect
           (let ((kinds (call-kinds device)))
             (ok (eq :take-master (first kinds)) "SET MASTER was asked, and refused")
             (ok (member :set-crtc kinds) "and the CRTC was programmed anyway")
             (ok (not (drm:drm-scanout-master-p scanout))
                 "the scanout does not claim a master it does not hold")
             (ok (not (drm:drm-device-master-p device))))
        (drm:drm-close-scanout scanout))
      (let ((kinds (call-kinds device)))
        (ok (not (member :drop-master kinds))
            "nothing is dropped that was never taken")
        (ok (= 2 (count :set-crtc kinds))
            "and the CRTC's saved state is still put back")))))

(deftest a-crtc-that-cannot-be-programmed-leaves-nothing-taken
  ;; With master best effort, the refusal that matters is the CRTC's: everything
  ;; the open built has to go away, and no master may be dropped that was not held.
  (let ((device (new-screen-device :program-error t)))
    (let ((condition (handler-case (drm:drm-open-scanout device)
                       (drm:drm-error (condition) condition))))
      (ok (typep condition 'drm:drm-error))
      (ok (eq :program-crtc (drm:drm-error-operation condition)))
      (ok (= ffi:+eacces+ (drm:drm-error-errno condition)))
      (let ((kinds (call-kinds device)))
        (ok (= 2 (count :destroy-dumb kinds)) "both buffers were destroyed")
        (ok (member :set-crtc kinds) "the CRTC's saved state was put back")
        (ok (eq :drop-master (car (last kinds)))
            "and master, which this card did grant, is dropped last"))
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

;;; ---------------------------------------------------------------------------
;;; The screen a seat hands out (4d-3)
;;; ---------------------------------------------------------------------------
;;
;; The same recording card, now opened through a seat instead of by path.  This is
;; the join the first four slices of phase 4 each proved one half of: a seat
;; callback opens the card *through* the seat, the screen is programmed, and a
;; disable puts the screen back before the descriptor goes back.  The descriptor is
;; a real memfd, so "given back" is a real close(2) and not a number compared.

(defclass fake-session (session:session)
  ((calls :initform '() :accessor fake-calls)
   (pending :initform '() :accessor fake-pending)
   (next-id :initform 0 :accessor fake-next-id)
   (open-fds :initform (make-hash-table) :accessor fake-open-fds)
   (opened-fds :initform '() :accessor fake-opened-fds)
   (card-error :initform nil :accessor fake-card-error)
   (card-class :initarg :card-class :initform 'recording-screen-device
               :accessor fake-card-class))
  (:documentation
   "A seat whose provider is the test: no logind, no seatd, and descriptors that
are real files, so closing them is observable."))

(defmethod session:%open-seat ((session fake-session))
  (push :open-seat (fake-calls session))
  (cffi:null-pointer))

(defmethod session:%close-seat ((session fake-session))
  (push :close-seat (fake-calls session))
  t)

(defmethod session:%acknowledge-disable ((session fake-session))
  (push :acknowledge (fake-calls session))
  t)

(defmethod session:%open-device ((session fake-session) path)
  (push (list :open-device path) (fake-calls session))
  (let ((fd (ffi:memfd-create "cl-wayland-vt-test"))
        (id (incf (fake-next-id session))))
    (setf (gethash id (fake-open-fds session)) fd)
    (push fd (fake-opened-fds session))
    (values fd id)))

(defmethod session:%close-device ((session fake-session) id)
  (push (list :close-device id) (fake-calls session))
  (let ((fd (gethash id (fake-open-fds session))))
    (when fd
      (remhash id (fake-open-fds session))
      (ffi:close-fd fd)))
  t)

(defmethod session:%dispatch ((session fake-session) timeout)
  (declare (ignore timeout))
  (push :dispatch (fake-calls session))
  (let ((event (pop (fake-pending session))))
    (case event
      (:enable (session:note-seat-enabled session) 1)
      (:disable (session:note-seat-disabled session) 1)
      (t 0))))

(defmethod session:%switch-session ((session fake-session) vt)
  (push (list :switch vt) (fake-calls session))
  t)

(defmethod session:%seat-fd ((session fake-session)) -1)

(defun make-seat (&key (enabled t) (card-class 'recording-screen-device))
  "A seat that is already enabled, the way logind hands one over."
  (let ((session (session:open-session :class 'fake-session :name "seat0"
                                       :initargs (list :card-class card-class))))
    (when enabled
      (session:note-seat-enabled session))
    session))

(defun seat-calls (session)
  "What the provider was asked, oldest first."
  (reverse (fake-calls session)))

(defmethod vt:open-vt-device ((output vt:vt-output) (session fake-session) path)
  "A recording card in place of the kernel's: the descriptor is real, the card is not."
  (multiple-value-bind (fd id) (session:open-session-device session path)
    (values (make-instance (fake-card-class session)
                           :path path :fd fd :driver-name "vkms"
                           :inventory (make-inventory)
                           :program-error (fake-card-error session))
            id)))

(deftest a-seat-enabled-output-opens-its-card-through-the-seat
  (let* ((session (make-seat))
         (output (vt:open-vt-output session :path "/dev/dri/card0"))
         (device (vt:vt-output-device output)))
    (ok (eq :enabled (session:session-state session)) "the seat is enabled")
    (ok (vt:vt-output-enabled-p output)
        "and the output came up with it, with no switch and no manual enable")
    (ok (equal (list :open-device "/dev/dri/card0")
               (find-if #'consp (fake-calls session)))
        "the card was asked for by the path the seat knows, before anything was drawn")
    (ok (eq :take-master (first (call-kinds device)))
        "master first, which is what KMS requires and what EBUSY answers")
    (ok (eq :set-crtc (car (last (call-kinds device))))
        "and the CRTC programmed with the first frame")
    (ok (= 1024 (vt:vt-output-width output)) "the size a scene is given")
    (ok (= 768 (vt:vt-output-height output)))
    (ok (string= "Virtual-1" (vt:vt-output-connector-name output))
        "the screen is remembered, so a switch back reprograms the same one")
    (ok (= 1 (vt:vt-output-enable-count output)) "one enable, recorded as evidence")
    (ok (= 1 (session:session-open-device-count session))
        "and the seat knows exactly one device is open")))

(deftest a-disable-restores-the-screen-before-giving-the-card-back
  (let* ((session (make-seat))
         (output (vt:open-vt-output session :path "/dev/dri/card0"))
         (device (vt:vt-output-device output))
         (fd (drm:drm-device-fd device)))
    (vt:disable-vt-output output)
    (ok (not (vt:vt-output-enabled-p output)) "the output is off")
    (let ((kinds (call-kinds device)))
      (ok (< (position :set-crtc kinds) (position :drop-master kinds))
          "the CRTC's saved state goes back before master is dropped")
      (ok (eq :drop-master (car (last kinds))) "and dropping master is the last call"))
    (ok (eq :close-device (first (first (fake-calls session))))
        "the descriptor goes back to the seat after the screen does")
    (ok (not (ffi:fd-open-p fd))
        "the seat closes what the seat opened, so the descriptor is gone")
    (ok (not (drm:drm-device-open-p device)) "and the device no longer claims it")
    (ok (zerop (session:session-open-device-count session))
        "with nothing left open in the seat's bookkeeping")
    (ok (= 1 (vt:vt-output-disable-count output)))))

(deftest a-vt-switch-takes-the-screen-away-and-brings-it-back
  (let* ((session (make-seat))
         (output (vt:open-vt-output session :path "/dev/dri/card0"))
         (device (vt:vt-output-device output)))
    (setf (fake-pending session) '(:disable :enable))
    (session:dispatch-session session)
    (ok (not (vt:vt-output-enabled-p output))
        "the disable callback gave the screen back, without the compositor asking")
    (ok (= 1 (vt:vt-output-disable-count output)))
    (session:dispatch-session session)
    (ok (vt:vt-output-enabled-p output) "and the enable callback took it again")
    (ok (= 2 (vt:vt-output-enable-count output)) "twice enabled, once disabled")
    (let* ((before (find-call device :set-crtc))
           (now (vt:vt-output-device output))
           (after (find-call now :set-crtc)))
      (ok (not (eq device now))
          "a new card handle, because the seat handed out a new descriptor")
      (ok (eq :take-master (first (call-kinds now)))
          "master taken again, because dropping it gave it away")
      (ok (equal (sixth before) (sixth after))
          "the same connector both times, because it was remembered")
      (ok (string= (seventh before) (seventh after))
          "and the same mode, not whatever the card prefers now"))))

(deftest an-enable-that-cannot-program-the-screen-gives-the-descriptor-back
  ;; Master is best effort now (D59), so the failure that still has to be tidy is the
  ;; CRTC's: the seat's descriptor goes back and no hook is left behind.
  (let ((session (make-seat)))
    (setf (fake-card-error session) t)
    (ok (signals (vt:open-vt-output session :path "/dev/dri/card0") 'drm:drm-error)
        "a CRTC that cannot be programmed is signalled, not swallowed")
    (ok (zerop (session:session-open-device-count session))
        "the seat has no device open")
    (ok (null (session:session-on-enabled session))
        "and no hook was left behind for a later switch to call")
    (ok (null (session:session-on-disabled session)))
    (ok (every (lambda (fd) (not (ffi:fd-open-p fd))) (fake-opened-fds session))
        "every descriptor the seat handed out is closed")))

(deftest a-disabled-output-has-nothing-to-draw-into
  (let* ((session (make-seat))
         (output (make-instance 'vt:vt-output :session session :path "nowhere")))
    (ok (signals (vt:render-vt-output output nil) 'error)
        "drawing without a card is an error, not a write into memory nobody scans")
    (ok (signals (vt:present-vt-output output) 'error)
        "and there is nothing to flip to")))

(deftest closing-an-output-twice-is-quiet
  (let* ((session (make-seat))
         (output (vt:open-vt-output session :path "/dev/dri/card0")))
    (ok (vt:close-vt-output output) "the first close")
    (ok (null (session:session-on-enabled session)) "the enable hook is gone")
    (ok (null (session:session-on-disabled session)) "and the disable hook with it")
    (ok (vt:close-vt-output output) "the second close is the same as the first")
    (ok (not (vt:vt-output-enabled-p output)))))

(deftest a-closed-output-is-not-brought-back-by-a-later-enable
  (let* ((session (make-seat))
         (output (vt:open-vt-output session :path "/dev/dri/card0")))
    (vt:close-vt-output output)
    (setf (fake-pending session) '(:disable :enable))
    (session:dispatch-session session)
    (session:dispatch-session session)
    (ok (= 1 (vt:vt-output-enable-count output))
        "a compositor that closed its output is not overruled by the seat")
    (ok (not (vt:vt-output-enabled-p output)))))

;;; ---------------------------------------------------------------------------
;;; What each buffer may still be trusted to hold (D61)
;;; ---------------------------------------------------------------------------
;;
;; The arithmetic is the nested backend's (D50); this is the card's version of it,
;; and the input to it is the difference.  Two levels again: the age arithmetic on
;; its own -- a buffer nobody has painted, one that missed a frame, one that missed
;; a wholesale repaint -- and then a real frame through the compositor's own seam,
;; into real memory with a padded pitch, where what was claimed is also what the
;; pixels say.

(defclass pixel-screen-device (recording-screen-device)
  ((mappings :initform (make-hash-table :test #'eql) :accessor pixel-mappings)
   (padding :initarg :padding :initform 16 :reader pixel-padding)
   (flips :initform 0 :accessor pixel-flips))
  (:documentation
   "A recording card whose dumb buffers are real memory, with a padded pitch.

A renderer reads the pitch and every write goes through it, so the card these tests
draw into cannot answer with a fake pointer: a frame here lands in a memfd this
process owns, and the padding is the driver's freedom made visible -- this card
always pads, so a target built from width x 4 would shear (D58)."))

(defmethod drm:drm-claim-dumb ((device pixel-screen-device) width height bits-per-pixel)
  (push (list :create-dumb width height bits-per-pixel) (recording-calls device))
  (let* ((pitch (+ (* width (floor bits-per-pixel 8)) (pixel-padding device)))
         (handle (incf (recording-handle device))))
    (values handle pitch (* pitch height))))

(defmethod drm:drm-map-dumb-memory ((device pixel-screen-device) handle size)
  (push (list :map-dumb handle size) (recording-calls device))
  (let ((fd (ffi:memfd-create "cl-wayland-vt-damage-test")))
    (unwind-protect
         (progn
           (ffi:set-file-size fd size)
           (let ((pointer (ffi:map-file fd size
                                        :protection (logior ffi:+prot-read+
                                                            ffi:+prot-write+))))
             (setf (gethash handle (pixel-mappings device)) (list pointer size))
             pointer))
      (ffi:close-fd fd))))

(defmethod drm:drm-unmap-dumb-memory ((device pixel-screen-device) buffer)
  (push (list :unmap-dumb (drm:dumb-buffer-handle buffer)) (recording-calls device))
  (let* ((handle (drm:dumb-buffer-handle buffer))
         (entry (gethash handle (pixel-mappings device))))
    (when entry
      (remhash handle (pixel-mappings device))
      (ffi:unmap-file (first entry) (second entry))))
  (values))

(defmethod drm:drm-read-events ((device pixel-screen-device) &key timeout-ms)
  "Every flip retires at once, as a completion for the CRTC that was programmed."
  (declare (ignore timeout-ms))
  (incf (pixel-flips device))
  (list (flip-event :sequence (pixel-flips device))))

;;; The age arithmetic, without a card, a compositor or a frame.

(defun make-damage-output ()
  "A VT output with nothing behind it: the history functions read only its slots."
  (make-instance 'vt:vt-output :session nil :path "nowhere"))

(deftest a-screen-nobody-has-painted-is-painted-whole
  (let ((output (make-damage-output)))
    (ok (eq :full (vt:vt-buffer-repaint-region output 'buffer-a 1))
        "a buffer the card has never been given has nothing to trust")))

(deftest a-buffer-repaints-the-frames-it-missed
  ;; Two buffers alternate, so a buffer drawn at frame 1 is used again at frame 3 and
  ;; missed exactly frame 2 -- and only frame 2's change has to be painted into it.
  (let* ((output (make-damage-output))
         (damage (render:make-region)))
    (render:region-add damage 10 10 5 5)
    (setf (gethash 'buffer-a (vt::vt-output-buffer-frames output)) 1)
    (vt:record-vt-frame-damage output 2 damage)
    (let ((region (vt:vt-buffer-repaint-region output 'buffer-a 3)))
      (ok (not (eq :full region)) "an age-2 buffer is repainted, not painted whole")
      (ok (equal '(10 10 5 5) (render:region-bounds region))
          (format nil "and the region is the change of the frame it missed: ~S"
                  (render:region-bounds region))))
    (ok (eq :full (vt:vt-buffer-repaint-region output 'buffer-a 4))
        "a buffer three frames old is painted whole")))

(deftest a-frame-that-changed-everything-makes-the-next-buffer-whole
  (let ((output (make-damage-output)))
    (setf (gethash 'buffer-a (vt::vt-output-buffer-frames output)) 1)
    (vt:record-vt-frame-damage output 2 nil)     ; :full, recorded as NIL
    (ok (eq :full (vt:vt-buffer-repaint-region output 'buffer-a 3))
        "a missed wholesale repaint makes the buffer whole")))

(deftest a-frame-nobody-recorded-makes-the-next-buffer-whole
  (let ((output (make-damage-output)))
    (setf (gethash 'buffer-a (vt::vt-output-buffer-frames output)) 1)
    (ok (eq :full (vt:vt-buffer-repaint-region output 'buffer-a 3))
        "an age-2 buffer whose missing frame has no entry is painted whole")))

(deftest the-damage-history-keeps-two-frames-and-no-more
  (let ((output (make-damage-output))
        (damage (render:make-region)))
    (render:region-add damage 0 0 100 80)
    (dotimes (frame 5)
      (vt:record-vt-frame-damage output (1+ frame) damage))
    (ok (= 2 (length (vt:vt-output-damage-history output)))
        "five frames in, the history holds the last two")
    (ok (equal '(5 4) (mapcar #'car (vt:vt-output-damage-history output)))
        "newest first")
    (ok (= 2 (length (vt::vt-output-history-regions output)))
        "and the pair of regions is reused, so recording a frame allocates nothing")
    (ok (eq (nth (mod 5 2) (vt::vt-output-history-regions output))
            (cdr (first (vt:vt-output-damage-history output))))
        "frame 5 uses region (5 mod 2) of the pair, not a fresh one")))

;;; The frame, through the compositor's seam, into real memory.

(defvar *frame-directory-counter* 0)

(defun make-frame-directory ()
  (let ((path (format nil "/tmp/cl-wayland-vt-damage-~D-~D/"
                      (get-universal-time) (incf *frame-directory-counter*))))
    (ensure-directories-exist path)
    (ffi:chmod-path (string-right-trim "/" path) #o700)
    path))

(defmacro with-vt-frames ((output compositor &key (width 200) (height 150)) &body body)
  "A seat-enabled VT output on padded real memory, and a compositor wired to it.

The out-of-body unwind order is the real one (D59): the compositor first, because it
holds no card of its own, then the output, which gives the screen and the seat's
descriptor back."
  (let ((directory (gensym "DIRECTORY"))
        (session (gensym "SESSION")))
    `(let ((,directory (make-frame-directory))
           (srv:*log-level* :warn))
       (unwind-protect
            (let* ((,session (make-seat :card-class 'pixel-screen-device))
                   (,output (vt:open-vt-output ,session :path "/dev/dri/card0"))
                   (,compositor (cf:make-headless-compositor
                                 :width ,width :height ,height
                                 :display-name "vt-damage-0"
                                 :runtime-dir ,directory)))
              (unwind-protect
                   (progn
                     (multiple-value-bind (preparer presenter)
                         (vt:make-vt-frame-hooks ,output)
                       (setf (headless:compositor-frame-preparer ,compositor) preparer
                             (headless:compositor-frame-presenter ,compositor)
                             presenter))
                     (locally ,@body))
                (srv:close-display (cf:compositor-display ,compositor))
                (vt:close-vt-output ,output)))
         (ignore-errors (uiop:delete-directory-tree (pathname ,directory)
                                                    :validate t))))))

(defun next-buffer (output)
  (drm:drm-scanout-next-buffer (vt:vt-output-scanout output)))

(deftest the-first-two-frames-paint-both-buffers-whole-and-the-third-does-not
  (with-vt-frames (output compositor :width 200 :height 150)
    (cf:render-frame compositor)
    (ok (= 0 (cf:compositor-partial-frame-count compositor))
        "the first frame has nothing to trust, so it paints everything")
    (cf:render-frame compositor)
    (ok (= 0 (cf:compositor-partial-frame-count compositor))
        "and so does the second, because the other buffer has never been painted")
    (cf:inject-pointer-motion compositor 50 40)
    (cf:render-frame compositor)
    (ok (= 1 (cf:compositor-partial-frame-count compositor))
        "the third frame repaints only what changed since that buffer was drawn")
    (let ((bounds (cf:output-damage-bounds compositor)))
      (ok (consp bounds)
          (format nil "the damage is a box, not the whole output: ~S" bounds))
      (when (consp bounds)
        (destructuring-bind (x y w h) bounds
          (ok (and (< (+ x w) 200) (< (+ y h) 150))
              (format nil "and the box is the pointer's, not the screen's: ~S"
                      bounds)))))
    (ok (= 3 (drm:drm-scanout-frames (vt:vt-output-scanout output)))
        "all three frames were presented")))

(defun count-colour (buffer x y width height colour)
  "How many pixels in the box hold COLOUR -- a claim the pixels make, not the code."
  (loop for py from y below (+ y height)
        sum (loop for px from x below (+ x width)
                  count (= colour (drm:dumb-buffer-pixel buffer px py)))))

(deftest a-damaged-frame-leaves-the-pixels-it-did-not-damage-alone
  ;; The claim a full repaint would hide: the buffer this frame draws into is not
  ;; repainted everywhere, so a pixel far from the change keeps whatever it held.
  (with-vt-frames (output compositor :width 200 :height 150)
    (cf:inject-pointer-motion compositor 20 20)
    (cf:render-frame compositor)                ; buffer 0, whole
    (cf:render-frame compositor)                ; buffer 1, whole
    (let ((buffer (next-buffer output)))
      ;; Frame 3 draws into buffer 0.  Paint it with a sentinel first: whatever the
      ;; frame does not damage must still be the sentinel afterwards.
      (render:fill-target (vt:vt-output-frame-target output buffer) #xFF5A5A5A)
      (cf:inject-pointer-motion compositor 150 110)
      (cf:render-frame compositor)
      (ok (= #xFF5A5A5A (drm:dumb-buffer-pixel buffer 10 140))
          "a pixel nobody damaged still holds what it held")
      (ok (plusp (count-colour buffer 150 110 16 16 #xFFFFFFFF))
          "the pixels the pointer moved to are painted")
      (ok (zerop (count-colour buffer 20 20 16 16 #xFF5A5A5A))
          "the box the pointer left is repainted, not left to itself")
      (ok (zerop (count-colour buffer 20 20 16 16 #xFFFFFFFF))
          "and no arrow is left behind there"))))

(deftest a-frame-with-nothing-to-show-does-not-flip
  ;; A flip costs a vblank's wait and paints no pixels, so a frame whose damage is
  ;; empty presents nothing -- but it is still a frame in the history, or the next
  ;; buffer would be repainted whole for no reason (D50's arithmetic, D61's input).
  (with-vt-frames (output compositor :width 200 :height 150)
    (cf:render-frame compositor)
    (cf:render-frame compositor)
    (let ((flips (drm:drm-scanout-frames (vt:vt-output-scanout output))))
      (cf:render-frame compositor)
      (ok (= flips (drm:drm-scanout-frames (vt:vt-output-scanout output)))
          "an unchanged frame is drawn, not flipped")
      (ok (= 3 (vt:vt-output-frame-sequence output))
          "but it took a frame number, so the history knows it happened"))))

(deftest a-vt-switch-forgets-every-buffer
  (with-vt-frames (output compositor :width 200 :height 150)
    (cf:inject-pointer-motion compositor 20 20)
    (cf:render-frame compositor)
    (cf:render-frame compositor)
    (ok (plusp (hash-table-count (vt::vt-output-buffer-frames output)))
        "two frames in, both buffers are known")
    (setf (fake-pending (vt:vt-output-session output)) '(:disable :enable))
    (session:dispatch-session (vt:vt-output-session output))
    (ok (zerop (hash-table-count (vt::vt-output-buffer-frames output)))
        "a disable destroys the buffers, so nothing is claimed about them")
    (ok (null (vt:vt-output-damage-history output))
        "and the history goes with them")
    (session:dispatch-session (vt:vt-output-session output))
    (ok (zerop (vt:vt-output-frame-sequence output))
        "the sequence starts again with the new scanout")))

;;; ---------------------------------------------------------------------------
;;; Hotplug: the cable as a question (D62)
;;; ---------------------------------------------------------------------------

(defun two-connectors (first second)
  "An inventory with two connectors, FIRST before SECOND, on one CRTC and encoder."
  (let ((inventory (make-inventory :connector first)))
    (setf (drm::drm-inventory-connectors inventory) (list first second))
    inventory))

(deftest the-hotplug-key-changes-only-when-the-cable-moves
  (let* ((device (new-screen-device))
         (before (drm:drm-hotplug-key device)))
    (ok (equal before (drm:drm-hotplug-key device))
        "two reads of an untouched card compare equal")
    (setf (recording-inventory device)
          (make-inventory :connector (make-connector :modes '() :status :disconnected)))
    (ok (not (equal before (drm:drm-hotplug-key device)))
        "a connector's status is part of the key")
    (let* ((smaller (make-mode :name "1280x720" :clock 74250
                               :width 1280 :height 720 :htotal 1650 :vtotal 750))
           (one (drm:drm-hotplug-key device)))
      (setf (recording-inventory device)
            (make-inventory :connector (make-connector :modes (list smaller))))
      (ok (not (equal one (drm:drm-hotplug-key device)))
          "and so are the modes on offer, so another monitor on the same cable is not a no-op"))))

(deftest an-unchanged-card-is-a-no-op
  (let* ((session (make-seat))
         (output (vt:open-vt-output session :path "/dev/dri/card0"))
         (device (vt:vt-output-device output))
         (kinds (call-kinds device)))
    (ok (eq :unchanged (vt:pump-vt-hotplug output)))
    (ok (eq :unchanged (vt:pump-vt-hotplug output)) "twice is still a no-op")
    (ok (equal kinds (call-kinds device))
        "and nothing was asked of the kernel beyond the enumeration")
    (ok (zerop (vt:vt-output-hotplug-count output)) "nothing counted")))

(deftest an-unplugged-cable-gives-the-screen-back-and-keeps-the-card
  (let* ((session (make-seat))
         (output (vt:open-vt-output session :path "/dev/dri/card0"))
         (device (vt:vt-output-device output)))
    (setf (recording-inventory device)
          (make-inventory :connector (make-connector :modes '() :status :disconnected)))
    (ok (eq :unplugged (vt:pump-vt-hotplug output)) "the cable going is noticed")
    (ok (not (vt:vt-output-screen-p output)) "the screen is given back")
    (ok (vt:vt-output-device output)
        "and the card is kept, because it is the only way to ask whether the cable came back")
    (ok (= 1 (session:session-open-device-count session))
        "the seat still counts exactly one device open")
    (ok (= 1 (vt:vt-output-hotplug-count output)) "one cable change counted")
    (ok (eq :unchanged (vt:pump-vt-hotplug output)) "still out is a no-op")
    (ok (= 1 (vt:vt-output-hotplug-count output)) "not counted again")))

(deftest a-returned-cable-brings-the-screen-back-with-a-fresh-history
  (let* ((session (make-seat))
         (output (vt:open-vt-output session :path "/dev/dri/card0"))
         (device (vt:vt-output-device output)))
    (setf (recording-inventory device)
          (make-inventory :connector (make-connector :modes '() :status :disconnected)))
    (vt:pump-vt-hotplug output)
    (setf (recording-inventory device)
          (make-inventory :connector (make-connector :modes (list (make-mode)))))
    (ok (eq :replugged (vt:pump-vt-hotplug output)) "the cable coming back is noticed")
    (ok (vt:vt-output-screen-p output) "and the screen comes back")
    (ok (= 1024 (vt:vt-output-width output)) "at the mode the monitor offers")
    (ok (= 2 (vt:vt-output-enable-count output)) "programmed a second time")
    (ok (zerop (vt:vt-output-frame-sequence output))
        "and the frame history went with the buffers"
        )
    (ok (zerop (vt:vt-output-disable-count output))
        "a pulled cable is not a disable: the output gave the screen back, not the card")))

(deftest a-different-monitor-on-the-same-cable-is-a-new-mode
  (let* ((session (make-seat))
         (output (vt:open-vt-output session :path "/dev/dri/card0"))
         (device (vt:vt-output-device output))
         (smaller (make-mode :name "1280x720" :clock 74250
                             :width 1280 :height 720 :htotal 1650 :vtotal 750)))
    (setf (recording-inventory device)
          (make-inventory :connector (make-connector :modes (list smaller))))
    (ok (eq :reprogrammed (vt:pump-vt-hotplug output))
        "the connector stayed connected, but what it offers changed")
    (ok (= 1280 (vt:vt-output-width output)) "the new monitor's mode is programmed")
    (ok (= 720 (vt:vt-output-height output)))
    (ok (string= "1280x720" (drm:drm-mode-name (vt:vt-output-mode output)))
        "and the remembered mode is the new one")
    (ok (eq :set-crtc (car (last (call-kinds device)))) "by a modeset, last")))

(deftest an-automatic-connector-follows-the-card
  ;; Opened with no connector named, so the card chose; when that socket goes and
  ;; another is connected, the output goes where the picture is (D62).
  (let* ((hdmi (make-connector :name "Virtual-1" :id 7 :modes (list (make-mode))))
         (display-port (make-connector :name "DP-1" :id 8 :modes
                                       (list (make-mode :name "1280x720" :clock 74250
                                                        :width 1280 :height 720
                                                        :htotal 1650 :vtotal 750))))
         (session (make-seat))
         (output nil)
         (device nil))
    (unwind-protect
         (progn
           (setf output (vt:open-vt-output session :path "/dev/dri/card0"))
           (setf device (vt:vt-output-device output))
           (ok (string= "Virtual-1" (vt:vt-output-connector-name output))
               "the card chose the first connected connector")
           (setf (recording-inventory device)
                 (two-connectors (make-connector :name "Virtual-1" :id 7 :status :disconnected
                                                 :modes '())
                                 display-port))
           (ok (eq :reprogrammed (vt:pump-vt-hotplug output))
               "the other socket is connected, so the screen moves to it")
           (ok (string= "DP-1" (vt:vt-output-connector-name output)))
           (ok (= 1280 (vt:vt-output-width output)) "at its own mode"))
      (when output (ignore-errors (vt:close-vt-output output))))))

(deftest a-named-connector-is-waited-for
  ;; Named explicitly, so the compositor was asked for that socket and no other; when
  ;; it goes, the screen stays off until it returns, even if something else is plugged
  ;; in (D62).
  (let* ((hdmi (make-connector :name "Virtual-1" :id 7 :modes (list (make-mode))))
         (display-port (make-connector :name "DP-1" :id 8 :modes (list (make-mode))))
         (session (make-seat))
         (output (vt:open-vt-output session :path "/dev/dri/card0" :connector "Virtual-1"))
         (device (vt:vt-output-device output)))
    (unwind-protect
         (progn
           (setf (recording-inventory device)
                 (two-connectors (make-connector :name "Virtual-1" :id 7
                                                 :status :disconnected :modes '())
                                 display-port))
           (ok (eq :unplugged (vt:pump-vt-hotplug output))
               "the named connector going is the screen going")
           (ok (not (vt:vt-output-screen-p output)))
           (ok (string= "Virtual-1" (vt:vt-output-connector-name output))
               "and the socket is remembered, not replaced by the other one")
           (setf (recording-inventory device)
                 (two-connectors hdmi display-port))
           (ok (eq :replugged (vt:pump-vt-hotplug output))
               "so the screen comes back when that cable does"))
      (ignore-errors (vt:close-vt-output output)))))

(deftest a-disabled-seat-has-no-card-to-ask
  (let* ((session (make-seat))
         (output (vt:open-vt-output session :path "/dev/dri/card0")))
    (session:note-seat-disabled session)
    (ok (eq :no-card (vt:pump-vt-hotplug output))
        "a VT switch closes the card, so there is nothing to poll until the seat comes back")))

;;; ---------------------------------------------------------------------------
;;; Resume: the sleep the clocks remember (D63)
;;; ---------------------------------------------------------------------------

(deftest the-resume-gap-is-the-time-the-machine-was-asleep
  (ok (null (vt:resume-gap 100 50 nil nil))
      "no previous reading is not a gap")
  (ok (zerop (vt:resume-gap 100.5 50.5 100 50))
      "two readings of an awake machine, one loop apart")
  (ok (= 30 (round (vt:resume-gap 130.1 50.1 100 50)))
      "boottime counts through a suspend and monotonic does not: thirty seconds is thirty")
  (ok (= 29 (round (vt:resume-gap 130.1 51.1 100 50)))
      "the loop's own second awake is not counted as sleep")
  (ok (zerop (vt:resume-gap 99 51 100 50))
      "a negative gap -- a clock that went backwards -- is clamped, not believed"))

(defun call-count (device)
  (length (recorded device)))

(defun the-crtc-is-showing (device output)
  "Make DEVICE's saved CRTC state claim the framebuffer OUTPUT is showing."
  (let* ((scanout (vt:vt-output-scanout output))
         (front (drm:drm-scanout-buffer scanout (drm:drm-scanout-front scanout)))
         (crtc (drm:drm-inventory-crtc (recording-inventory device) 33)))
    (setf (drm:drm-crtc-buffer-id crtc) (drm:dumb-buffer-framebuffer-id front)
          (drm:drm-crtc-mode-valid-p crtc) t)
    crtc))

(deftest a-resume-that-finds-the-screen-ours-repaints-it-in-full
  (with-vt-frames (output compositor :width 200 :height 150)
    (let ((device (vt:vt-output-device output)))
      (cf:render-frame compositor)
      (cf:render-frame compositor)
      (ok (= 2 (vt:vt-output-frame-sequence output)) "two frames drawn")
      (ok (eq :awake (vt:pump-vt-resume output :boottime 100 :monotonic 50))
          "the first call has nothing to compare with")
      (the-crtc-is-showing device output)
      (let ((calls (call-count device)))
        (ok (eq :resumed (vt:pump-vt-resume output :boottime 130.1 :monotonic 50.1))
            "thirty seconds of boottime with no monotonic time is a sleep")
        (ok (= calls (call-count device))
            "and the card is asked nothing: the CRTC was still ours")
        (ok (= 1 (vt:vt-output-resume-count output)) "the resume is counted")
        (ok (= 30 (floor (vt:vt-output-sleep-gap output))) "with how long it lasted")
        (ok (zerop (vt:vt-output-frame-sequence output))
            "the buffers' pixels cannot be trusted, so the history is gone")
        (cf:render-frame compositor)
        (ok (eq :full (cf:output-damage-bounds compositor))
            "and the frame after a resume is full, not whatever changed")
        (ok (zerop (cf:compositor-partial-frame-count compositor))
            "counted as a full frame")))))

(deftest a-resume-that-finds-the-screen-not-ours-programs-it-again
  (with-vt-frames (output compositor :width 200 :height 150)
    (let ((device (vt:vt-output-device output)))
      (cf:render-frame compositor)
      (vt:pump-vt-resume output :boottime 100 :monotonic 50)
      ;; The CRTC still says framebuffer 0: the kernel restored something that is not
      ;; ours, which is what a resume on a card without modeset restore looks like.
      (setf (drm:drm-crtc-buffer-id
             (drm:drm-inventory-crtc (recording-inventory device) 33))
            0)
      (let ((programs (length (find-calls device :set-crtc))))
        (ok (eq :reprogrammed (vt:pump-vt-resume output
                                               :boottime 145 :monotonic 50.2))
            "forty-five seconds asleep, and the screen is not this compositor's")
        (ok (= (+ 2 programs) (length (find-calls device :set-crtc)))
            "so the screen is given back and programmed again -- two modesets, not one")
        (let ((last-call (car (last (find-calls device :set-crtc)))))
          (ok (equal '(7) (sixth last-call)) "through the same connector")
          (ok (string= "1024x768" (seventh last-call)) "and at the same mode"))
        (ok (= 1 (vt:vt-output-resume-count output)) "counted once")
        (ok (= 1024 (vt:vt-output-width output)) "at the same connector and mode")))))

(deftest a-resume-while-the-seat-is-away-has-nothing-to-program
  (with-vt-frames (output compositor :width 200 :height 150)
    (declare (ignore compositor))
    (vt:pump-vt-resume output :boottime 100 :monotonic 50)
    (vt:disable-vt-output output)
    (ok (eq :no-card (vt:pump-vt-resume output :boottime 130 :monotonic 50.1))
        "a VT switch closed the descriptor: nothing to check until the seat comes back")))

;;; ---------------------------------------------------------------------------
;;; A client that double-buffers, which is what GTK does (D64's walk)
;;; ---------------------------------------------------------------------------
;;
;; The frames above move the *pointer*, and the cursor is one item with a known
;; picture.  A GTK client is the other case: two shm buffers, alternating, each
;; commit damaging only the widget that changed, while the buffer that was not
;; drawn into still holds the previous state.  Hovering a link in Emacs flickers if
;; a frame presents the buffer that was not repainted -- so this reads the pixels of
;; the buffer that was just flipped to, after every frame.

(defun make-mapped-pool (width height)
  "A shm pool over a memfd, mapped, big enough for one WIDTH x HEIGHT buffer."
  (let* ((size (* width height 4))
         (fd (ffi:memfd-create "cl-wayland-client-buffer")))
    (ffi:set-file-size fd size)
    (let ((pool (make-instance 'srv:shm-pool :fd fd :size size)))
      (setf (srv:shm-pool-mapping pool)
            (ffi:map-file fd size :protection (logior ffi:+prot-read+
                                                     ffi:+prot-write+)))
      pool)))

(defun fill-client-buffer (buffer colour x y width height)
  "Paint a rectangle of BUFFER's memory, the way a client's cairo surface does."
  (let ((mapping (srv:shm-pool-mapping (srv::shm-buffer-pool buffer))))
    (loop for py from y below (+ y height)
          do (loop for px from x below (+ x width)
                   do (setf (cffi:mem-aref mapping :unsigned-int
                                           (+ (/ (srv:shm-buffer-offset buffer) 4)
                                              px (* py (/ (srv:shm-buffer-stride buffer) 4))))
                            colour)))))

(defun make-client-buffer (width height colour)
  "A shm buffer with its OWN pool, filled with COLOUR (0xAARRGGBB).

Its own pool because two buffers in one pool at offset 0 are the same memory, and
a test whose two buffers alias cannot tell a stale frame from a fresh one."
  (let ((buffer (make-instance 'srv:shm-buffer
                               :pool (make-mapped-pool width height) :offset 0
                               :width width :height height
                               :stride (* 4 width) :format 0)))
    (fill-client-buffer buffer colour 0 0 width height)
    buffer))

(defun client-surface (compositor buffer &key (x 0) (y 0))
  "A mapped compositor surface whose current buffer is BUFFER, at (X, Y)."
  (let* ((display (headless:compositor-display compositor))
         (client (make-instance 'srv:client :id 77 :display display :fd -1))
         (surface (make-instance 'cf:cf-surface
                                 :client client :id 21 :interface nil :version 1)))
    ;; The buffer and the mapped flag first: a node made before them is a
    ;; zero-sized window (the order CL-TINYWL's fake-window uses).
    (setf (srv:surface-current-buffer surface) buffer
          (srv:surface-current-x surface) 0
          (srv:surface-current-y surface) 0
          (srv:surface-mapped-p surface) t)
    (let ((node (cf:on-new-toplevel compositor surface)))
      (cf.scene:set-node-position node x y))
    surface))

(defun render-and-read (compositor output x y)
  "Render one frame and return (values pixel presented-buffer front-index).

NEXT-BUFFER is read *before* the frame, because that is the buffer the frame draws
into and flips; asking afterwards names the one still to come.  FRONT-INDEX is the
scanout's own answer to "what is the display reading now", and it is the only
check that a frame drawn into one buffer was not flipped over another."
  (let ((drawn (next-buffer output)))
    (cf:render-frame compositor)
    (values (drm:dumb-buffer-pixel drawn x y)
            drawn
            (drm:drm-scanout-front (vt:vt-output-scanout output)))))

(deftest the-first-frame-after-an-enable-does-not-draw-into-the-visible-buffer
  ;; Opening the scanout programs the CRTC with buffer 0, so buffer 0 is on the
  ;; screen before any frame is drawn.  A compositor that then draws into buffer 0
  ;; is drawing into the frame the display is reading -- a tear on the first frame
  ;; after every enable: every VT switch back, every hotplug replug, every resume.
  (with-vt-frames (output compositor :width 200 :height 150)
    (let ((scanout (vt:vt-output-scanout output)))
      (ok (= 0 (drm:drm-scanout-front scanout))
          "the CRTC was programmed with buffer 0")
      (ok (/= (drm:drm-scanout-front scanout)
              (position (next-buffer output) (drm::drm-scanout-buffers scanout)))
          "so the first frame must draw into the other one")))
  (with-vt-frames (output compositor :width 200 :height 150)
    (let ((drawn (next-buffer output))
          (scanout (vt:vt-output-scanout output)))
      (cf:render-frame compositor)
      (ok (= (drm:drm-scanout-front scanout)
             (position drawn (drm::drm-scanout-buffers scanout)))
          "and the flip goes to the buffer that was drawn"))))

(deftest a-double-buffered-client-never-shows-a-stale-highlight
  ;; The window sits at (40,30), clear of the cursor's 16x16 arrow at the origin:
  ;; the first version of this test read pixels under the pointer and could not tell
  ;; a stale frame from an arrow.
  (with-vt-frames (output compositor :width 200 :height 150)
    (let* ((grey #xFF202020)
           (hot #xFF00FF00)
           (buffer-a (make-client-buffer 120 60 grey))
           (buffer-b (make-client-buffer 120 60 grey))
           (surface (client-surface compositor buffer-a :x 40 :y 30)))
      ;; Two frames, so both scanout buffers hold the plain window.
      (cf:render-frame compositor)
      (multiple-value-bind (pixel presented front) (render-and-read compositor output 60 40)
        (ok (= grey pixel) "the window is on the screen before the hover")
        (ok (= front (position presented
                                (drm::drm-scanout-buffers
                                 (vt:vt-output-scanout output))))
            "and the display is reading the buffer that was drawn"))
      ;; The hover: the client paints the link's box into the *other* buffer and
      ;; commits, damaging only that box -- GTK's pattern exactly.  Surface-local
      ;; (10,10)-(50,22) is device (50,40)-(90,52).
      (fill-client-buffer buffer-b hot 10 10 40 12)
      (setf (srv:surface-current-buffer surface) buffer-b
            (srv:surface-damage-since-frame surface) '((10 10 40 12)))
      (cf:request-frame compositor)
      (multiple-value-bind (pixel presented) (render-and-read compositor output 52 42)
        (declare (ignore presented))
        (ok (= hot pixel) "the buffer that was flipped to shows the highlight"))
      ;; The next frame draws into the other scanout buffer, which missed the
      ;; hover: it owes exactly that change, and if it presents without painting it
      ;; the highlight disappears for a frame -- the flicker.
      (cf:request-frame compositor)
      (multiple-value-bind (pixel presented) (render-and-read compositor output 52 42)
        (declare (ignore presented))
        (ok (= hot pixel)
            "the second scanout buffer has the highlight too, so it does not strobe"))
      (multiple-value-bind (pixel presented) (render-and-read compositor output 140 80)
        (declare (ignore presented))
        (ok (= grey pixel) "and the rest of the window is still the window")))))
