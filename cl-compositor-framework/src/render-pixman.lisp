;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The pixman renderer: the reference (docs/memory-and-rendering.md §6-§7).
;;;;
;;;; Everything here is libpixman through CFFI -- CPU compositing, no EGL, no GPU
;;;; (D3: shm first, pixman as the definition of correct).  A target is a pixman
;;;; image over a Lisp octet vector; a source is a pixman image over the client's
;;;; wl_shm buffer, read in place.  Nothing is copied per frame unless the
;;;; platform makes us.

(in-package #:cf.render.pixman)

;;; ---------------------------------------------------------------------------
;;; The library
;;; ---------------------------------------------------------------------------
;;
;; CFFI does not load a library because a DEFCFUN mentions it, so say it once,
;; here: libpixman is a leaf dependency of the reference renderer (D3), and it is
;; loaded by this system and nothing else.

(cffi:define-foreign-library libpixman
  (:unix (:or "libpixman-1.so.0" "libpixman-1.so")))

(cffi:use-foreign-library libpixman)

;;; ---------------------------------------------------------------------------
;;; pixman, by hand
;;; ---------------------------------------------------------------------------
;;
;; The format codes are pixman's `PIXMAN_FORMAT(bpp, type, a, r, g, b)' macro,
;; spelled out so the arithmetic can be checked against the header:
;;
;;   0x20028888 = (32 << 24) | (ARGB << 16) | (8 << 12) | (8 << 8) | (8 << 4) | 8
;;
;; a8r8g8b8 is what wl_shm calls ARGB8888 in memory: the 32-bit word is
;; 0xAARRGGBB, which little-endian stores as B, G, R, A.

(defconstant +format-a8r8g8b8+ #x20028888)
(defconstant +format-x8r8g8b8+ #x20020888)

(defconstant +op-src+ 1)
(defconstant +op-over+ 3)

(cffi:defcfun ("pixman_image_create_bits" %create-bits) :pointer
  (format :unsigned-int) (width :int) (height :int) (bits :pointer) (stride :int))

(cffi:defcfun ("pixman_image_unref" %image-unref) :int
  (image :pointer))

(cffi:defcfun ("pixman_image_composite32" %composite32) :void
  (op :unsigned-int)
  (source :pointer) (mask :pointer) (destination :pointer)
  (source-x :int) (source-y :int)
  (mask-x :int) (mask-y :int)
  (destination-x :int) (destination-y :int)
  (width :int) (height :int))

(defun pixman-format-for-shm (shm-format)
  "The pixman format code for a wl_shm format, or NIL if we do not render it."
  (declare (type integer shm-format))
  (cond ((= shm-format 0) +format-a8r8g8b8+)   ; argb8888, premultiplied
        ((= shm-format 1) +format-x8r8g8b8+)   ; xrgb8888, opaque
        (t nil)))

(defun op-for-shm-format (shm-format)
  "SRC for opaque content into a cleared target, OVER for anything with alpha.

Getting this the other way round is both slower and, for XRGB sources, wrong:
the x bits are undefined and OVER would blend them."
  (if (= shm-format 1) +op-src+ +op-over+))

;;; ---------------------------------------------------------------------------
;;; Targets
;;; ---------------------------------------------------------------------------

(defstruct (target (:constructor %make-target (octets width height stride image)))
  ;; A simple octet vector, so it can be pinned and handed to pixman directly.
  (octets #() :type (simple-array (unsigned-byte 8) (*)))
  (width 0 :type fixnum)
  (height 0 :type fixnum)
  (stride 0 :type fixnum)
  (image (cffi:null-pointer) :type cffi:foreign-pointer))

(defun make-target (width height)
  "A cleared ARGB8888 target of WIDTH x HEIGHT."
  (let* ((stride (* width 4))
         (octets (make-array (* stride height) :element-type '(unsigned-byte 8)
                                             :initial-element 0))
         (image (cffi:with-pointer-to-vector-data (pointer octets)
                  (%create-bits +format-a8r8g8b8+ width height pointer stride))))
    (when (cffi:null-pointer-p image)
      (error "pixman_image_create_bits failed for ~Dx~D" width height))
    (%make-target octets width height stride image)))

(defun fill-target (target argb)
  "Fill TARGET with a premultiplied 0xAARRGGBB colour, the way pixman would."
  (let ((octets (target-octets target))
        (b (ldb (byte 8 0) argb))
        (g (ldb (byte 8 8) argb))
        (r (ldb (byte 8 16) argb))
        (a (ldb (byte 8 24) argb)))
    (loop for index from 0 below (length octets) by 4
          do (setf (aref octets index) b
                   (aref octets (+ index 1)) g
                   (aref octets (+ index 2)) r
                   (aref octets (+ index 3)) a))
    target))

(declaim (inline target-pixel))
(defun target-pixel (target x y)
  "The premultiplied 0xAARRGGBB pixel at X, Y, read straight from the target."
  (let ((offset (+ (* y (target-stride target)) (* x 4)))
        (octets (target-octets target)))
    (logior (aref octets offset)
            (ash (aref octets (+ offset 1)) 8)
            (ash (aref octets (+ offset 2)) 16)
            (ash (aref octets (+ offset 3)) 24))))

(defun (setf target-pixel) (argb target x y)
  (let ((offset (+ (* y (target-stride target)) (* x 4)))
        (octets (target-octets target)))
    (setf (aref octets offset) (ldb (byte 8 0) argb)
          (aref octets (+ offset 1)) (ldb (byte 8 8) argb)
          (aref octets (+ offset 2)) (ldb (byte 8 16) argb)
          (aref octets (+ offset 3)) (ldb (byte 8 24) argb)))
  argb)

;;; ---------------------------------------------------------------------------
;;; Sources: wl_shm buffers, read in place
;;; ---------------------------------------------------------------------------

(defun buffer-image (buffer)
  "A pixman image over a wl_shm buffer's pixels, or NIL for a format we cannot draw.

The image borrows the pool's mapping; it must be unref'd before the buffer dies,
which RENDER-SURFACE guarantees by unref'ing in its own unwind-protect."
  (let ((format (pixman-format-for-shm (wayland.server:shm-buffer-format buffer))))
    (and format
         (%create-bits format
                       (wayland.server:shm-buffer-width buffer)
                       (wayland.server:shm-buffer-height buffer)
                       (wayland.server:shm-buffer-pointer buffer)
                       (wayland.server:shm-buffer-stride buffer)))))

(defun composite-buffer (target buffer &key (x 0) (y 0) (width nil) (height nil))
  "Draw BUFFER onto TARGET at X, Y.  Returns true when it was drawn.

Clipping is the target's job: pixman clips to the destination image, so a window
hanging off the edge simply loses the outside part."
  (let ((image (buffer-image buffer)))
    (unless image
      (return-from composite-buffer nil))
    (unwind-protect
         (progn
           (%composite32 (op-for-shm-format (wayland.server:shm-buffer-format buffer))
                         image (cffi:null-pointer) (target-image target)
                         0 0 0 0 x y
                         (or width (wayland.server:shm-buffer-width buffer))
                         (or height (wayland.server:shm-buffer-height buffer)))
           t)
      (%image-unref image))))

(defun render-surface (target surface)
  "Draw SURFACE at its committed position; returns true when something was drawn.

A surface with no buffer is not drawn at all -- attach(nil) means hidden, and a
client that only moves its buffer commits position without content."
  (let ((buffer (wayland.server:surface-current-buffer surface)))
    (when (and buffer (wayland.server:surface-mapped-p surface))
      (composite-buffer target buffer
                        :x (wayland.server:surface-current-x surface)
                        :y (wayland.server:surface-current-y surface)))))
