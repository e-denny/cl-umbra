;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The frame that goes into the scanout: a padded pitch, and the cursor in it (D58).
;;;;
;;;; No card is opened here.  A dumb buffer is a width, a height, a pitch and a
;;;; mapping, and the only thing about it that the renderer reads is the pitch -- so
;;;; these tests build one over a memfd, deliberately *padded*, and check the two
;;;; claims the slice makes:
;;;;
;;;;   * the picture is the same whatever the pitch, so a driver that pads is not a
;;;;     driver that shears;
;;;;   * the cursor is in the frame where the scene puts it, which is what "software
;;;;     cursor in the scanout" means -- there is no cursor plane in this design.
;;;;
;;;; And the negatives: nothing outside the buffer's own rows is written (padding is
;;;; somebody else's memory in principle, and D55's fill-rect bug was a write before a
;;;; mapping), and a damaged frame does not repaint what it did not damage (D50).

(in-package #:cl-user)

(defpackage #:wayland.test.drm-frame
  (:use #:cl #:rove)
  (:local-nicknames (#:drm #:cf.backend.drm)
                    (#:ffi #:wayland.ffi)
                    (#:render #:cf.render.pixman)
                    (#:scene #:cf.scene))
  (:documentation "Rendering a scene -- cursor included -- into a padded scanout
buffer (D58)."))

(in-package #:wayland.test.drm-frame)

;;; ---------------------------------------------------------------------------
;;; A buffer with a padded pitch, over memory we own
;;; ---------------------------------------------------------------------------

(defstruct (mapping (:constructor %make-mapping))
  pointer fd size)

(defun make-mapping (size)
  (let ((fd (ffi:memfd-create "cl-wayland-scanout-test")))
    (unwind-protect
         (progn
           (ffi:set-file-size fd size)
           (let ((pointer (ffi:map-file fd size :protection (logior ffi:+prot-read+ ffi:+prot-write+))))
             (%make-mapping :pointer pointer :fd fd :size size)))
      (ffi:close-fd fd))))

(defun free-mapping (mapping)
  (unless (cffi:null-pointer-p (mapping-pointer mapping))
    (ffi:unmap-file (mapping-pointer mapping) (mapping-size mapping))
    (setf (mapping-pointer mapping) (cffi:null-pointer))))

(defun make-scanout-buffer (width height padding)
  "A DUMB-BUFFER over a memfd, with PADDING bytes at the end of every row.

A real dumb buffer comes from the driver; nothing in the renderer looks at the
device, so a buffer with no device is the honest fake -- and the padding is the
point, because the driver is allowed to pad even where this card does not."
  (let* ((pitch (+ (* width 4) padding))
         (mapping (make-mapping (* pitch height)))
         (buffer (make-instance 'drm:dumb-buffer
                                :width width :height height
                                :bits-per-pixel 32
                                :handle 0
                                :pitch pitch
                                :size (* pitch height))))
    (setf (drm:dumb-buffer-mapping buffer) (mapping-pointer mapping))
    (values buffer mapping pitch)))

(defmacro with-scanout-buffer ((buffer mapping pitch width height &key (padding 64)) &body body)
  `(multiple-value-bind (,buffer ,mapping ,pitch)
       (make-scanout-buffer ,width ,height ,padding)
     (unwind-protect (progn ,@body)
       (free-mapping ,mapping))))

(defun sentinel (mapping)
  (loop for index below (mapping-size mapping)
        do (setf (cffi:mem-aref (mapping-pointer mapping) :unsigned-char index) #x5A)))

(deftest the-fake-buffer-is-what-the-tests-think-it-is
  ;; A test fixture that is wrong about its own geometry makes every assertion below
  ;; meaningless, so the fixture is checked too.
  (with-scanout-buffer (buffer mapping pitch 32 8 :padding 16)
    (ok (= 144 pitch) "pitch = width * 4 + padding")
    (ok (= (* pitch 8) (drm:dumb-buffer-size buffer)))
    (ok (not (cffi:null-pointer-p (drm:dumb-buffer-mapping buffer))))))

(defun scene-with-cursor (width height &key (x 40) (y 24) (scale 1))
  (let ((scene (scene:make-scene width height :scale scale)))
    (setf (scene:scene-cursor-visible-p scene) t)
    (scene:set-node-position (scene:scene-cursor scene) x y)
    scene))

;;; ---------------------------------------------------------------------------
;;; The picture does not depend on the pitch
;;; ---------------------------------------------------------------------------

(deftest a-padded-scanout-draws-the-same-pixels-as-a-packed-one
  ;; The same scene into two buffers: one whose pitch is width * 4 and one with 16
  ;; bytes of padding per row.  Every visible pixel must be identical.  If the
  ;; renderer assumed width * 4, the second picture would be a sheared copy of the
  ;; first -- the stride bug that looks like a rendering bug.
  (let ((width 64) (height 40))
    (with-scanout-buffer (padded padded-mapping padded-pitch width height :padding 16)
      (multiple-value-bind (packed packed-mapping packed-pitch)
          (make-scanout-buffer width height 0)
        (declare (ignore packed-pitch))
        (unwind-protect
             (let ((scene (scene-with-cursor width height)))
               (drm:drm-scanout-render nil scene packed)
               (drm:drm-scanout-render nil scene padded)
               (let ((differences
                       (loop for y below height
                             sum (loop for x below width
                                       count (/= (cffi:mem-aref (drm:dumb-buffer-mapping packed)
                                                                :uint32 (+ (* y width) x))
                                                 (cffi:mem-aref (drm:dumb-buffer-mapping padded)
                                                                :uint32 (+ (* y (/ padded-pitch 4)) x)))))))
                 (ok (zerop differences)
                     (format nil "~D x ~D pixels agree between the packed and padded buffers (~D differ)"
                             width height differences))))
          (free-mapping packed-mapping))))))

;;; ---------------------------------------------------------------------------
;;; The cursor is in the frame
;;; ---------------------------------------------------------------------------

(deftest the-cursor-lands-where-the-scene-put-it
  ;; The pointer is drawn by the scene, last, into the scanout mapping.  So after a
  ;; full frame, the pixels the built-in arrow covers are not the background, they are
  ;; inside the 16x16 box the scene positioned, and a pixel well away from the
  ;; pointer is still the background.
  (with-scanout-buffer (buffer mapping pitch 64 40 :padding 16)
    (let* ((scene (scene-with-cursor 64 40 :x 20 :y 10))
           (inside 0))
      (sentinel mapping)
      (drm:drm-scanout-render nil scene buffer :background #xFF000000)
      (loop for y from 10 below 26
            do (loop for x from 20 below 36
                     unless (= #xFF000000 (cffi:mem-aref (mapping-pointer mapping) :uint32
                                                          (+ (* y (/ pitch 4)) x)))
                       do (incf inside)))
      (ok (plusp inside)
          (format nil "~D pixel(s) inside the pointer's box are painted" inside))
      (ok (= #xFF000000 (cffi:mem-aref (mapping-pointer mapping) :uint32 (+ (* 2 (/ pitch 4)) 2)))
          "a pixel away from the pointer is still the background"))))

(deftest the-cursor-is-drawn-last-and-at-device-scale
  ;; At scale 2 the same scene puts a 32x32 arrow on device pixels.  That is the
  ;; compositor's existing rule (D40); what this asserts is that it survives the trip
  ;; into a scanout buffer, because the cursor is not a separate plane with its own
  ;; scale setting.
  (with-scanout-buffer (buffer mapping pitch 64 40 :padding 16)
    (let* ((scene (scene-with-cursor 32 20 :x 5 :y 5 :scale 2))
           (painted 0))
      (sentinel mapping)
      (drm:drm-scanout-render nil scene buffer :background #xFF000000)
      (loop for y from 5 below 37
            do (loop for x from 5 below 37
                     unless (= #xFF000000 (cffi:mem-aref (mapping-pointer mapping) :uint32
                                                          (+ (* y (/ pitch 4)) x)))
                       do (incf painted)))
      (ok (plusp painted)
          (format nil "the cursor at scale 2 paints device pixels (~D of the 32x32 box)" painted)))))

;;; ---------------------------------------------------------------------------
;;; Nothing outside the buffer's rows is written
;;; ---------------------------------------------------------------------------

(deftest the-padding-and-the-tail-are-untouched
  ;; Padding is not ours to write, and neither is anything past the last row.  The
  ;; cursor is put at the bottom-right corner so that the frame's most extreme write
  ;; is the one being tested.
  (with-scanout-buffer (buffer mapping pitch 64 40 :padding 16)
    (let ((scene (scene-with-cursor 64 40 :x 56 :y 32)))
      (sentinel mapping)
      (drm:drm-scanout-render nil scene buffer)
      (let ((touched (loop for y below 40
                           count (/= #x5A (cffi:mem-aref (mapping-pointer mapping)
                                                         :unsigned-char
                                                         (+ (* y pitch) (* 64 4)))))))
        (ok (zerop touched)
            (format nil "the padding at the end of every row is untouched (~D rows written)" touched)))
      (ok (/= #x5A (cffi:mem-aref (mapping-pointer mapping) :unsigned-char 0))
          "the first visible byte was written, so the check is not vacuous"))))

;;; ---------------------------------------------------------------------------
;;; Damage confines the repaint
;;; ---------------------------------------------------------------------------

(deftest a-damaged-frame-repaints-only-its-damage
  ;; A damaged frame does not paint the background, or buffer age stops meaning
  ;; anything (D50).  Sentinel everywhere, damage a 8x8 rectangle, and check that the
  ;; write stayed inside it -- with the cursor parked far away.
  (with-scanout-buffer (buffer mapping pitch 64 40 :padding 16)
    (let ((scene (scene-with-cursor 64 40 :x 56 :y 32))
          (damage (render:make-region)))
      (unwind-protect
           (progn
             (sentinel mapping)
             (render:region-add-box damage (list 56 32 8 8))
             (drm:drm-scanout-render nil scene buffer :damage damage)
             (let ((outside
                     (loop for y below 40
                           sum (loop for x below 64
                                     unless (and (<= 56 x) (< x 64) (<= 32 y) (< y 40))
                                       count (/= #x5A (cffi:mem-aref (mapping-pointer mapping)
                                                                     :unsigned-char
                                                                     (+ (* y pitch) (* x 4))))))))
               (ok (zerop outside)
                   (format nil "no byte outside the damaged rectangle was written (~D were)" outside))
               (ok (loop for y from 32 below 40
                         thereis (loop for x from 56 below 64
                                       thereis (/= #x5A (cffi:mem-aref (mapping-pointer mapping)
                                                                       :unsigned-char
                                                                       (+ (* y pitch) (* x 4))))))
                   "and the damage under the cursor was repainted")))
        (render:destroy-region damage)))))
