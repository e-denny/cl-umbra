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
;;; Regions: damage and clip
;;; ---------------------------------------------------------------------------
;;
;; A pixman region is a set of rectangles kept normalised by pixman (unioned,
;; sorted, merged, emptied), and it is the currency of everything that decides *where*
;; to draw: the damage a frame has to repaint, the clip an item is drawn through, and
;; the area an opaque surface hides from the surfaces under it (docs/memory-and-rendering.md §7).
;;
;; pixman_region32_t is a box (four int32s) and a pointer to its rectangle array, so
;; the Lisp side holds one address and pixman owns everything behind it.  The struct is
;; never read field by field: the accessors below are the whole interface.

(cffi:defcstruct pixman-region32
  (x1 :int32) (y1 :int32) (x2 :int32) (y2 :int32)
  (data :pointer))

(cffi:defcfun ("pixman_region32_init" %region-init) :void
  (region :pointer))

(cffi:defcfun ("pixman_region32_init_rect" %region-init-rect) :void
  (region :pointer) (x :int) (y :int) (width :unsigned-int) (height :unsigned-int))

(cffi:defcfun ("pixman_region32_fini" %region-fini) :void
  (region :pointer))

(cffi:defcfun ("pixman_region32_clear" %region-clear-foreign) :void
  (region :pointer))

(cffi:defcfun ("pixman_region32_union" %region-union-foreign) :pointer
  (destination :pointer) (a :pointer) (b :pointer))

(cffi:defcfun ("pixman_region32_union_rect" %region-union-rect-foreign) :pointer
  (destination :pointer) (source :pointer)
  (x :int) (y :int) (width :unsigned-int) (height :unsigned-int))

(cffi:defcfun ("pixman_region32_intersect" %region-intersect-foreign) :pointer
  (destination :pointer) (a :pointer) (b :pointer))

(cffi:defcfun ("pixman_region32_intersect_rect" %region-intersect-rect-foreign) :pointer
  (destination :pointer) (source :pointer)
  (x :int) (y :int) (width :unsigned-int) (height :unsigned-int))

(cffi:defcfun ("pixman_region32_subtract" %region-subtract-foreign) :pointer
  (destination :pointer) (a :pointer) (b :pointer))

(cffi:defcfun ("pixman_region32_copy" %region-copy-foreign) :pointer
  (destination :pointer) (source :pointer))

(cffi:defcfun ("pixman_region32_translate" %region-translate-foreign) :void
  (region :pointer) (x :int) (y :int))

(cffi:defcfun ("pixman_region32_not_empty" %region-not-empty) :int
  (region :pointer))

(cffi:defcfun ("pixman_region32_n_rects" %region-n-rects) :int
  (region :pointer))

(cffi:defcfun ("pixman_region32_rectangles" %region-rectangles-foreign) :pointer
  (region :pointer) (n :pointer))

(cffi:defcfun ("pixman_region32_extents" %region-extents-foreign) :pointer
  (region :pointer))

(defstruct (region (:constructor %make-region (pointer)))
  ;; A region is one allocation that pixman may resize behind it; the Lisp object
  ;; is the address and nothing else.  Every function below takes regions, never
  ;; bare pointers, so the address never leaks into the scene.
  (pointer (cffi:null-pointer) :type cffi:foreign-pointer))

(defun make-region (&key (x 0) (y 0) (width 0) (height 0))
  "An empty region, or the single WIDTH x HEIGHT rectangle at X, Y.

INIT-RECT initialises as well as sets, so calling INIT first would allocate a
rectangle block that is then leaked."
  (let* ((pointer (cffi:foreign-alloc '(:struct pixman-region32)))
         (region (%make-region pointer)))
    (if (and (plusp width) (plusp height))
        (%region-init-rect pointer x y width height)
        (%region-init pointer))
    region))

(defun destroy-region (region)
  "Free REGION's rectangles and the region itself; a second call is a no-op."
  (let ((pointer (region-pointer region)))
    (unless (cffi:null-pointer-p pointer)
      (%region-fini pointer)
      (cffi:foreign-free pointer)
      (setf (region-pointer region) (cffi:null-pointer))))
  nil)

(declaim (inline region-pointer-or-nil))
(defun region-pointer-or-nil (region)
  (and region (region-pointer region)))

(defun region-clear (region)
  "Empty REGION; returns it."
  (%region-clear-foreign (region-pointer region))
  region)

(defun region-empty-p (region)
  "True when REGION covers no pixels."
  (or (null region)
      (zerop (%region-not-empty (region-pointer region)))))

(defun region-add (region x y width height)
  "Add a WIDTH x HEIGHT rectangle at X, Y to REGION; returns REGION.

A degenerate rectangle adds nothing -- a client is allowed to damage zero pixels,
and pixman would rather not be asked."
  (when (and (plusp width) (plusp height))
    (%region-union-rect-foreign (region-pointer region) (region-pointer region)
                                x y width height))
  region)

(defun region-add-box (region box)
  "Add a (X Y WIDTH HEIGHT) rectangle to REGION."
  (region-add region (first box) (second box) (third box) (fourth box)))

(defun region-union (into a b)
  "INTO := A union B.  Returns INTO; INTO may be A or B."
  (%region-union-foreign (region-pointer into) (region-pointer a) (region-pointer b))
  into)

(defun region-intersect (into a b)
  "INTO := A intersected with B.  Returns INTO; INTO may be A or B."
  (%region-intersect-foreign (region-pointer into) (region-pointer a) (region-pointer b))
  into)

(defun region-subtract (into a b)
  "INTO := A minus B.  Returns INTO; INTO may be A or B (pixman handles the alias)."
  (%region-subtract-foreign (region-pointer into) (region-pointer a) (region-pointer b))
  into)

(defun region-copy (into from)
  "INTO := FROM.  Returns INTO."
  (%region-copy-foreign (region-pointer into) (region-pointer from))
  into)

(defun region-intersect-rect (into from x y width height)
  "INTO := FROM intersected with a WIDTH x HEIGHT rectangle at X, Y."
  (if (and (plusp width) (plusp height))
      (%region-intersect-rect-foreign (region-pointer into) (region-pointer from)
                                      x y width height)
      (region-clear into))
  into)

(defun region-set-rect (region x y width height)
  "REGION := the single WIDTH x HEIGHT rectangle at X, Y; returns REGION."
  (region-clear region)
  (region-add region x y width height))

(defun region-translate (region dx dy)
  "Move every rectangle of REGION by (DX, DY); returns it."
  (%region-translate-foreign (region-pointer region) dx dy)
  region)

(defun region-rectangles (region)
  "REGION as a list of (X Y WIDTH HEIGHT) rectangles.

Read straight off pixman's array -- four int32 per box -- so this does not need the
box struct to have been declared yet and cannot disagree with it about layout."
  (if (region-empty-p region)
      '()
      (cffi:with-foreign-object (count :int)
        (let ((pointer (%region-rectangles-foreign (region-pointer region) count))
              (n (cffi:mem-ref count :int)))
          (loop for index below n
                for base = (* index 4)
                collect (list (cffi:mem-aref pointer :int32 base)
                              (cffi:mem-aref pointer :int32 (+ base 1))
                              (- (cffi:mem-aref pointer :int32 (+ base 2))
                                 (cffi:mem-aref pointer :int32 base))
                              (- (cffi:mem-aref pointer :int32 (+ base 3))
                                 (cffi:mem-aref pointer :int32 (+ base 1)))))))))

(defun region-bounds (region)
  "The smallest rectangle containing REGION, as (X Y WIDTH HEIGHT); NIL when empty."
  (unless (region-empty-p region)
    (let ((extents (%region-extents-foreign (region-pointer region))))
      (let ((x1 (cffi:mem-aref extents :int32 0))
            (y1 (cffi:mem-aref extents :int32 1))
            (x2 (cffi:mem-aref extents :int32 2))
            (y2 (cffi:mem-aref extents :int32 3)))
        (list x1 y1 (- x2 x1) (- y2 y1))))))


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

;;; ---------------------------------------------------------------------------
;;; Solid colours and boxes
;;; ---------------------------------------------------------------------------
;;
;; Two things every drawing call needs: a pixman colour (straight, not
;; premultiplied, so a translucent colour is divided back out exactly once) and the
;; boxes pixman fills.  They are declared here because the target fill and the
;; scene's rectangles both use them.

(cffi:defcstruct pixman-color
  (red :uint16) (green :uint16) (blue :uint16) (alpha :uint16))

(cffi:defcstruct pixman-box32
  (x1 :int32) (y1 :int32) (x2 :int32) (y2 :int32))

(cffi:defcfun ("pixman_image_fill_boxes" %pixman-fill-boxes) :int
  (op :unsigned-int) (destination :pointer) (color :pointer)
  (n-boxes :int) (boxes :pointer))

(cffi:defcfun ("pixman_image_set_repeat" %set-repeat) :void
  (image :pointer) (repeat :int))

(defconstant +repeat-normal+ 1)

(defun fill-box-premultiplied (target x y width height argb)
  "Fill one rectangle with a premultiplied colour, translucent or not, correctly.

One pixel in foreign memory, repeated across the rectangle and composited OVER: the
only shape of a translucent fill this pixman gets right (see FILL-BOXES-WITH)."
  (when (and (plusp width) (plusp height))
    (let ((pixel (cffi:foreign-alloc :uint32 :count 1 :initial-element argb)))
      (unwind-protect
           (let ((image (%create-bits +format-a8r8g8b8+ 1 1 pixel 4)))
             (when (cffi:null-pointer-p image)
               (return-from fill-box-premultiplied nil))
             (unwind-protect
                  (progn
                    (%set-repeat image +repeat-normal+)
                    (%composite32 +op-over+ image (cffi:null-pointer)
                                  (target-image target)
                                  0 0 0 0 x y width height)
                    t)
               (%image-unref image)))
        (cffi:foreign-free pixel)))))

(defun straight-channel (premultiplied alpha shift)
  "One 8-bit straight channel from a premultiplied pixel.

pixman_colour_t is *not* premultiplied (pixman_image_fill_boxes multiplies), and
our targets and buffers are, so a translucent rectangle has to be divided back
out.  An opaque colour -- every rectangle v0 draws -- passes through unchanged."
  (if (zerop alpha)
      0
      (min 255 (round (* 255 (ldb (byte 8 shift) premultiplied)) alpha))))

(defun fill-boxes-with (target boxes count argb)
  "Fill COUNT consecutive pixman boxes at BOXES with premultiplied ARGB.

An *opaque* colour goes through pixman_image_fill_boxes, which writes it exactly and
honours the target's clip region -- that is the common case, a background or a
window border, and the reason a partial repaint costs what it damages.

A translucent colour cannot: pixman 0.46's fill_boxes turns a pixman_color_t into a
*straight* alpha pixel and then composites it as if it were premultiplied, so a 50%
white rectangle comes out opaque white -- measured, not assumed (filltest in the
2b session; the same call over a green destination gives #xFFFFFFFF instead of
#xFF80FF80).  A one-pixel premultiplied image, repeated, is correct: it is the same
call COMPOSITE-BITMAP makes and pixman blends it exactly.  Translucent rectangles are
rare (a border, a veil), so the extra image per fill is not on any hot path, and a
wrong pixel would be on the screen."
  (when (plusp count)
    (let ((alpha (ldb (byte 8 24) argb)))
      (cffi:with-foreign-object (color '(:struct pixman-color))
        (flet ((set-slot (name value)
                 (setf (cffi:foreign-slot-value color '(:struct pixman-color) name)
                       (* 257 value))))
          (set-slot 'red (straight-channel argb alpha 16))
          (set-slot 'green (straight-channel argb alpha 8))
          (set-slot 'blue (straight-channel argb alpha 0))
          (set-slot 'alpha alpha))
        (cond
          ((= alpha 255)
           (plusp (%pixman-fill-boxes +op-over+ (target-image target) color count boxes)))
          (t
           (loop for index below count
                 for box = (cffi:mem-aptr boxes '(:struct pixman-box32) index)
                 do (fill-box-premultiplied
                     target
                     (cffi:foreign-slot-value box '(:struct pixman-box32) 'x1)
                     (cffi:foreign-slot-value box '(:struct pixman-box32) 'y1)
                     (- (cffi:foreign-slot-value box '(:struct pixman-box32) 'x2)
                        (cffi:foreign-slot-value box '(:struct pixman-box32) 'x1))
                     (- (cffi:foreign-slot-value box '(:struct pixman-box32) 'y2)
                        (cffi:foreign-slot-value box '(:struct pixman-box32) 'y1))
                     argb))
           t))))))

;;; ---------------------------------------------------------------------------
;;; Targets
;;; ---------------------------------------------------------------------------

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

(cffi:defcfun ("pixman_image_set_clip_region32" %set-clip-region) :int
  (image :pointer) (region :pointer))

(defun target-set-clip (target region)
  "Draw only inside REGION from now on; NIL removes the clip.

pixman copies the region into the image, so the caller may free or reuse REGION as
soon as this returns -- which is what the scene's per-item clips rely on."
  (%set-clip-region (target-image target) (region-pointer-or-nil region))
  target)

(defun target-clear-clip (target)
  "Remove TARGET's clip region: draw everywhere again."
  (%set-clip-region (target-image target) (cffi:null-pointer))
  target)

(defun fill-target (target argb)
  "Fill TARGET with a premultiplied 0xAARRGGBB colour.

Through pixman, so the target's clip region applies: a partial repaint sets the
clip to its damage and calls this, and only the damaged rectangles are painted.
An opaque colour is written exactly (OVER with alpha 255), not blended."
  (cffi:with-foreign-object (box '(:struct pixman-box32))
    (setf (cffi:foreign-slot-value box '(:struct pixman-box32) 'x1) 0
          (cffi:foreign-slot-value box '(:struct pixman-box32) 'y1) 0
          (cffi:foreign-slot-value box '(:struct pixman-box32) 'x2) (target-width target)
          (cffi:foreign-slot-value box '(:struct pixman-box32) 'y2) (target-height target))
    (fill-boxes-with target box 1 argb))
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

;;; ---------------------------------------------------------------------------
;;; Transforms: buffer scale, and the eight buffer transforms
;;; ---------------------------------------------------------------------------
;;
;; A surface's buffer is drawn into a rectangle whose size the scene decides: a
;; client that drew at buffer scale 2 supplies twice the pixels of its surface, and
;; an output at scale 2 wants twice the pixels of the layout coordinate.  The ratio
;; between the two is a pixman transform, and pixman's transform maps *destination*
;; to *source* -- which is why the matrices below read backwards at first glance
;; (docs/memory-and-rendering.md §7).
;;
;; The eight wl_output.transform values are the protocol's: 90/180/270 are
;; counter-clockwise rotations of the buffer contents, and the `flipped' family is a
;; flip around a vertical axis followed by the rotation (protocols/wayland/wayland.xml,
;; wl_output.transform).  Each matrix was checked against rendered pixels -- the
;; scene suite draws a 3x2 source through all eight and asserts the result -- so the
;; table is evidence, not an interpretation.

(cffi:defcstruct pixman-transform32
  (matrix :int32 :count 9))

(cffi:defcfun ("pixman_image_set_transform" %set-transform) :int
  (image :pointer) (transform :pointer))

(cffi:defcfun ("pixman_image_set_filter" %set-filter) :void
  (image :pointer) (filter :int) (filter-params :pointer) (n-filter-params :int))

(defconstant +filter-nearest+ 0)
(defconstant +filter-bilinear+ 1)

(defvar *transform-scratch* nil
  "One pixman_transform_t, allocated once and rewritten per draw.

Compositing is single-threaded and pixman copies nothing out of the transform, so a
frame that scales ten surfaces writes this ten times rather than allocating ten of
them (docs/memory-and-rendering.md §11).")

(defun buffer-display-size (buffer-width buffer-height transform)
  "The size a BUFFER-WIDTH x BUFFER-HEIGHT buffer occupies, after TRANSFORM.

A quarter turn swaps the axes; everything else keeps them."
  (if (oddp transform)
      (values buffer-height buffer-width)
      (values buffer-width buffer-height)))

(defun transform-matrix (buffer-width buffer-height display-width display-height transform)
  "Nine 16.16 values, row-major, mapping a destination point to a source point.

W/H are the buffer's pixels and DW/DH the rectangle it is drawn into.  For the
rotated transforms the two disagree by a swap, which is why they are passed
separately rather than derived here."
  (let ((w buffer-width) (h buffer-height)
        (dw (max 1 display-width)) (dh (max 1 display-height)))
    (multiple-value-bind (a b tx c d ty)
        (ecase transform
          ;; Each case is sx = a*dx + b*dy + tx, sy = c*dx + d*dy + ty.
          (0 (values (/ w dw) 0 0 0 (/ h dh) 0))
          (1 (values 0 (- (/ w dh)) w (/ h dw) 0 0))          ; 90 CCW
          (2 (values (- (/ w dw)) 0 w 0 (- (/ h dh)) h))     ; 180
          (3 (values 0 (/ w dh) 0 (- (/ h dw)) 0 h))         ; 270 CCW
          (4 (values (- (/ w dw)) 0 w 0 (/ h dh) 0))         ; flipped
          (5 (values 0 (/ w dh) 0 (/ h dw) 0 0))             ; flipped 90
          (6 (values (/ w dw) 0 0 0 (- (/ h dh)) h))         ; flipped 180
          (7 (values 0 (- (/ w dh)) w (- (/ h dw)) 0 h)))    ; flipped 270
      (list a b tx c d ty 0 0 1))))

(defun %set-image-transform (image buffer-width buffer-height display-width display-height transform)
  "Map IMAGE's destination rectangle back onto its pixels; returns IMAGE."
  (let ((scratch (or *transform-scratch*
                     (setf *transform-scratch*
                           (cffi:foreign-alloc '(:struct pixman-transform32)))))
        (index 0))
    (dolist (value (transform-matrix buffer-width buffer-height
                                     display-width display-height transform))
      (setf (cffi:mem-aref scratch :int32 index) (round (* value 65536)))
      (incf index))
    ;; Nearest is faster *and* sharper for an integer ratio: a client that drew at
    ;; the output's scale should be copied pixel for pixel, not blurred.
    (%set-filter image +filter-nearest+ (cffi:null-pointer) 0)
    (%set-transform image scratch)
    image))

(defun composite-buffer (target buffer &key (x 0) (y 0) width height (transform 0)
                                             (filter :nearest))
  "Draw BUFFER into the WIDTH x HEIGHT rectangle at X, Y of TARGET.

WIDTH and HEIGHT default to the buffer's own size, which is the 1:1 case; a
surface drawn at a buffer scale different from the output's passes the device size
and is scaled to fit it.  TRANSFORM is a wl_output.transform value (the client's
`set_buffer_transform'), applied on top of the scale.  Returns true when it drew.

Clipping is the target's job: pixman clips to the destination image (and to its
clip region), so a window hanging off the edge loses the outside part."
  (let ((image (buffer-image buffer)))
    (unless image
      (return-from composite-buffer nil))
    (unwind-protect
         (let* ((buffer-width (wayland.server:shm-buffer-width buffer))
                (buffer-height (wayland.server:shm-buffer-height buffer))
                (display-width (or width buffer-width))
                (display-height (or height buffer-height)))
           (unless (and (= transform 0)
                        (= display-width buffer-width)
                        (= display-height buffer-height))
             (%set-image-transform image buffer-width buffer-height
                                   display-width display-height transform)
             (unless (eq filter :nearest)
               (%set-filter image +filter-bilinear+ (cffi:null-pointer) 0)))
           (%composite32 (op-for-shm-format (wayland.server:shm-buffer-format buffer))
                         image (cffi:null-pointer) (target-image target)
                         0 0 0 0 x y display-width display-height)
           t)
      (%image-unref image))))

;;; ---------------------------------------------------------------------------
;;; Solid rectangles and images we own
;;; ---------------------------------------------------------------------------
;;
;; The scene needs two things the shm path does not: a solid rectangle (a
;; background, a border) and a bitmap that is ours rather than a client's (the
;; cursor).  FILL-RECT and COMPOSITE-BITMAP are those two, and both go through
;; pixman so a clip region is honoured without a Lisp pixel loop anywhere.

(defun fill-rect (target x y width height argb)
  "Fill a X, Y, WIDTH x HEIGHT rectangle of TARGET with premultiplied ARGB.

Clipped by pixman to the target (and to the target's clip region, when one is
set), so a rectangle hanging off the edge is drawn as much as fits; a degenerate
one draws nothing."
  (when (and (plusp width) (plusp height))
    (cffi:with-foreign-object (box '(:struct pixman-box32))
      (setf (cffi:foreign-slot-value box '(:struct pixman-box32) 'x1) x
            (cffi:foreign-slot-value box '(:struct pixman-box32) 'y1) y
            (cffi:foreign-slot-value box '(:struct pixman-box32) 'x2) (+ x width)
            (cffi:foreign-slot-value box '(:struct pixman-box32) 'y2) (+ y height))
      (fill-boxes-with target box 1 argb))))

(defun composite-bitmap (target octets width height &key (x 0) (y 0)
                                                  dest-width dest-height)
  "Draw premultiplied ARGB8888 OCTETS (WIDTH x HEIGHT) over TARGET at X, Y.

OVER, not SRC: a bitmap has transparent pixels and the thing underneath must
survive them -- which is exactly what the cursor needs.  The octets are pinned
for the duration of the call, so pixman never reads a moved vector.  DEST-WIDTH
and DEST-HEIGHT scale the bitmap (the cursor is 16x16 pixels and an output at
scale 2 draws it 32x32), nearest-neighbour so it stays an arrow."
  (when (and (plusp width) (plusp height))
    (cffi:with-pointer-to-vector-data (pointer octets)
      (let* ((image (%create-bits +format-a8r8g8b8+ width height pointer (* 4 width)))
             (draw-width (or dest-width width))
             (draw-height (or dest-height height)))
        (when (cffi:null-pointer-p image)
          (return-from composite-bitmap nil))
        (unwind-protect
             (progn
               (unless (and (= draw-width width) (= draw-height height))
                 (%set-image-transform image width height draw-width draw-height 0))
               (%composite32 +op-over+ image (cffi:null-pointer) (target-image target)
                             0 0 0 0 x y draw-width draw-height)
               t)
          (%image-unref image))))))
