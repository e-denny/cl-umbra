;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The DRM modeset gate (clause 22): take a card, set a mode, flip real frames,
;;;; wait for the kernel's completions, and give the card back (D55).
;;;;
;;;; Run by scripts/drm-modeset-gate.sh.  Exit status: 0 pass, 1 fail, 77 skip.
;;;;
;;;; This is the clause that changes the screen, so which screen it is allowed to
;;;; change is the whole design.  By default it will only take a virtual card --
;;;; vkms, the kernel's virtual KMS, which has a connector, modes, page flips and
;;;; vblank and no display on the other end.  A real card has to be named:
;;;; CL_DRM_MODESET_CARD=/dev/dri/card0 and CL_DRM_MODESET_ALLOW=1.  Two settings,
;;;; because taking somebody's screen should take two deliberate acts.
;;;;
;;;; What makes it a check rather than a rehearsal of our own arithmetic:
;;;;
;;;;   * the CRTC's state is read by GETCRTC before and after, and the after state
;;;;     has to be the before state -- the saved state is not what we hope it is;
;;;;   * every flip has to be retired by an event the kernel sent, with a crtc id
;;;;     that is ours and a sequence number that only goes forward, so a flip that
;;;;     was queued and never completed fails here rather than silently;
;;;;   * each buffer is painted through the renderer that will draw frames and read
;;;;     back before it is flipped, so a pitch that is not the driver's shows up as
;;;;     a wrong pixel;
;;;;   * the connector state in sysfs is compared before and after, the descriptor
;;;;     count is flat, and master is dropped.
;;;;
;;;; A card somebody else is presenting on answers EBUSY to SET MASTER.  That is a
;;;; skip, not a failure, and it is why this clause is safe to run on a working
;;;; machine: the live card refuses.

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defparameter *checks* 0)
(defparameter *failures* 0)

(defun check (value description &rest arguments)
  (incf *checks*)
  (if value
      (format t "  ok   ~A~%" (apply #'format nil description arguments))
      (progn
        (incf *failures*)
        (format t "  FAIL ~A~%" (apply #'format nil description arguments)))))

(defun note (description &rest arguments)
  (format t "       ~A~%" (apply #'format nil description arguments)))

(defun skip (description &rest arguments)
  (format t "drm-modeset-gate: skip ~A~%" (apply #'format nil description arguments))
  (uiop:quit 77))

(defun finish (summary &rest arguments)
  (format t "~&drm-modeset-gate: ~D checks, ~D failed~%" *checks* *failures*)
  (if (plusp *failures*)
      (uiop:quit 1)
      (progn
        (format t "drm-modeset-gate: ~A~%" (apply #'format nil summary arguments))
        (uiop:quit 0))))

(defun fd-count ()
  (length (uiop:directory-files #p"/proc/self/fd/")))

(defun card-of (path)
  (string-right-trim "/" (file-namestring path)))

(defun allowed-card (path)
  "Is this gate willing to take PATH's screen?  Returns (values allowed driver).

A virtual driver: yes.  Anything else: only when a person named this card *and*
set the allow variable, because the two together are a decision and one alone is
an accident.  The driver is asked through libdrm, not /sys: vkms presents as a
faux device and /sys says `faux_driver' while the driver says `vkms'."
  (let ((driver (handler-case (cf.backend.drm:drm-driver-at path)
                  (cf.backend.drm:drm-error () nil)))
        (named (equal (uiop:getenv "CL_DRM_MODESET_CARD") path))
        (allowed (equal (uiop:getenv "CL_DRM_MODESET_ALLOW") "1")))
    (values (and driver
                 (or (cf.backend.drm:drm-virtual-driver-p driver)
                     (and named allowed)))
            driver)))

(defun paint (buffer argb rectangle)
  "Fill BUFFER with ARGB and draw RECTANGLE (x y w h colour) through the renderer
that will draw frames."
  (let ((target (cf.render.pixman:make-target-over-pointer
                 (cf.backend.drm:dumb-buffer-mapping buffer)
                 (cf.backend.drm:dumb-buffer-width buffer)
                 (cf.backend.drm:dumb-buffer-height buffer)
                 :stride (cf.backend.drm:dumb-buffer-pitch buffer))))
    (unwind-protect
         (progn
           (cf.render.pixman:fill-target target argb)
           (destructuring-bind (x y width height colour) rectangle
             (cf.render.pixman:fill-rect target x y width height colour)))
      (cf.render.pixman:destroy-target target))))

;;; ---------------------------------------------------------------------------
;;; The probe
;;; ---------------------------------------------------------------------------

(let* ((paths (cf.backend.drm:drm-device-paths))
       (descriptors-before (fd-count))
       (candidates '()))
  (dolist (path paths)
    (multiple-value-bind (allowed driver) (allowed-card path)
      (when allowed
        (push (list path (card-of path) driver) candidates))))
  (unless candidates
    (skip "no virtual KMS card~@[ (cards: ~{~A~^, ~})~]; load vkms, or name a card with CL_DRM_MODESET_CARD and CL_DRM_MODESET_ALLOW=1"
          (mapcar #'card-of paths)))
  (destructuring-bind (path card sysfs-driver) (first candidates)
    (let ((device (handler-case
                      (cf.backend.drm:open-drm-device path)
                    (cf.backend.drm:drm-error (condition)
                      (if (member (cf.backend.drm:drm-error-errno condition)
                                  (list wayland.ffi:+eacces+ wayland.ffi:+enoent+))
                          (skip "~A was not given to this user (errno ~D)"
                                path (cf.backend.drm:drm-error-errno condition))
                          (progn
                            (incf *failures*)
                            (check nil "open ~A: ~A" path condition)
                            (finish "opening the card failed"))))))
          (sysfs-before (cf.backend.drm:drm-sysfs-state card))
          (scanout nil)
          (saved nil)
          (events '()))
      (note "card ~A (~A), driver ~A~@[ (/sys says ~A)~]"
            card path (cf.backend.drm:drm-device-driver-name device)
            (unless (string= sysfs-driver
                             (cf.backend.drm:drm-device-driver-name device))
              sysfs-driver))
      (unwind-protect
           (progn
             ;; vkms is a faux device: /sys says faux_driver and the driver says
             ;; vkms.  Every real driver's two names agree, so only a virtual one
             ;; is exempt, and the exemption is stated rather than assumed.
             (check (if (cf.backend.drm:drm-virtual-driver-p
                         (cf.backend.drm:drm-device-driver-name device))
                        t
                        (string= sysfs-driver (cf.backend.drm:drm-device-driver-name device)))
                    "the driver is ~A~@[ (its uevent calls the device ~A)~]"
                    (cf.backend.drm:drm-device-driver-name device)
                    (unless (string= sysfs-driver (cf.backend.drm:drm-device-driver-name device))
                      sysfs-driver))
             (check (getf (cf.backend.drm:drm-device-capabilities device) :dumb-buffer)
                    "the driver has dumb buffers")
             (let* ((inventory (cf.backend.drm:drm-inventory device))
                    (connectors (cf.backend.drm:drm-inventory-connected-connectors inventory)))
               (unless connectors
                 (skip "~A has no connected connector" card))
               (let* ((connector (first connectors))
                      (name (cf.backend.drm:drm-connector-name connector))
                      (mode (cf.backend.drm:drm-pick-mode connector))
                      (crtc-id (cf.backend.drm:drm-scanout-crtc inventory connector))
                      (width (cf.backend.drm:drm-mode-hdisplay mode))
                      (height (cf.backend.drm:drm-mode-vdisplay mode)))
                 (setf saved (cf.backend.drm:drm-inventory-crtc inventory crtc-id))
                 (note "connector ~A, crtc ~D, mode ~A ~Dx~D at ~,3F Hz, saved crtc state: framebuffer ~D, ~:[off~;~A~]"
                       name crtc-id (cf.backend.drm:drm-mode-name mode) width height
                       (cf.backend.drm:drm-mode-refresh mode)
                       (cf.backend.drm:drm-crtc-buffer-id saved)
                       (cf.backend.drm:drm-crtc-mode-valid-p saved)
                       (and (cf.backend.drm:drm-crtc-mode saved)
                            (cf.backend.drm:drm-mode-name (cf.backend.drm:drm-crtc-mode saved))))

                 ;; --- take master -------------------------------------------------
                 ;; Not an assertion that we are not master already: the kernel makes
                 ;; the first opener of a free primary node master, which is what a
                 ;; virtual card with nobody on it looks like (measured on vkms).
                 ;; SET MASTER is a real transition only when something else holds
                 ;; the card, and then it answers EBUSY.
                 (note "master at open: ~:[no~;yes (the kernel makes the first opener of a free card master)~]"
                       (cf.backend.drm:drm-device-master-p device))
                 (let ((condition
                         (handler-case (progn (cf.backend.drm:drm-take-master device) nil)
                           (cf.backend.drm:drm-error (condition) condition))))
                   (cond (condition
                          (let ((errno (cf.backend.drm:drm-error-errno condition)))
                            (cond ((and (eq :take-master (cf.backend.drm:drm-error-operation condition))
                                        (= wayland.ffi:+ebusy+ errno))
                                   (skip "~A is driven by another master (EBUSY): this gate does not take a screen somebody is using" card))
                                  ((and (eq :take-master (cf.backend.drm:drm-error-operation condition))
                                        (= wayland.ffi:+eacces+ errno))
                                   (skip "SET MASTER on ~A is EACCES for this user: DRM master is a privileged operation, so run this clause as root (sudo) or from a session that owns the seat" card))
                                  (t
                                   (incf *failures*)
                                   (check nil "take master on ~A: ~A" card condition)))))
                         (t
                          (cf.backend.drm:drm-refresh-master device)
                          (check (cf.backend.drm:drm-device-master-p device)
                                 "SET MASTER succeeded and IS MASTER agrees"))))

                 ;; --- a scanout, which programs the CRTC ---------------------------
                 (setf scanout (cf.backend.drm:drm-open-scanout device :connector connector))
                 (check (cf.backend.drm:drm-scanout-open-p scanout) "a scanout opened on ~A" name)
                 (check (= 2 (cf.backend.drm:drm-scanout-buffer-count scanout))
                        "two buffers, so the frame just replaced is never redrawn")
                 (check (equal (cf.backend.drm:drm-scanout-mode scanout) mode)
                        "the scanout is programmed with the connector's preferred mode")

                 (let* ((after (cf.backend.drm:drm-crtc-state device crtc-id))
                        (first-buffer (cf.backend.drm:drm-scanout-buffer scanout 0)))
                   (check (= (cf.backend.drm:dumb-buffer-framebuffer-id first-buffer)
                             (cf.backend.drm:drm-crtc-buffer-id after))
                          "the CRTC scans out our framebuffer ~D"
                          (cf.backend.drm:dumb-buffer-framebuffer-id first-buffer))
                   (check (and (= width (cf.backend.drm:drm-crtc-width after))
                               (= height (cf.backend.drm:drm-crtc-height after)))
                          "GETCRTC reports the mode we set (~Dx~D)"
                          (cf.backend.drm:drm-crtc-width after)
                          (cf.backend.drm:drm-crtc-height after)))

                 ;; --- paint each buffer, and read it back --------------------------
                 (let ((zero (cf.backend.drm:drm-scanout-buffer scanout 0))
                       (one (cf.backend.drm:drm-scanout-buffer scanout 1)))
                   (paint zero #xFF101820 '(0 0 64 48 #xFFFF8000))
                   (paint one #xFF204060 '(128 96 32 24 #xFF00FF00))
                   (check (and (= #xFFFF8000 (cf.backend.drm:dumb-buffer-pixel zero 0 0))
                               (= #xFF101820 (cf.backend.drm:dumb-buffer-pixel zero 64 48)))
                          "buffer 0: painted through the renderer, read back at pitch ~D"
                          (cf.backend.drm:dumb-buffer-pitch zero))
                   (check (and (= #xFF00FF00 (cf.backend.drm:dumb-buffer-pixel one 130 100))
                               (= #xFF204060 (cf.backend.drm:dumb-buffer-pixel one 0 0)))
                          "buffer 1: a second mapping, painted and read back")

                 ;; --- a scene, cursor included, into the scanout (D58) -------------
                 ;;
                 ;; The compositor's frame is not a painted rectangle: it is the scene,
                 ;; and with no cursor plane in this design the pointer is the last
                 ;; thing the scene draws into this same mapping.  Two claims: the
                 ;; cursor's pixels are in the buffer at the scene's position, and the
                 ;; driver's pitch padding was not written.
                 (let* ((zero (cf.backend.drm:drm-scanout-buffer scanout 0))
                        (scene (cf.scene:make-scene width height :scale 1))
                        (pitch (cf.backend.drm:dumb-buffer-pitch zero))
                        (x (min 200 (- width 20)))
                        (y (min 120 (- height 20))))
                   (setf (cf.scene:scene-cursor-visible-p scene) t)
                   (cf.scene:set-node-position (cf.scene:scene-cursor scene) x y)
                   (cf.backend.drm:drm-scanout-render scanout scene zero :background #xFF101820)
                   (let ((painted 0)
                         (padding-written 0))
                     (loop for py from y below (min height (+ y 16))
                           do (loop for px from x below (min width (+ x 16))
                                    unless (= #xFF101820
                                              (cf.backend.drm:dumb-buffer-pixel zero px py))
                                      do (incf painted)))
                     (when (> pitch (* width 4))
                       (loop for py below (min height 64)
                             do (loop for byte from (* width 4) below pitch
                                      when (/= 0 (cffi:mem-aref (cf.backend.drm:dumb-buffer-mapping zero)
                                                                :unsigned-char
                                                                (+ (* py pitch) byte)))
                                        do (incf padding-written))))
                     (check (plusp painted)
                            "the scene's cursor is in the scanout at (~D,~D): ~D pixel(s)"
                            x y painted)
                     (check (zerop padding-written)
                            "the driver's pitch padding (~D bytes per row) was not written"
                            (- pitch (* width 4))))

                   ;; Present the scene's buffer, so the frame the kernel scanned out is
                   ;; the one with the cursor in it.
                   (let ((event (cf.backend.drm:drm-scanout-present scanout zero :timeout-ms 2000)))
                     (check (plusp (getf event :sequence))
                            "the scene's frame was retired: sequence ~D"
                            (getf event :sequence))
                     (check (= crtc-id (getf event :crtc-id))
                            "and it was our CRTC that retired it")))

                 ;; --- flip, and wait for the kernel to say so ----------------------
                 (let ((start (wayland.ffi:monotonic-seconds)))
                   (dotimes (index 3)
                     (let* ((buffer (cf.backend.drm:drm-scanout-buffer
                                     scanout (mod index 2)))
                            (event (cf.backend.drm:drm-scanout-present scanout buffer
                                                                      :timeout-ms 2000)))
                       (push event events)
                       (check (plusp (getf event :sequence))
                              "flip ~D was retired: sequence ~D at ~D.~6,'0D"
                              (1+ index) (getf event :sequence)
                              (getf event :tv-sec) (getf event :tv-usec))
                       (check (= crtc-id (getf event :crtc-id))
                              "flip ~D named our CRTC (~D)" (1+ index) crtc-id)
                       (check (= (1+ index) (getf event :user-data))
                              "flip ~D carried the user-data we sent"
                              (1+ index) (getf event :user-data))))
                   (let* ((ordered (nreverse events))
                          (sequences (mapcar (lambda (event) (getf event :sequence)) ordered))
                          (times (mapcar (lambda (event)
                                           (+ (getf event :tv-sec)
                                              (/ (getf event :tv-usec) 1000000.0)))
                                         ordered))
                          (elapsed (- (wayland.ffi:monotonic-seconds) start)))
                     (check (= 3 (length sequences)) "three flips were retired")
                     (check (equal sequences (sort (copy-list sequences) #'<))
                            "the sequence numbers only go forward: ~{~D~^, ~}" sequences)
                     (check (equal times (sort (copy-list times) #'<=))
                            "the vblank timestamps only go forward: ~{~,6F~^, ~}" times)
                     (check (plusp elapsed) "the three flips took ~,3F s" elapsed)
                     (check (= 3 (cf.backend.drm:drm-scanout-frames scanout))
                            "the scanout counted three completed frames")))
                 ))
        ;; --- give the card back -----------------------------------------------
        (when scanout
          (let ((condition (handler-case (progn (cf.backend.drm:drm-close-scanout scanout) nil)
                             (error (condition) condition))))
            (check (null condition) "closing the scanout restored and released: ~A"
                   (or condition "ok"))))
        (check (not (cf.backend.drm:drm-device-master-p device))
               "master was dropped")
        (when saved
          (let ((restored (cf.backend.drm:drm-crtc-state device (cf.backend.drm:drm-crtc-id saved))))
            (check (= (cf.backend.drm:drm-crtc-buffer-id saved)
                      (cf.backend.drm:drm-crtc-buffer-id restored))
                   "the CRTC scans out the framebuffer it did before (~D)"
                   (cf.backend.drm:drm-crtc-buffer-id restored))
            (check (equal (and (cf.backend.drm:drm-crtc-mode-valid-p saved)
                               (cf.backend.drm:drm-mode-name (cf.backend.drm:drm-crtc-mode saved)))
                          (and (cf.backend.drm:drm-crtc-mode-valid-p restored)
                               (cf.backend.drm:drm-mode-name (cf.backend.drm:drm-crtc-mode restored))))
                   "the CRTC is programmed with the mode it had before")))
        (when (cf.backend.drm:drm-device-open-p device)
          (cf.backend.drm:close-drm-device device))
        (check (not (cf.backend.drm:drm-device-open-p device)) "the descriptor is closed")
        (check (= descriptors-before (fd-count))
               "no descriptor leaked (~D before, ~D after)" descriptors-before (fd-count))
        (check (equal sysfs-before (cf.backend.drm:drm-sysfs-state card))
               "the kernel's connector state is identical to before the probe")
        (unless (equal sysfs-before (cf.backend.drm:drm-sysfs-state card))
          (note "before: ~S" sysfs-before)
          (note "after:  ~S" (cf.backend.drm:drm-sysfs-state card)))
        (finish "~A (~A) took master, set ~A, retired 3 page flips, restored the CRTC and dropped master"
                card (cf.backend.drm:drm-device-driver-name device)
                (and scanout (cf.backend.drm:drm-mode-name
                              (cf.backend.drm:drm-scanout-mode scanout))))))))
))