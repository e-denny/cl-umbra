;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; A visible page-flip demo: two dumb buffers, a frame painted into whichever one
;;;; the display is not reading, a page flip, and a wait for the kernel's vblank
;;;; (D55).
;;;;
;;;; Run by scripts/drm-demo.sh, which explains the flags.  This is the smallest
;;;; program that uses the screen half of cf.backend.drm the way a compositor will:
;;;; open a scanout (which takes master and saves the CRTC), paint through the
;;;; renderer, flip, wait, and close (which restores the CRTC and drops master).
;;;;
;;;; The picture is deliberately boring and deliberately diagnosable: a band that
;;;; sweeps once per second, a block whose height is the frame number modulo the
;;;; screen, and the frame number drawn in binary as sixteen squares.  A frame that
;;;; was retired but never shown, or a flip that silently reused a buffer, changes
;;;; what those squares say.
;;;;
;;;; Exits 0 after the requested frames, 2 when there is no card it is willing to
;;;; take, 1 when something failed.  The CRTC is restored on the way out of every
;;;; path this program controls; a SIGKILL is the only way to leave it set, which
;;;; on a virtual card costs nothing and on a real one is why the last paragraph of
;;;; the demo prints what the saved state was.

(asdf:load-system "cl-compositor-framework")

(in-package #:cl-user)

;;; ---------------------------------------------------------------------------
;;; What was asked for
;;; ---------------------------------------------------------------------------

(defun environment-integer (name default)
  (let ((text (uiop:getenv name)))
    (if (and text (plusp (length text)))
        (or (parse-integer text :junk-allowed t) default)
        default)))

(defun split-mode (text)
  "`WxH' as (values W H), or NIL when TEXT is not a size."
  (when text
    (let ((at (position #\x text)))
      (when at
        (list (parse-integer text :end at :junk-allowed t)
              (parse-integer text :start (1+ at) :junk-allowed t))))))

(defun demo-card ()
  "The card to take, or NIL with a reason printed.

A virtual card is always allowed.  A real one only when this program was told
which one *and* that it may: two settings, because taking a screen is a decision
and not a default."
  (let ((named (uiop:getenv "CL_DRM_DEMO_CARD"))
        (paths (cf.backend.drm:drm-device-paths)))
    (flet ((allowed (path)
             (let ((driver (handler-case (cf.backend.drm:drm-driver-at path)
                             (cf.backend.drm:drm-error () nil))))
               (cond ((cf.backend.drm:drm-virtual-driver-p driver) t)
                     ((and named (equal named path)
                           (equal (uiop:getenv "CL_DRM_MODESET_ALLOW") "1"))
                      t)
                     (t nil)))))
      (cond ((null paths)
             (format t "~&drm-demo: there is no /dev/dri/card*~%")
             nil)
            (named
             (unless (member named paths :test #'equal)
               (format t "~&drm-demo: ~A is not one of ~{~A~^, ~}~%" named paths))
             (if (allowed named)
                 named
                 (progn
                   (format t "~&drm-demo: ~A is a real card: set CL_DRM_MODESET_ALLOW=1 to take its screen~%"
                           named)
                   nil)))
            (t
             (or (find-if #'allowed paths)
                 (progn
                   (format t "~&drm-demo: no virtual KMS card among ~{~A~^, ~}; ~
                             load it with `sudo modprobe vkms' (or name a card with --card ~
                             and allow it)~%"
                           paths)
                   nil)))))))

;;; ---------------------------------------------------------------------------
;;; The picture
;;; ---------------------------------------------------------------------------

(defun draw-frame (target frame width height)
  "Paint frame number FRAME of the animation into TARGET."
  (cf.render.pixman:fill-target target #xFF0A0A12)
  ;; A band that sweeps left to right once a second at 60 Hz.
  (let* ((period 60)
         (phase (mod frame period))
         (x (- (round (* phase (- width 140)) (1- period)))))
    (cf.render.pixman:fill-rect target x 0 140 height #xFF14243C))
  ;; A block whose vertical position is the frame number: smooth motion, and a
  ;; stall anywhere in the loop shows as a jump.
  (let ((y (mod (* frame 3) (max 1 (- height 64)))))
    (cf.render.pixman:fill-rect target (- width 180) y 64 64 #xFF00C060))
  ;; The frame number in binary, sixteen squares, top left.  Bit 0 is on the left
  ;; so the picture counts up as the squares fill in.
  (dotimes (bit 16)
    (let ((on (logbitp bit frame)))
      (cf.render.pixman:fill-rect target (+ 8 (* bit 22)) 8 18 18
                                  (if on #xFFFFB000 #xFF2A2A35))))
  ;; A progress bar along the bottom, so a run that stops early looks stopped.
  (cf.render.pixman:fill-rect target 8 (- height 12) (- width 16) 4 #xFF2A2A35))

(defun draw-tear-frame (target frame width height)
  "One of two flat pictures, for a tear test; FRAME is 0 or 1.

Two flat greys and nothing else, because every other picture has a feature that a
person can mistake for a seam.  A vertical boundary can only move horizontally, so a
tear shows up in it as a step; a *flat* field has no feature at all, so the only thing
that can appear on the screen is an edge between the two greys -- which is a tear, or
a scanout that switched at a vblank.  Greys rather than black and white because a
60 Hz alternation of white and black is a strobe, and this test asks somebody to look
at it for ten seconds."
  (declare (ignore width height))
  (cf.render.pixman:fill-target target (if (zerop frame) #xFF5A5A5A #xFFA5A5A5))
  target)

(defun target-for (buffer)
  (cf.render.pixman:make-target-over-pointer
   (cf.backend.drm:dumb-buffer-mapping buffer)
   (cf.backend.drm:dumb-buffer-width buffer)
   (cf.backend.drm:dumb-buffer-height buffer)
   :stride (cf.backend.drm:dumb-buffer-pitch buffer)))

;;; ---------------------------------------------------------------------------
;;; Running it
;;; ---------------------------------------------------------------------------

(defun report-run (frames intervals sequences)
  (let* ((count (length intervals))
         (mean (if (plusp count) (/ (reduce #'+ intervals) count) 0))
         (fastest (if (plusp count) (reduce #'min intervals) 0))
         (slowest (if (plusp count) (reduce #'max intervals) 0)))
    (format t "~&drm-demo: ~D frames flipped~%" frames)
    (format t "drm-demo: interval mean ~,2F ms (fastest ~,2F, slowest ~,2F), ~,1F Hz~%"
            (* 1000 mean) (* 1000 fastest) (* 1000 slowest)
            (if (plusp mean) (/ 1 mean) 0))
    (format t "drm-demo: sequences ~D to ~D, ~:[not ~;~]monotonic~%"
            (or (first sequences) 0) (or (car (last sequences)) 0)
            (equal sequences (sort (copy-list sequences) #'<)))))

(defun run-demo ()
  (let* ((path (demo-card))
         (frames (max 1 (environment-integer "CL_DRM_DEMO_FRAMES" 300)))
         (requested (split-mode (uiop:getenv "CL_DRM_DEMO_MODE")))
         (tear-p (member (uiop:getenv "CL_DRM_DEMO_TEAR") '("1" "yes" "true")
                         :test #'string-equal))
         (connector-name (uiop:getenv "CL_DRM_DEMO_CONNECTOR"))
         (device nil)
         (scanout nil)
         (targets '())
         (intervals '())
         (sequences '()))
    (unless path
      (uiop:quit 2))
    (setf device (cf.backend.drm:open-drm-device path))
    (let* ((inventory (cf.backend.drm:drm-inventory device))
           (connector (if connector-name
                          (or (cf.backend.drm:drm-inventory-connector inventory connector-name)
                              (error "no connector called ~A" connector-name))
                          (or (first (cf.backend.drm:drm-inventory-connected-connectors inventory))
                              (error "no connector is connected"))))
           (mode (cond ((null requested)
                        (cf.backend.drm:drm-pick-mode connector))
                       (t
                        (or (cf.backend.drm:drm-pick-mode connector
                                                          :width (first requested)
                                                          :height (second requested))
                            (cf.backend.drm:drm-pick-mode connector))))))
      (format t "~&drm-demo: ~A (~A), connector ~A, mode ~A ~Dx~D at ~,2F Hz~%"
              path (cf.backend.drm:drm-device-driver-name device)
              (cf.backend.drm:drm-connector-name connector)
              (cf.backend.drm:drm-mode-name mode)
              (cf.backend.drm:drm-mode-hdisplay mode)
              (cf.backend.drm:drm-mode-vdisplay mode)
              (cf.backend.drm:drm-mode-refresh mode))
      (unwind-protect
           (progn
             (setf scanout (handler-case
                               (cf.backend.drm:drm-open-scanout
                                device :connector connector :mode mode)
                             (cf.backend.drm:drm-error (condition)
                               (format t "~&drm-demo: ~A~%~
                                         drm-demo: DRM master is a privileged operation: run this as root (sudo), ~
                                         or from a session that owns the seat~%"
                                       condition)
                               (uiop:quit 2))))
             (format t "drm-demo: took master (the CRTC was scanning framebuffer ~D)~%"
                     (cf.backend.drm:drm-crtc-buffer-id
                      (cf.backend.drm:drm-scanout-saved-state scanout)))
             (setf targets (map 'list #'target-for (cf.backend.drm:drm-scanout-buffers scanout)))
             (let ((width (cf.backend.drm:drm-scanout-width scanout))
                   (height (cf.backend.drm:drm-scanout-height scanout)))
               ;; Two buffers, two pictures, painted once: the tear test then only
               ;; flips, so nothing but the scanout can put a seam on the glass.
               (when tear-p
                 (draw-tear-frame (first targets) 0 width height)
                 (draw-tear-frame (second targets) 1 width height)
                 (format t "~&drm-demo: tear test: two flat greys, ~D flips.  ~
A horizontal edge between the greys is a tear; a uniform field that only changes
shade is a scanout that switches at a vblank.~%" frames))
               (loop for frame below frames
                     ;; The buffer the display is NOT reading (D65).  Not FRAME mod
                     ;; the count: at open the CRTC is programmed with buffer 0, so a
                     ;; count from zero draws the first frame into the buffer being
                     ;; scanned -- a tear on the first frame of every run.
                     for buffer = (cf.backend.drm:drm-scanout-next-buffer scanout)
                     for buffer-index = (position buffer
                                                  (cf.backend.drm:drm-scanout-buffers scanout))
                     for started = (wayland.ffi:monotonic-seconds)
                     do (progn
                          (unless tear-p
                            (draw-frame (nth buffer-index targets) frame width height))
                          (let ((event (cf.backend.drm:drm-scanout-present scanout buffer)))
                            (push (- (wayland.ffi:monotonic-seconds) started) intervals)
                            (push (getf event :sequence) sequences))
                          (when (zerop (mod (1+ frame) 30))
                            (format t "drm-demo: frame ~D/~D, sequence ~D, interval ~,2F ms~%"
                                    (1+ frame) frames (first sequences)
                                    (* 1000 (first intervals)))))))
             (report-run frames (nreverse intervals) (nreverse sequences)))
        (when scanout
          (handler-case (cf.backend.drm:drm-close-scanout scanout)
            (error (condition)
              (format t "~&drm-demo: closing the scanout failed: ~A~%" condition)
              (uiop:quit 1))))
        (mapc #'cf.render.pixman:destroy-target targets)
        (when scanout
          (let ((restored (cf.backend.drm:drm-crtc-state
                           device (cf.backend.drm:drm-scanout-crtc-id scanout))))
            (format t "drm-demo: restored the CRTC to framebuffer ~D, ~:[off~;~A~]; master dropped: ~:[no~;yes~]~%"
                    (cf.backend.drm:drm-crtc-buffer-id restored)
                    (cf.backend.drm:drm-crtc-mode-valid-p restored)
                    (and (cf.backend.drm:drm-crtc-mode restored)
                         (cf.backend.drm:drm-mode-name (cf.backend.drm:drm-crtc-mode restored)))
                    (not (cf.backend.drm:drm-device-master-p device)))))
        (cf.backend.drm:close-drm-device device)))))

(run-demo)
(uiop:quit 0)
