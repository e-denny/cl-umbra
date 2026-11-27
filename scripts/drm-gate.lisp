;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The DRM gate (clause 21): a real card, its connector, a mode, and a
;;;; scanout-sized dumb buffer -- without setcrtc and without DRM master (D54).
;;;;
;;;; Run by scripts/drm-gate.sh.  Exit status: 0 pass, 1 fail, 77 skip.  A skip
;;;; is "no card" or "this user was not given the card": EACCES is the difference
;;;; between not a DRM machine and not this user's session, and neither is a
;;;; failure of the code.
;;;;
;;;; What makes this a check rather than a rehearsal of our own arithmetic: the
;;;; kernel's view and libdrm's are compared to each other.  /sys/class/drm/
;;;; cardN-<connector>/{status,enabled,modes} is a second witness for the
;;;; connector list, the plug state and the mode table, and the uevent names the
;;;; driver independently of drmGetVersion.  The buffer half is checked through
;;;; the renderer that will draw the frame: pixels are painted into the dumb
;;;; buffer's mapping with pixman and read back, so a wrong pitch or a mapping
;;;; that is not the buffer shows up as a wrong pixel rather than as a quiet
;;;; success.
;;;;
;;;; What makes it safe to run on the machine someone is using: nothing here sets
;;;; a mode, flips a page, or asks to be master.  The probe proves that in the
;;;; only way a probe can -- the connector state from sysfs is identical before
;;;; and after, the device reports that it was never master, and the descriptor
;;;; count is flat.

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

(defparameter *checks* 0)
(defparameter *failures* 0)

(defun check (value description &rest arguments)
  "One assertion.  VALUE was already computed by the caller, in the caller's
scope, so a check cannot pass because its arguments were reassembled wrongly."
  (incf *checks*)
  (if value
      (format t "  ok   ~A~%" (apply #'format nil description arguments))
      (progn
        (incf *failures*)
        (format t "  FAIL ~A~%" (apply #'format nil description arguments)))))

(defun note (description &rest arguments)
  (format t "       ~A~%" (apply #'format nil description arguments)))

(defun skip (description &rest arguments)
  (format t "drm-gate: skip ~A~%" (apply #'format nil description arguments))
  (uiop:quit 77))

(defun finish (summary &rest arguments)
  (format t "~&drm-gate: ~D checks, ~D failed~%" *checks* *failures*)
  (if (plusp *failures*)
      (uiop:quit 1)
      (progn
        (format t "drm-gate: ~A~%" (apply #'format nil summary arguments))
        (uiop:quit 0))))

(defun fd-count ()
  (length (uiop:directory-files #p"/proc/self/fd/")))

(defun card-of (path)
  "The sysfs card name for a /dev/dri/cardN path."
  (file-namestring path))

(defun sysfs-sizes (strings)
  "Mode sizes from a sysfs modes file, with a trailing `i' removed.

sysfs prints an interlaced mode as 1920x1080i and one libdrm struct carries
hdisplay 1920, vdisplay 1080 and a flag, so the comparison has to be about the
size and not about the spelling."
  (mapcar (lambda (string)
            (if (uiop:string-suffix-p string "i")
                (subseq string 0 (1- (length string)))
                string))
          strings))

(defun probe-connector (device connector)
  "The dumb-buffer half for one connected connector: allocate at the mode it
would be programmed with, paint through the renderer, read back, add and remove a
framebuffer, and release everything."
  (let* ((name (cf.backend.drm:drm-connector-name connector))
         (mode (cf.backend.drm:drm-pick-mode connector))
         (width (cf.backend.drm:drm-mode-hdisplay mode))
         (height (cf.backend.drm:drm-mode-vdisplay mode))
         (buffer (cf.backend.drm:drm-create-dumb device width height)))
    (unwind-protect
         (progn
           (check (>= (cf.backend.drm:dumb-buffer-pitch buffer) (* 4 width))
                  "~A: a ~Dx~D dumb buffer has a pitch of at least 4 x ~D (~D)"
                  name width height width (cf.backend.drm:dumb-buffer-pitch buffer))
           (check (and (>= (cf.backend.drm:dumb-buffer-size buffer)
                           (cf.backend.drm:dumb-buffer-minimum-size buffer))
                       (< (cf.backend.drm:dumb-buffer-size buffer)
                          (* 1024 1024 512)))
                  "~A: ~D bytes, at least pitch x height and under half a gigabyte"
                  name (cf.backend.drm:dumb-buffer-size buffer))
           (cf.backend.drm:drm-map-dumb device buffer)
           (check (cf.backend.drm:dumb-buffer-mapped-p buffer) "~A: the buffer mapped" name)
           ;; Paint through the renderer that will draw the frame: a background,
           ;; then a rectangle at the origin.
           (let ((target (cf.render.pixman:make-target-over-pointer
                          (cf.backend.drm:dumb-buffer-mapping buffer)
                          width height
                          :stride (cf.backend.drm:dumb-buffer-pitch buffer))))
             (unwind-protect
                  (progn
                    (cf.render.pixman:fill-target target #xFF101820)
                    (cf.render.pixman:fill-rect target 0 0 64 48 #xFFFF8000))
               (cf.render.pixman:destroy-target target)))
           (check (= #xFFFF8000 (cf.backend.drm:dumb-buffer-pixel buffer 0 0))
                  "~A: pixel (0,0) is the rectangle we drew" name)
           (check (= #xFFFF8000 (cf.backend.drm:dumb-buffer-pixel buffer 63 47))
                  "~A: pixel (63,47) is inside it" name)
           (check (and (= #xFF101820 (cf.backend.drm:dumb-buffer-pixel buffer (1- width) (1- height)))
                       (= #xFF101820 (cf.backend.drm:dumb-buffer-pixel buffer 64 48)))
                  "~A: the last pixel (~D,~D) and the one past the rectangle are the background"
                  name (1- width) (1- height))
           (let ((id (cf.backend.drm:drm-add-framebuffer device buffer)))
             (check (plusp id) "~A: ADDFB named it framebuffer ~D" name id)
             (note "dumb buffer: ~Dx~D, pitch ~D, ~D bytes, framebuffer ~D"
                   width height (cf.backend.drm:dumb-buffer-pitch buffer)
                   (cf.backend.drm:dumb-buffer-size buffer) id))
           (cf.backend.drm:drm-remove-framebuffer device buffer)
           (check (not (cf.backend.drm:dumb-buffer-framebuffer-p buffer))
                  "~A: RMFB forgot it" name))
      (cf.backend.drm:drm-destroy-dumb device buffer)
      (check (and (not (cf.backend.drm:dumb-buffer-mapped-p buffer))
                  (not (cf.backend.drm:dumb-buffer-framebuffer-p buffer)))
             "~A: destroyed with neither a mapping nor a framebuffer left" name))))

(defun check-inventory (inventory sysfs-before)
  "Everything enumeration claims, checked against the kernel's own view."
  (let ((connectors (cf.backend.drm:drm-inventory-connectors inventory))
        (crtcs (cf.backend.drm:drm-inventory-crtcs inventory))
        (encoders (cf.backend.drm:drm-inventory-encoders inventory))
        (framebuffers (cf.backend.drm:drm-inventory-framebuffers inventory)))
    (check (and (plusp (length crtcs)) (plusp (length connectors)) (plusp (length encoders)))
           "~D CRTCs, ~D connectors, ~D encoders, ~D framebuffers"
           (length crtcs) (length connectors) (length encoders) (length framebuffers))
    (check (= (length sysfs-before) (length connectors))
           "every connector sysfs lists is in the inventory (~D)"
           (length connectors))

    (dolist (entry sysfs-before)
      (let* ((name (getf entry :name))
             (connector (cf.backend.drm:drm-inventory-connector inventory name)))
        (check (not (null connector)) "~A is in the inventory" name)
        (when connector
          (check (string= (cf.backend.drm:drm-connector-status-string connector)
                          (getf entry :status))
                 "~A: libdrm says ~A and /sys says ~A"
                 name (cf.backend.drm:drm-connector-status-string connector)
                 (getf entry :status))
          (check (integerp (cf.backend.drm:drm-connector-id connector))
                 "~A: has a kernel id (~D)" name (cf.backend.drm:drm-connector-id connector))
          (when (cf.backend.drm:drm-connector-connected-p connector)
            (let ((modes (cf.backend.drm:drm-connector-modes connector))
                  (sysfs-modes (getf entry :modes)))
              (check (plusp (length modes)) "~A is connected and offers ~D modes"
                     name (length modes))
              ;; The kernel's sysfs file prints the connector's whole mode table;
              ;; the GETCONNECTOR ioctl answers with the probed subset, which is
              ;; the smaller list.  So the count is bounded, and every mode we
              ;; were given has to be one the kernel also lists.
              (check (<= (length modes) (length sysfs-modes))
                     "~A: libdrm reports ~D of the ~D modes /sys lists"
                     name (length modes) (length sysfs-modes))
              (check (every (lambda (mode)
                              (member (format nil "~Dx~D"
                                              (cf.backend.drm:drm-mode-hdisplay mode)
                                              (cf.backend.drm:drm-mode-vdisplay mode))
                                      (sysfs-sizes sysfs-modes)
                                      :test #'string=))
                            modes)
                     "~A: every mode libdrm reports is a size /sys lists" name)
              ;; Totals must exceed the visible size in both directions, and a
              ;; clock must be there: a swapped or misread slot lands here.
              (check (every (lambda (mode)
                              (and (> (cf.backend.drm:drm-mode-htotal mode)
                                      (cf.backend.drm:drm-mode-hdisplay mode))
                                   (> (cf.backend.drm:drm-mode-vtotal mode)
                                      (cf.backend.drm:drm-mode-vdisplay mode))
                                   (plusp (cf.backend.drm:drm-mode-clock mode))))
                            modes)
                     "~A: every mode has totals larger than its size and a clock" name)
              (check (every (lambda (mode)
                              (< 20000 (cf.backend.drm:drm-mode-refresh-milli-hz mode) 240000))
                            modes)
                     "~A: every refresh is between 20 and 240 Hz" name)
              (let ((preferred (cf.backend.drm:drm-connector-preferred-mode connector)))
                (check (not (null preferred)) "~A nominates a preferred mode" name)
                (when preferred
                  (let ((size (format nil "~Dx~D"
                                      (cf.backend.drm:drm-mode-hdisplay preferred)
                                      (cf.backend.drm:drm-mode-vdisplay preferred))))
                    (note "preferred: ~A ~A, ~D kHz, ~,3F Hz"
                          (cf.backend.drm:drm-mode-name preferred) size
                          (cf.backend.drm:drm-mode-clock preferred)
                          (cf.backend.drm:drm-mode-refresh preferred))
                    (check (member size sysfs-modes :test #'string=)
                           "~A: the preferred mode (~A) is one /sys lists" name size)))))))))

    ;; Referential integrity: every id one object names is an object we
    ;; enumerated.  A wrong struct offset breaks this immediately.
    (check (every (lambda (connector)
                    (let ((id (cf.backend.drm:drm-connector-encoder-id connector)))
                      (or (zerop id)
                          (not (null (cf.backend.drm:drm-inventory-encoder inventory id))))))
                  connectors)
           "every connector's encoder id names an encoder we enumerated")
    (check (every (lambda (encoder)
                    (let ((id (cf.backend.drm:drm-encoder-crtc-id encoder)))
                      (or (zerop id)
                          (not (null (cf.backend.drm:drm-inventory-crtc inventory id))))))
                  encoders)
           "every encoder's CRTC id names a CRTC we enumerated")

    ;; What each CRTC is doing right now: read-only, and the state the next
    ;; slice has to put back before it gives the screen back.
    (dolist (crtc crtcs)
      (let ((mode (cf.backend.drm:drm-crtc-mode crtc)))
        (note "crtc ~D: framebuffer ~D, ~:[no valid mode~;~A, ~Dx~D~]"
              (cf.backend.drm:drm-crtc-id crtc)
              (cf.backend.drm:drm-crtc-buffer-id crtc)
              (and mode t)
              (and mode (cf.backend.drm:drm-mode-name mode))
              (cf.backend.drm:drm-crtc-width crtc)
              (cf.backend.drm:drm-crtc-height crtc))))
    (check (every (lambda (crtc)
                    (and (plusp (cf.backend.drm:drm-crtc-width crtc))
                         (plusp (cf.backend.drm:drm-crtc-height crtc))))
                  (remove-if-not #'cf.backend.drm:drm-crtc-mode-valid-p crtcs))
           "every CRTC with a valid mode reads as a non-empty size")))

;;; ---------------------------------------------------------------------------
;;; The probe
;;; ---------------------------------------------------------------------------

(let* ((paths (cf.backend.drm:drm-device-paths))
       (descriptors-before (fd-count))
       (candidates (loop for path in paths
                         for card = (card-of path)
                         for state = (cf.backend.drm:drm-sysfs-state card)
                         for connected = (find "connected" state
                                               :key (lambda (entry) (getf entry :status))
                                               :test #'string=)
                         when connected collect (list path card state))))
  (unless candidates
    (skip "no /dev/dri/card* with a connected connector~@[ (cards: ~{~A~^, ~})~]"
          paths))
  (destructuring-bind (path card sysfs-before) (first candidates)
    (note "card ~A (~A): ~{~A~^, ~}"
          card path
          (loop for entry in sysfs-before
                collect (format nil "~A ~A" (getf entry :name) (getf entry :status))))

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
                            (finish "opening the card failed")))))))
      (let ((connected-count 0))
        (unwind-protect
             (progn
               (check (plusp (length (cf.backend.drm:drm-device-driver-name device)))
                      "the driver is named: ~A" (cf.backend.drm:drm-device-driver-name device))
               (note "version ~A, capabilities ~S"
                     (cf.backend.drm:drm-device-version device)
                     (cf.backend.drm:drm-device-capabilities device))
               (check (= 3 (length (uiop:split-string (cf.backend.drm:drm-device-version device)
                                                      :separator ".")))
                      "the DRM version is major.minor.patch: ~A"
                      (cf.backend.drm:drm-device-version device))
               (check (string= (cf.backend.drm:drm-device-driver-name device)
                               (cf.backend.drm:drm-sysfs-driver-name card))
                      "the driver name matches /sys: ~A" (cf.backend.drm:drm-sysfs-driver-name card))
               (check (null (cf.backend.drm:drm-device-master-p device))
                      "the card was opened without DRM master")
               (check (getf (cf.backend.drm:drm-device-capabilities device) :dumb-buffer)
                      "the driver has dumb buffers, which is the whole point")
               (check (getf (cf.backend.drm:drm-device-capabilities device) :prime)
                      "and PRIME, so a GPU path in phase 5 has something to import")

               (let* ((inventory (cf.backend.drm:drm-inventory device))
                      (connectors (cf.backend.drm:drm-inventory-connected-connectors inventory)))
                 (setf connected-count (length connectors))
                 (check-inventory inventory sysfs-before)
                 (dolist (connector connectors)
                   (probe-connector device connector))))
          (cf.backend.drm:close-drm-device device))

        (check (not (cf.backend.drm:drm-device-open-p device)) "the descriptor is closed")
        (check (null (cf.backend.drm:drm-device-master-p device))
               "the device was never master, so it never touched the screen")
        (check (= descriptors-before (fd-count))
               "no descriptor leaked (~D before, ~D after)" descriptors-before (fd-count))
        (check (equal sysfs-before (cf.backend.drm:drm-sysfs-state card))
               "the kernel's connector state is identical to before the probe")
        (unless (equal sysfs-before (cf.backend.drm:drm-sysfs-state card))
          (note "before: ~S" sysfs-before)
          (note "after:  ~S" (cf.backend.drm:drm-sysfs-state card)))
        (finish "~A enumerated, ~D connector(s) buffered, no mode set, nothing on screen changed"
                card connected-count)))))
