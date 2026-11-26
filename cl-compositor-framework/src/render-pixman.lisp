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

(defstruct (target (:constructor %make-target (pointer width height stride image
                                                         &aux (owned-p nil))))
  ;; The pixels live in foreign memory, never in a Lisp vector.  pixman keeps the
  ;; address for the image's whole life, and SBCL's GC may move a vector that has
  ;; been handed out as a SAP (found the hard way: a full GC between creating the
  ;; target and drawing turned every frame into background).  A wl_shm mapping and
  ;; a headless target are therefore the same shape -- someone else's memory that
  ;; nothing in Lisp moves -- and readback copies.
  (pointer (cffi:null-pointer) :type cffi:foreign-pointer)
  (width 0 :type fixnum)
  (height 0 :type fixnum)
  (stride 0 :type fixnum)
  (image (cffi:null-pointer) :type cffi:foreign-pointer)
  ;; True only for a target that allocated its own pixels, so DESTROY-TARGET knows
  ;; whether freeing the pointer would free someone else's mapping.
  (owned-p nil :type boolean))

(defun make-target (width height)
  "A cleared ARGB8888 target of WIDTH x HEIGHT, in allocated foreign memory."
  (let* ((stride (* width 4))
         (size (* stride height))
         (pointer (cffi:foreign-alloc :unsigned-char :count size :initial-element 0))
         (image (%create-bits +format-a8r8g8b8+ width height pointer stride)))
    (unless image
      (cffi:foreign-free pointer)
      (error "pixman_image_create_bits failed for ~Dx~D" width height))
    (let ((target (%make-target pointer width height stride image)))
      (setf (target-owned-p target) t)
      target)))

(defun make-target-over-pointer (pointer width height &key (stride (* width 4)))
  "An ARGB8888 target over memory someone else owns (a wl_shm mapping).

The caller keeps the memory alive and of the stated stride for as long as the
target is drawn into; nothing is copied and nothing is unmapped or freed here."
  (unless (plusp width)
    (error "a target needs a positive width, got ~S" width))
  (let ((image (%create-bits +format-a8r8g8b8+ width height pointer stride)))
    (when (cffi:null-pointer-p image)
      (error "pixman_image_create_bits failed for ~Dx~D over a mapping" width height))
    (%make-target pointer width height stride image)))

(defun destroy-target (target)
  "Unref the image, and free the pixels when this target allocated them.

A target made over a wl_shm mapping (nested) releases only its pixman image: the
mapping belongs to the pool.  A second call is a no-op."
  (unless (cffi:null-pointer-p (target-image target))
    (%image-unref (target-image target))
    (setf (target-image target) (cffi:null-pointer)))
  (when (and (target-owned-p target)
             (not (cffi:null-pointer-p (target-pointer target))))
    (cffi:foreign-free (target-pointer target))
    (setf (target-pointer target) (cffi:null-pointer)))
  nil)

(defun target-octets-copy (target)
  "The target's pixels as a Lisp octet vector, copied out of the mapping.

For screenshots and tests.  The render path never calls this: it draws through
pixman straight into the memory POINTER names."
  (let* ((length (* (target-stride target) (target-height target)))
         (octets (make-array length :element-type '(unsigned-byte 8)))
         (pointer (target-pointer target)))
    (dotimes (index length octets)
      (setf (aref octets index)
            (cffi:mem-aref pointer :unsigned-char index)))))

(defun fill-target (target argb)
  "Fill TARGET with a premultiplied 0xAARRGGBB colour.

A word at a time through MEM-AREF, which indexes elements, so the count is the
octet length over four.  Foreign memory cannot be a vector, so this stays a loop;
the colour is written exactly, not composited."
  (let ((pointer (target-pointer target)))
    (dotimes (index (/ (* (target-stride target) (target-height target)) 4))
      (setf (cffi:mem-aref pointer :uint32 index) argb)))
  target)

(declaim (inline target-pixel))
(defun target-pixel (target x y)
  "The premultiplied 0xAARRGGBB pixel at X, Y, read straight from the target."
  (cffi:mem-aref (target-pointer target) :uint32
                 (ash (+ (* y (target-stride target)) (* x 4)) -2)))

(defun (setf target-pixel) (argb target x y)
  (setf (cffi:mem-aref (target-pointer target) :uint32
                       (ash (+ (* y (target-stride target)) (* x 4)) -2))
        argb)
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

;;; ---------------------------------------------------------------------------
;;; Solid rectangles and images we own
;;; ---------------------------------------------------------------------------
;;
;; The scene needs two things the shm path does not: a solid rectangle (a
;; background, a border) and a bitmap that is ours rather than a client's (the
;; cursor).  Both are ordinary pixman operations; doing them through pixman
;; rather than a Lisp pixel loop keeps the reference renderer one code path, and
;; keeps the cost of a full-window background out of interpreted code.

(cffi:defcstruct pixman-color
  (red :uint16) (green :uint16) (blue :uint16) (alpha :uint16))

(cffi:defcstruct pixman-box32
  (x1 :int32) (y1 :int32) (x2 :int32) (y2 :int32))

(cffi:defcfun ("pixman_image_fill_boxes" %fill-boxes) :int
  (op :unsigned-int) (destination :pointer) (color :pointer)
  (n-boxes :int) (boxes :pointer))

(defun straight-channel (premultiplied alpha shift)
  "One 8-bit straight channel from a premultiplied pixel.

pixman_colour_t is *not* premultiplied (pixman_image_fill_boxes multiplies), and
our targets and buffers are, so a translucent rectangle has to be divided back
out.  An opaque colour -- every rectangle v0 draws -- passes through unchanged."
  (if (zerop alpha)
      0
      (min 255 (round (* 255 (ldb (byte 8 shift) premultiplied)) alpha))))

(defun fill-rect (target x y width height argb)
  "Fill a X, Y, WIDTH x HEIGHT rectangle of TARGET with premultiplied ARGB.

Clipped by pixman to the target, so a rectangle hanging off the edge is drawn as
much as fits; a degenerate one draws nothing."
  (when (and (plusp width) (plusp height))
    (let ((alpha (ldb (byte 8 24) argb)))
      (cffi:with-foreign-objects ((color '(:struct pixman-color))
                                  (box '(:struct pixman-box32)))
        (flet ((set-slot (name value)
                 (setf (cffi:foreign-slot-value color '(:struct pixman-color) name)
                       (* 257 value))))
          (set-slot 'red (straight-channel argb alpha 16))
          (set-slot 'green (straight-channel argb alpha 8))
          (set-slot 'blue (straight-channel argb alpha 0))
          (set-slot 'alpha alpha))
        (setf (cffi:foreign-slot-value box '(:struct pixman-box32) 'x1) x
              (cffi:foreign-slot-value box '(:struct pixman-box32) 'y1) y
              (cffi:foreign-slot-value box '(:struct pixman-box32) 'x2) (+ x width)
              (cffi:foreign-slot-value box '(:struct pixman-box32) 'y2) (+ y height))
        (%fill-boxes +op-over+ (target-image target) color 1 box)
        t))))

(defun composite-bitmap (target octets width height &key (x 0) (y 0))
  "Draw premultiplied ARGB8888 OCTETS (WIDTH x HEIGHT) over TARGET at X, Y.

OVER, not SRC: a bitmap has transparent pixels and the thing underneath must
survive them -- which is exactly what the cursor needs.  The octets are pinned
for the duration of the call, so pixman never reads a moved vector."
  (when (and (plusp width) (plusp height))
    (cffi:with-pointer-to-vector-data (pointer octets)
      (let ((image (%create-bits +format-a8r8g8b8+ width height pointer (* 4 width))))
        (when (cffi:null-pointer-p image)
          (return-from composite-bitmap nil))
        (unwind-protect
             (progn
               (%composite32 +op-over+ image (cffi:null-pointer) (target-image target)
                             0 0 0 0 x y width height)
               t)
          (%image-unref image))))))
