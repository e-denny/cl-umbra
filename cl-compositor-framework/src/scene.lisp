;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cf.scene v0: a retained node tree per output (docs/framework.md §4).
;;;;
;;;; Six node kinds cover everything this compositor draws -- the compositing
;;;; phase 2a already did, the text the switcher needs, and the picture in each of
;;;; its rows:
;;;;
;;;;   TREE-NODE      a group with children, drawn in order: the root is one
;;;;   BUFFER-NODE    a mapped wl_surface, drawn from its current buffer
;;;;   RECT-NODE      a solid rectangle: backgrounds, borders, letterboxing
;;;;   BITMAP-NODE    premultiplied ARGB8888 pixels we own:
;;;;     IMAGE-NODE     the software cursor
;;;;     SNAPSHOT-NODE  a window's picture, taken once (the switcher's thumbnails)
;;;;   TEXT-NODE      a string in the built-in 5x7 font: the switcher's titles
;;;;
;;;; One tree is what the compositor arranges; one overlay is what it draws on top
;;;; of everything without arranging it.  The overlay is a second root -- above the
;;;; windows, below the cursor, never hit-tested -- so the Alt+Tab switcher can
;;;; cover the screen without becoming part of the desktop (D51).  A layer
;;;; (layer-shell) is a different thing and arrives with the shell that needs it
;;;; (phase 6).
;;;;
;;;; Positions are in the parent's space; the root's parent is the output, so a
;;;; root child's position is output-local, which is the space the renderer and
;;;; hit testing both work in.  A node's own position plus its surface's attach
;;;; offset is where its pixels go: the attach offset is the client's own
;;;; statement about its content, and window placement is the compositor's --
;;;; keeping them separate is what lets the compositor move a window without
;;;; lying to the client about its buffer.
;;;;
;;;; Two spaces, one tree.  Layout (also called output-local or surface-local)
;;;; coordinates are what a compositor's policies, configure sizes, hit tests and
;;;; grabs speak; the target's device pixels are layout times the output scale.
;;;; The scene is retained in layout coordinates and turns them into device
;;;; pixels exactly once per frame, in SCENE-DRAW-LIST (D49).  A client that drew
;;;; at its own buffer scale is divided out on the way: a scale-2 buffer shown on
;;;; a scale-2 output is a 1:1 copy, which is the whole point of the protocol's
;;;; buffer scale.
;;;;
;;;; The tree is retained, not rebuilt per frame, because rules, workspaces,
;;;; overview and animations all need the node to exist between frames (D10).
;;;;
;;;; Deliberately *not* here yet: layers (layer-shell arrives with the shell that
;;;; needs them, phase 6), fractional scaling (wp-fractional-scale, phase 5), and
;;;; the effects passes (phase 7).
(in-package #:cl-user)

(in-package #:cf.scene)

(defparameter +cursor-width+ 16)
(defparameter +cursor-height+ 16)


;;; ---------------------------------------------------------------------------
;;; Nodes
;;; ---------------------------------------------------------------------------

(defclass scene-node ()
  ((parent :initform nil :accessor node-parent)
   (x :initform 0 :accessor node-x)
   (y :initform 0 :accessor node-y)
   (visible-p :initform t :accessor node-visible-p))
  (:documentation
   "Anything that occupies a place in an output's tree.

A node's position is in its parent's coordinate space; the parent of a root child
is the output, so its position is output-local.  Moving a node is a position
change, not a re-creation: the node survives frames (that is what makes it
retained rather than immediate)."))

(defclass tree-node (scene-node)
  ((children :initform nil :accessor node-children))
  (:documentation
   "A group: its children are drawn in order, back to front, at its position.

The scene's root is one of these, and it is also what layer-shell's background,
content, top and overlay layers will be (phase 6): a layer is a group with a
fixed place in the stacking order, not a new kind of node."))

(defclass buffer-node (scene-node)
  ((surface :initarg :surface :reader buffer-node-surface))
  (:documentation
   "A mapped wl_surface, drawn from whatever buffer it currently has.

Its size is the buffer's size -- never a value the compositor chose -- because a
compositor that thinks a window is bigger than its pixels puts hit-testable area
where there is nothing to see."))

(defclass rect-node (scene-node)
  ((width :initarg :width :initform 0 :accessor node-width)
   (height :initarg :height :initform 0 :accessor node-height)
   (color :initarg :color :initform #xFF000000 :accessor rect-node-color))
  (:documentation
   "A solid rectangle in premultiplied 0xAARRGGBB: backgrounds, borders, and
letterboxing when an output's aspect ratio and a fullscreen client's disagree."))

(defclass bitmap-node (scene-node)
  ((octets :initarg :octets :reader bitmap-node-octets)
   ;; The bitmap's own pixel size, which is not always the size it is drawn: the
   ;; cursor is 16x16 pixels and is drawn 32x32 at scale 2, while a snapshot is
   ;; taken at the size it will be drawn and the two agree (D52).
   (source-width :initarg :source-width :initform 0 :reader bitmap-node-source-width)
   (source-height :initarg :source-height :initform 0 :reader bitmap-node-source-height))
  (:documentation
   "Pixel memory we own, not a client's: premultiplied ARGB8888, row-major.

What a bitmap node has that a buffer node does not is a lifetime of its own: the
client that supplied the pixels may redraw, resize or disconnect, and the picture
stays what it was.  That is what a cursor needs (it must survive the client that
set it) and what a thumbnail needs (it must not change under a draw item whose
signature says it did not) (D52)."))

(defclass image-node (bitmap-node)
  ((width :initarg :width :accessor node-width)
   (height :initarg :height :accessor node-height))
  (:documentation
   "Premultiplied ARGB8888 pixels owned by us, not by a client: today only the
software cursor, because a cursor is composited last and must not be a client
surface (a client may set a cursor *surface*, which is a different object --
phase 5)."))

(defclass snapshot-node (bitmap-node)
  ((width :initarg :width :accessor node-width)
   (height :initarg :height :accessor node-height))
  (:documentation
   "A picture of a client's buffer, taken once and drawn into a box we chose.

Not a buffer node, and the difference is the whole point: a buffer node draws
whatever the client last committed, at the size the client chose, and its size is
never a value the compositor invented.  A snapshot is a *copy* whose size and
lifetime are ours -- downscaled once, at the resolution it will be shown at, so
drawing it later is a 1:1 copy rather than a resample per frame (D52).

It is also what makes a row's picture honest with the damage diff: the draw item's
signature carries the octets, and a vector we allocated does not change, so a
client that keeps repainting its window does not keep repainting its thumbnail.
Whether the picture is *current* is then a policy question with one answer -- no:
it is what the window looked like when the picture was taken -- instead of an
accident of what happened to be damaged."))

(defclass text-node (scene-node)
  ((text :initarg :text :initform "" :accessor text-node-text)
   (colour :initarg :colour :initform #xFFFFFFFF :accessor text-node-colour)
   ;; One raster, kept until the text, the colour or the scale changes.  A
   ;; switcher draws the same titles for as long as it is open; a raster per
   ;; frame per row is a bitmap allocation per frame per row
   ;; (docs/memory-and-rendering.md §11).
   (cache-key :initform nil :accessor text-node-cache-key)
   (cache :initform nil :accessor text-node-cache))
  (:documentation
   "A string in the built-in 5x7 font, measured in layout pixels and drawn at the
output's scale (D51).

Measured, not sized by the caller: NODE-WIDTH is the font's own answer, so a
layout that places a title places it where its pixels end.  The colour is
premultiplied 0xAARRGGBB like a rectangle's, and an empty string has no size and
draws nothing -- which is what lets a row with no title still have a row."))

;;; ---------------------------------------------------------------------------
;;; DEFCLASS defines no type predicates (that is DEFSTRUCT), and the walk below
;;; reads better with names than with TYPEP forms in every branch.
(declaim (inline tree-node-p buffer-node-p rect-node-p bitmap-node-p image-node-p
                 snapshot-node-p text-node-p))
(defun tree-node-p (node) (typep node 'tree-node))
(defun buffer-node-p (node) (typep node 'buffer-node))
(defun rect-node-p (node) (typep node 'rect-node))
(defun bitmap-node-p (node) (typep node 'bitmap-node))
(defun image-node-p (node) (typep node 'image-node))
(defun snapshot-node-p (node) (typep node 'snapshot-node))
(defun text-node-p (node) (typep node 'text-node))

(defun image-node-octets (node)
  "NODE's pixels; the reader IMAGE-NODE used to have, now on BITMAP-NODE."
  (bitmap-node-octets node))

;;; ---------------------------------------------------------------------------
;;; Constructors
;;; ---------------------------------------------------------------------------

(defun make-buffer-node (surface)
  "A node that draws SURFACE at its current buffer, sized by that buffer."
  (make-instance 'buffer-node :surface surface))

(defun make-rect-node (width height color)
  "A solid WIDTH x HEIGHT rectangle, premultiplied 0xAARRGGBB."
  (make-instance 'rect-node :width width :height height :color color))

(defun make-image-node (octets width height)
  "A node drawing premultiplied ARGB8888 OCTETS, WIDTH x HEIGHT pixels."
  (make-instance 'image-node :octets octets :width width :height height
                             :source-width width :source-height height))

(defun make-snapshot-node (octets pixel-width pixel-height width height)
  "A node drawing OCTETS (PIXEL-WIDTH x PIXEL-HEIGHT pixels) as a
WIDTH x HEIGHT layout box.

The two sizes are given separately because they mean different things: PIXEL-WIDTH
is how many pixels the picture has, WIDTH is how much of the output it covers.  A
snapshot is normally taken at exactly the device size it will be drawn at, which is
what makes drawing it a copy rather than a resample (D52)."
  (make-instance 'snapshot-node :octets octets
                                :source-width pixel-width :source-height pixel-height
                                :width width :height height))

(defun make-text-node (text &key (colour #xFFFFFFFF))
  "A node drawing TEXT in the built-in font, in premultiplied ARGB8888 COLOUR."
  (make-instance 'text-node :text text :colour colour))

(defun text-node-raster (node &optional (scale 1))
  "NODE's text as premultiplied ARGB8888 at SCALE; three values.

(values OCTETS WIDTH HEIGHT), WIDTH and HEIGHT in device pixels, and WIDTH zero
for empty text.  Cached on the text, the colour and the scale, so a frame that
draws the same title twice allocates nothing for it (D51)."
  (let* ((scale (max 1 (round scale)))
         (key (list (text-node-text node) (text-node-colour node) scale)))
    (unless (equal key (text-node-cache-key node))
      (multiple-value-bind (octets width height)
          (font:rasterize-text (text-node-text node) (text-node-colour node) scale)
        (setf (text-node-cache node) (list octets width height)
              (text-node-cache-key node) key)))
    (values (first (text-node-cache node))
            (second (text-node-cache node))
            (third (text-node-cache node)))))

;;; ---------------------------------------------------------------------------
;;; Layout size: what a surface occupies
;;; ---------------------------------------------------------------------------
;;
;; A buffer is pixels; a surface is a size in layout coordinates.  The two differ
;; by the client's buffer scale and, for a rotated buffer, by a swapped pair of
;; axes.  Everything a compositor *decides* -- where a window goes, what a click
;; hits, what a configure asks for -- is in layout coordinates, so the conversion
;; happens here and nowhere else (D49).

(defun surface-layout-size (surface)
  "SURFACE's size in layout coordinates; two values, zero when it has no buffer.

buffer size / buffer scale, with the axes swapped for the quarter turns.  Rounded
up: a client whose buffer is not a whole multiple of its scale is malformed, and
covering a pixel too many is the failure a person does not see."
  (let ((buffer (and surface (surface-current-buffer surface))))
    (if buffer
        (let ((scale (max 1 (or (and surface (surface-buffer-scale surface)) 1))))
          (multiple-value-bind (width height)
              (render:buffer-display-size (shm-buffer-width buffer)
                                          (shm-buffer-height buffer)
                                          (or (surface-buffer-transform surface) 0))
            (values (max 1 (ceiling width scale))
                    (max 1 (ceiling height scale)))))
        (values 0 0))))

(defmethod node-width ((node buffer-node))
  (let ((surface (buffer-node-surface node)))
    (if surface
        (nth-value 0 (surface-layout-size surface))
        0)))

(defmethod node-height ((node buffer-node))
  (let ((surface (buffer-node-surface node)))
    (if surface
        (nth-value 1 (surface-layout-size surface))
        0)))

(defmethod node-width ((node scene-node))
  "A group has no size of its own: it is exactly its children's extent."
  0)

(defmethod node-height ((node scene-node))
  0)

;; A text node is laid out in layout pixels whatever scale it is drawn at, so a
;; switcher's arithmetic is the same at scale 1 and scale 2 (D49).
(defmethod node-width ((node text-node))
  (font:text-width (text-node-text node)))

(defmethod node-height ((node text-node))
  (if (plusp (font:text-width (text-node-text node))) (font:text-height) 0))

;;; ---------------------------------------------------------------------------
;;; The scene
;;; ---------------------------------------------------------------------------

(defclass scene ()
  ((width :initarg :width :accessor scene-width)
   (height :initarg :height :accessor scene-height)
   (root :initarg :root :reader scene-root)
   ;; What the compositor draws *over* the desktop without arranging it: the
   ;; Alt+Tab switcher today (D51).  A second root, drawn after the tree and
   ;; before the cursor, and deliberately not part of the tree: an overlay is not
   ;; a window, so it must not be hit-tested, raised, cycled or clamped, and the
   ;; surest way to guarantee that is not to let it be found (D31's rule for the
   ;; cursor, applied to a second thing).
   (overlay :initarg :overlay :reader scene-overlay)
   ;; Drawn after everything else, at the pointer's position.  It is a node so
   ;; that it has a position and a drawing rule like every other node, but it is
   ;; deliberately *not* a child of the root: it must never be hit-tested, or it
   ;; would be the one thing the pointer can never leave.
   (cursor :initarg :cursor :reader scene-cursor)
   (cursor-visible-p :initform t :accessor scene-cursor-visible-p)
   ;; The pointer image a *client* has installed (wl_pointer.set_cursor), if any,
   ;; and where its hotspot is inside the image.  Drawn at the pointer instead of
   ;; the built-in arrow: the image is the client's statement about what the
   ;; pointer means where it happens to be (an I-beam over text, a resize arrow on
   ;; a border), and a compositor that always draws its own arrow throws that away
   ;; (D41).  NIL means "no client image": the built-in arrow is drawn, so a
   ;; pointer never disappears over the bare output.
   (cursor-surface :initform nil :accessor scene-cursor-surface)
   (cursor-hotspot-x :initform 0 :accessor scene-cursor-hotspot-x)
   (cursor-hotspot-y :initform 0 :accessor scene-cursor-hotspot-y)
   ;; Layout coordinate -> device pixel.  The tree, its positions, its sizes and
   ;; everything a compositor decides stay in layout coordinates; this is the one
   ;; number that turns them into the target's pixels (D49).
   (scale :initarg :scale :initform 1 :accessor scene-scale)
   ;; Scratch regions for the per-frame clip and damage arithmetic, kept and
   ;; reused rather than allocated: a frame allocates none of them in steady
   ;; state, and growing the pool once is cheaper than a malloc per item per
   ;; frame (docs/memory-and-rendering.md §11).
   (regions :initform nil :accessor scene-regions))
  (:documentation
   "One output's tree, plus its overlay and its cursor.

The output size is here because the scene is the thing that knows what fits;
SCALE is the device pixels per layout coordinate; the compositor still owns the
target, the background fill and the frame clock."))

(defun make-scene (width height &key (cursor-image (make-cursor-image)) (scale 1))
  "A scene for a WIDTH x HEIGHT output at SCALE device pixels per coordinate."
  (let* ((root (make-instance 'tree-node))
         (overlay (make-instance 'tree-node))
         (cursor (make-instance 'image-node
                                :octets cursor-image
                                :width +cursor-width+
                                :height +cursor-height+)))
    (make-instance 'scene :width width :height height :scale scale
                          :root root :overlay overlay :cursor cursor)))

(defun scene-region (scene index)
  "Scratch region number INDEX for SCENE, created on first use and reused after.

A region is only valid until the next frame uses the same index, which is what lets
one pool serve the clip arithmetic without being cleared by hand."
  (let ((pool (scene-regions scene)))
    (if (< index (length pool))
        (nth index pool)
        (let ((region (render:make-region)))
          (setf (scene-regions scene) (append pool (list region)))
          region))))

;;; ---------------------------------------------------------------------------
;;; Tree operations
;;; ---------------------------------------------------------------------------

(defun scene-add-node (scene node &key (x 0) (y 0))
  "Put NODE on top of the scene, at (X, Y) in output space."
  (setf (node-parent node) (scene-root scene)
        (node-x node) x
        (node-y node) y)
  ;; Appending is "on top" because drawing walks the list front to back.
  (setf (node-children (scene-root scene))
        (append (node-children (scene-root scene)) (list node)))
  node)

(defun scene-remove-node (node)
  "Take NODE out of its parent's children.  Idempotent."
  (let ((parent (node-parent node)))
    (when parent
      (setf (node-children parent) (remove node (node-children parent) :test #'eq)
            (node-parent node) nil)))
  node)

(defun node-raised (node)
  "Move NODE to the top of its parent's stacking order; return it.

Raising is how a commit-order list behaved before the scene existed, and it is
still what a client that commits again is asking for: its window came forward."
  (let ((parent (node-parent node)))
    (when parent
      (setf (node-children parent)
            (append (remove node (node-children parent) :test #'eq)
                    (list node))))
    node))

(defun node-position (node)
  "NODE's position in its parent's space, as two values."
  (values (node-x node) (node-y node)))

(defun scene-add-overlay-node (scene node &key (x 0) (y 0))
  "Put NODE in SCENE's overlay at (X, Y), above every window and below the cursor.

The overlay is how a compositor draws something that is not part of the desktop --
the Alt+Tab switcher's panel and titles (D51).  Note what it is not: a child of
SCENE-ROOT.  Nothing that hit-tests, cycles, raises or re-clamps walks the
overlay, so an overlay node cannot be clicked, focused or moved by accident."
  (let ((overlay (scene-overlay scene)))
    (setf (node-parent node) overlay
          (node-x node) x
          (node-y node) y)
    ;; Appending is "on top", as in SCENE-ADD-NODE.
    (setf (node-children overlay)
          (append (node-children overlay) (list node))))
  node)

(defun scene-clear-overlay (scene)
  "Take everything out of SCENE's overlay; returns how many nodes there were.

Idempotent, and the one call a compositor makes when its overlay goes away: the
next frame's draw list no longer contains those nodes, so the damage diff repaints
what they were covering."
  (let ((overlay (scene-overlay scene)))
    (prog1 (length (node-children overlay))
      (dolist (child (node-children overlay))
        (setf (node-parent child) nil))
      (setf (node-children overlay) nil))))

(defun set-node-position (node x y)
  "Move NODE; returns it."
  (setf (node-x node) x
        (node-y node) y)
  node)

(defun set-node-size (node width height)
  "Resize NODE to WIDTH x HEIGHT layout pixels; returns it.

Only the sizes that are the compositor's to set: a rectangle's (a border, a
selection bar) and a bitmap's (a cursor image).  A buffer node's size is its
client's answer, a text node's is its font's, and a snapshot's is the box it was
taken for -- setting those would be a second truth about the same pixels, which is
exactly what D10 refused."
  (typecase node
    ((or rect-node image-node)
     (setf (node-width node) width
           (node-height node) height)
     node)
    (t (error "~S has no size of its own to set" node))))

;;; ---------------------------------------------------------------------------
;;; Hit testing
;;; ---------------------------------------------------------------------------

(defun input-region-accepts-p (surface x y)
  "Does SURFACE take input at its own (X, Y)?

Surface-local coordinates, and the committed region, which is NIL for \"no region
was ever set\" (the whole surface takes input), :EMPTY for an empty wl_region (a
common and legal way to make a surface input-transparent), or a list of
rectangles.  Honouring the third case is what makes a client-drawn shadow or a
popup gap clickable through (D31)."
  (let ((region (surface-input-region surface)))
    (cond ((null region) t)
          ((eq region :empty) nil)
          (t (loop for (rx ry width height) in region
                   thereis (and (<= rx x) (< x (+ rx width))
                                (<= ry y) (< y (+ ry height))))))))

(defun buffer-node-accepts-p (node x y)
  "Is (X, Y), in NODE's own space, on NODE's surface?"
  (let ((surface (buffer-node-surface node))
        (width (node-width node))
        (height (node-height node)))
    (and surface
         (surface-mapped-p surface)
         (plusp width)
         (plusp height)
         (<= 0 x) (< x width)
         (<= 0 y) (< y height)
         (input-region-accepts-p surface x y))))

(defun node-accepts-p (node x y)
  "Does NODE take input at (X, Y) in NODE's own space?"
  (cond ((buffer-node-p node) (buffer-node-accepts-p node x y))
        ;; A rectangle is a part of the scene like any other and can be hit;
        ;; whether it *takes* input is the compositor's policy (it focuses
        ;; BUFFER-NODEs only).
        ((rect-node-p node)
         (and (plusp (node-width node)) (plusp (node-height node))
              (<= 0 x) (< x (node-width node))
              (<= 0 y) (< y (node-height node))))
        (t nil)))

(defun node-at (node x y)
  "The frontmost node under (X, Y), with (X, Y) in NODE's parent space.

Returns three values: the node, and the position in the node's own space.  The
walk is front to back, so a window on top of another wins even where they
overlap, which is the whole point of a stacking order."
  (when (node-visible-p node)
    (cond
      ((tree-node-p node)
       (let ((lx (- x (node-x node)))
             (ly (- y (node-y node))))
         (dolist (child (reverse (node-children node)))
           (multiple-value-bind (hit hx hy) (node-at child lx ly)
             (when hit (return-from node-at (values hit hx hy)))))))
      ((node-accepts-p node (- x (node-x node)) (- y (node-y node)))
       (values node (- x (node-x node)) (- y (node-y node)))))))

(defun scene-hit-test (scene x y)
  "The frontmost node under (X, Y) in output space; three values like NODE-AT.

A point with nothing under it returns NIL and NIL -- there is no background node
in v0, so the bare output is genuinely nothing, and the compositor treats it as
\"no surface takes this input\" rather than as a window."
  (node-at (scene-root scene) x y))

;;; ---------------------------------------------------------------------------
;;; Drawing: what to draw, where, and what has to be repainted
;;; ---------------------------------------------------------------------------
;;
;; A frame is three passes over one list.  SCENE-DRAW-LIST turns the tree into
;; draw items in device pixels, back to front; SCENE-DAMAGE-BETWEEN compares this
;; frame's list with the last one and says which pixels differ; SCENE-RENDER-ITEMS
;; draws the items, each through a clip that is its own rectangle minus everything
;; opaque above it and minus everything undamaged (D48, D50).
;;
;; One list is why the passes cannot disagree: the same rectangles decide the
;; damage and the draw, so a window that moved and a window that redrew are the
;; same kind of event to both.

(defstruct (draw-item (:constructor %make-draw-item))
  ;; NODE is what the damage diff matches on, and for the cursor item it is always
  ;; the scene's cursor node -- a client's cursor image and the built-in arrow are
  ;; the same item with a different picture, not two things that come and go.
  node
  (kind :rect)
  ;; device pixels
  (x 0) (y 0) (width 0) (height 0)
  ;; where surface-local (0,0) is, in device pixels (buffer items)
  (surface-x 0) (surface-y 0)
  surface
  buffer
  (transform 0)
  colour
  octets
  ;; the bitmap's own pixel size, when it is not its drawn size (the cursor)
  (source-width 0) (source-height 0)
  ;; device rectangles this item hides completely (opaque culling)
  opaque
  ;; device rectangles this item's content changed in since the last frame
  damage
  (cursor-p nil)
  ;; the region this item is drawn through; NIL means "unclipped"
  clip)

(defun draw-item-signature (item)
  "What has to stay equal for two frames to draw the same pixels for ITEM.

Geometry is compared separately (the damage diff needs the old rectangle as well
as the new one); this is the *content*: which buffer, which bitmap, which colour."
  (list (draw-item-kind item)
        (draw-item-surface item)
        (draw-item-buffer item)
        (draw-item-transform item)
        (draw-item-colour item)
        (draw-item-octets item)
        (draw-item-width item)
        (draw-item-height item)))

(declaim (inline scale-coordinate))
(defun scale-coordinate (value scale)
  "VALUE in layout coordinates as a device pixel index, rounded to nearest."
  (round (* value scale)))

(defun scale-length (value scale)
  "VALUE as a device length, at least one pixel: a visible thing is never zero wide."
  (max 1 (round (* value scale))))

(defun surface-local-rect-to-device (rect surface-x surface-y scale)
  "RECT (X Y WIDTH HEIGHT), surface-local, as a device rectangle.

SURFACE-X/Y are where the surface's own origin is in device pixels, so this needs
no origin for the node: a damage rectangle or an opaque region is relative to the
surface, which is relative to nothing else."
  (destructuring-bind (x y width height) rect
    (list (+ surface-x (scale-coordinate x scale))
          (+ surface-y (scale-coordinate y scale))
          (scale-length width scale)
          (scale-length height scale))))

(defun opaque-rects-from-surface (surface surface-x surface-y scale)
  "SURFACE's committed opaque region as device rectangles; NIL when it hides nothing.

An XRGB8888 buffer is opaque everywhere by definition -- its alpha bits are
undefined and must not be blended -- so a client need not set a region to get the
benefit.  An ARGB buffer hides only what the client says it does (D48)."
  (let ((buffer (and surface (surface-current-buffer surface))))
    (when buffer
      (if (= (shm-buffer-format buffer) 1)
          (multiple-value-bind (layout-width layout-height) (surface-layout-size surface)
            (list (list surface-x surface-y
                        (scale-length layout-width scale)
                        (scale-length layout-height scale))))
          (let ((region (surface-opaque-region surface)))
            (when region
              (loop for rect in region
                    collect (surface-local-rect-to-device rect surface-x surface-y scale))))))))

(defun make-buffer-item (node surface scale)
  "A draw item for SURFACE drawn at NODE's position, in device pixels."
  (let* ((buffer (surface-current-buffer surface))
         (buffer-scale (max 1 (or (surface-buffer-scale surface) 1)))
         (node-x (scale-coordinate (node-x node) scale))
         (node-y (scale-coordinate (node-y node) scale))
         (x (scale-coordinate (+ (node-x node) (surface-current-x surface)) scale))
         (y (scale-coordinate (+ (node-y node) (surface-current-y surface)) scale))
         (transform (or (surface-buffer-transform surface) 0)))
    ;; A rotated buffer occupies the swapped rectangle: the client's bytes are
    ;; width x height, the space they fill is the other way round.
    (multiple-value-bind (display-width display-height)
        (render:buffer-display-size (shm-buffer-width buffer) (shm-buffer-height buffer)
                                    transform)
      (%make-draw-item
       :node node
       :kind :buffer
       :surface surface
       :buffer buffer
       :transform transform
       ;; The destination size is what the client's pixels occupy *now*: its own
       ;; buffer scale divided out, the output's scale multiplied in (D49).
       :x x :y y
       :width (max 1 (round (/ (* display-width scale) buffer-scale)))
       :height (max 1 (round (/ (* display-height scale) buffer-scale)))
       :surface-x node-x
       :surface-y node-y
       :opaque (opaque-rects-from-surface surface node-x node-y scale)
       :damage (loop for rect in (surface-damage-since-frame surface)
                     collect (surface-local-rect-to-device rect node-x node-y scale))
       :cursor-p nil))))

(defun client-cursor-usable-p (surface)
  "Is SURFACE a pointer image that can be drawn right now?

A cursor surface is a wl_surface like any other: it needs a current buffer, and it
must not have been destroyed.  It is deliberately *not* held to SURFACE-MAPPED-P:
that predicate is about a surface's role being mapped, and a cursor image is not a
window -- it is drawn whenever the client has put pixels in it."
  (and surface
       (not (resource-destroyed-p surface))
       (surface-current-buffer surface)))

(defun make-cursor-item (scene scale)
  "The pointer's item: the client's image when there is one, the arrow otherwise.

The built-in arrow is drawn at 16x16 layout pixels -- it is a cursor, not a
client's pixels -- so it grows with the output scale instead of being resampled to
some other size (nearest-neighbour, so it stays an arrow)."
  (let ((cursor (scene-cursor scene))
        (surface (scene-cursor-surface scene)))
    (cond
      ((client-cursor-usable-p surface)
       (let* ((buffer (surface-current-buffer surface))
              (buffer-scale (max 1 (or (surface-buffer-scale surface) 1)))
              (transform (or (surface-buffer-transform surface) 0))
              ;; The hotspot is in layout coordinates, so it is subtracted
              ;; *before* scaling: that is what makes it mean what the protocol
              ;; says it means.
              (x (scale-coordinate (- (node-x cursor) (scene-cursor-hotspot-x scene)) scale))
              (y (scale-coordinate (- (node-y cursor) (scene-cursor-hotspot-y scene)) scale)))
         (multiple-value-bind (display-width display-height)
             (render:buffer-display-size (shm-buffer-width buffer) (shm-buffer-height buffer)
                                         transform)
           (%make-draw-item
            :node cursor
            :kind :buffer
            :surface surface
            :buffer buffer
            :transform transform
            :x x :y y
            :width (max 1 (round (/ (* display-width scale) buffer-scale)))
            :height (max 1 (round (/ (* display-height scale) buffer-scale)))
            :surface-x x
            :surface-y y
            :damage (loop for rect in (surface-damage-since-frame surface)
                          collect (surface-local-rect-to-device rect x y scale))
            :cursor-p t))))
      ((and (scene-cursor-visible-p scene) (node-visible-p cursor))
       (%make-draw-item
        :node cursor
        :kind :image
        :x (scale-coordinate (node-x cursor) scale)
        :y (scale-coordinate (node-y cursor) scale)
        :width (scale-length (node-width cursor) scale)
        :height (scale-length (node-height cursor) scale)
        :octets (image-node-octets cursor)
        :source-width (node-width cursor)
        :source-height (node-height cursor)
        :cursor-p t))
      (t nil))))

;;; ---------------------------------------------------------------------------
;;; Pictures we own: a snapshot of a client's buffer, taken once
;;; ---------------------------------------------------------------------------
;;
;; A thumbnail is a *copy*, and the copy is the design (D52).  Drawing the client's
;; buffer straight into a small rectangle looks simpler and is wrong three ways: the
;; buffer changes whenever the client draws, so the item's signature changes and the
;; panel repaints on every client frame; the client may destroy the buffer while the
;; overlay is up; and the result is a picture whose freshness depends on what else
;; happened to be damaged that frame.  Copying once, at the resolution it will be
;; shown at, makes the thumbnail a constant -- and a constant is something a damage
;; diff can reason about.

(defun buffer-drawable-p (buffer)
  "Can BUFFER be read as pixels right now?

A buffer is pixels when its pool is still mapped and the buffer has not been
destroyed.  The protocol's state machine refuses everything else, but a buffer can
outlive the mapping that gave it a pointer for a moment, and a snapshot must not be
the thing that follows it there."
  (and buffer
       (not (resource-destroyed-p buffer))
       (plusp (shm-buffer-width buffer))
       (plusp (shm-buffer-height buffer))
       (let ((pool (shm-buffer-pool buffer)))
         (and pool (shm-pool-mapping pool) t))))

(defun snapshot-surface (surface width height &key (scale 1))
  "SURFACE's current buffer, downscaled into a WIDTH x HEIGHT layout box.

Three values -- (values OCTETS PIXEL-WIDTH PIXEL-HEIGHT), premultiplied ARGB8888 at
the output's resolution for that box -- or NIL when there are no pixels to take.

SCALE is the output's scale, so a 72x48 box on a scale-2 output becomes a 144x96
picture: the resolution it will be drawn at, never more and never less.  Drawing it
is then a 1:1 copy with no filter, which is why the resample happens here, once per
opening, instead of once per frame.

The filter is bilinear, and that is a judgement about pictures rather than text: a
window's content is not a glyph grid, so nearest-neighbour turns a downscaled title
bar into a row of dropped pixels.  Text is the case where nearest is right (D51); a
picture is the case where it is not."
  (let ((buffer (and surface (surface-current-buffer surface))))
    (when (buffer-drawable-p buffer)
      (let* ((pixel-width (scale-length width scale))
             (pixel-height (scale-length height scale))
             (target (render:make-target pixel-width pixel-height)))
        (unwind-protect
             (progn
               (render:composite-buffer target buffer
                                        :width pixel-width :height pixel-height
                                        :transform (or (surface-buffer-transform surface) 0)
                                        :filter :bilinear)
               (values (render:target-octets-copy target)
                       pixel-width pixel-height))
          (render:destroy-target target))))))

(defun make-bitmap-item (node x y scale)
  "A draw item for bitmap NODE whose accumulated parent position is layout (X, Y).

The picture's own size and the size it is drawn are two different numbers: the
cursor's are 16x16 pixels into 16x16 layout coordinates (so 32x32 device at scale
2), a snapshot's are equal by construction, and neither is the other's business."
  (let ((width (scale-length (node-width node) scale))
        (height (scale-length (node-height node) scale))
        (source-width (bitmap-node-source-width node))
        (source-height (bitmap-node-source-height node)))
    (%make-draw-item :node node
                     :kind :image
                     :x (scale-coordinate x scale)
                     :y (scale-coordinate y scale)
                     :width width :height height
                     :octets (bitmap-node-octets node)
                     :source-width (if (plusp source-width) source-width width)
                     :source-height (if (plusp source-height) source-height height)
                     :cursor-p nil)))

(defun collect-draw-items (node base-x base-y scale items)
  "Push NODE's subtree's draw items onto ITEMS, back to front; return ITEMS."
  (when (node-visible-p node)
    (let ((x (+ base-x (node-x node)))
          (y (+ base-y (node-y node))))
      (cond
        ((tree-node-p node)
         (dolist (child (node-children node))
           (setf items (collect-draw-items child x y scale items))))
        ((buffer-node-p node)
         (let ((surface (buffer-node-surface node)))
           (when (and surface (surface-mapped-p surface) (surface-current-buffer surface))
             (push (make-buffer-item node surface scale) items))))
        ((rect-node-p node)
         (let* ((colour (rect-node-color node))
                (x0 (scale-coordinate x scale))
                (y0 (scale-coordinate y scale))
                (w (scale-length (node-width node) scale))
                (h (scale-length (node-height node) scale)))
           (push (%make-draw-item
                  :node node
                  :kind :rect
                  :x x0 :y y0 :width w :height h
                  :colour colour
                  ;; A rectangle with a translucent colour hides nothing; an
                  ;; opaque one hides everything under it.
                  :opaque (when (= 255 (ldb (byte 8 24) colour))
                            (list (list x0 y0 w h)))
                  :cursor-p nil)
                 items)))
        ((bitmap-node-p node)
         ;; A cursor image and a window's snapshot are the same kind of thing to
         ;; the renderer -- our pixels, drawn into a device rectangle -- and differ
         ;; only in whether that rectangle is the picture's own size (D52).
         (push (make-bitmap-item node x y scale) items))
        ((text-node-p node)
         ;; Rasterised at the output's scale and drawn 1:1: a glyph cell is
         ;; SCALE x SCALE device pixels, so text is crisp at scale 2 rather than
         ;; an upscaled 5x7 picture (D51).  Empty text has no item at all.
         (multiple-value-bind (octets width height) (text-node-raster node scale)
           (when (and (plusp width) (plusp height))
             (push (%make-draw-item :node node
                                    :kind :image
                                    :x (scale-coordinate x scale)
                                    :y (scale-coordinate y scale)
                                    :width width :height height
                                    :octets octets
                                    :source-width width
                                    :source-height height
                                    :cursor-p nil)
                   items))))))
    items))

(defun scene-draw-list (scene &key (scale nil))
  "Everything the scene would draw this frame, back to front, in device pixels.

Three lists in one order, and the order is the whole point: the tree (the
desktop), then the overlay (what is drawn over it, D51), then the cursor.  The
cursor and the overlay are the two things outside the tree, and neither is ever
hit-tested (D31).  This one list is what the damage diff and the draw both read,
so they cannot disagree about what a frame contains (D48)."
  (let* ((scale (or scale (scene-scale scene)))
         ;; SETF, not a bare call: PUSH extends a *local* head, so the returned
         ;; list is the only one that has the tree's items in it (the same trap
         ;; RENDER-NODE documented before this list existed).
         (items (nreverse (collect-draw-items (scene-root scene) 0 0 scale nil)))
         (overlay (nreverse (collect-draw-items (scene-overlay scene) 0 0 scale nil)))
         (cursor (make-cursor-item scene scale)))
    ;; Appended, not pushed: the cursor is drawn *after* everything in the tree,
    ;; and a pointer that is drawn under a window is a pointer nobody can see.
    (append items overlay (if cursor (list cursor) nil))))

;;; ---------------------------------------------------------------------------
;;; Damage: what changed since the last frame
;;; ---------------------------------------------------------------------------

(defun item-rect (item)
  "ITEM's device rectangle as (X Y WIDTH HEIGHT)."
  (list (draw-item-x item) (draw-item-y item)
        (draw-item-width item) (draw-item-height item)))

(defun same-rect-p (a b)
  (and (= (draw-item-x a) (draw-item-x b))
       (= (draw-item-y a) (draw-item-y b))
       (= (draw-item-width a) (draw-item-width b))
       (= (draw-item-height a) (draw-item-height b))))

(defun item-order (items)
  "The nodes of ITEMS, in order: what has to be equal for stacking not to change."
  (mapcar #'draw-item-node items))

(defun scene-damage-between (previous current into)
  "Union into INTO the pixels that differ between PREVIOUS and CURRENT; returns INTO.

Returns :FULL instead when the whole output has to be repainted: a stacking change
(raising a window uncovers the pixels under it and covers the pixels over it, and
a rectangle diff cannot see either).  The first frame is the caller's business --
an empty scene and a never-drawn scene have the same item list, and only the
compositor knows which it has (D48).

Two sources of damage, and both are needed.  *Geometry* -- a node that is new,
gone or somewhere else -- is the difference between the two lists, which is why
moving a window, moving a popup or moving the pointer needs no bookkeeping at all.
*Content* -- a client that repainted part of its window -- is the damage the client
itself reported at commit, carried on the item.  A frame with no damage is a frame
with nothing to draw (D48)."
  (cond
    ((not (equal (item-order previous) (item-order current))) :full)
    (t
     (dolist (item current)
       (let ((old (find (draw-item-node item) previous :key #'draw-item-node)))
         (cond
           ((null old)
            (render:region-add-box into (item-rect item)))
           (t
            (unless (same-rect-p old item)
              (render:region-add-box into (item-rect old))
              (render:region-add-box into (item-rect item)))
            (unless (equal (draw-item-signature old) (draw-item-signature item))
              (render:region-add-box into (item-rect item)))
            (dolist (rect (draw-item-damage item))
              (render:region-add-box into rect))))))
     (dolist (old previous)
       (unless (find (draw-item-node old) current :key #'draw-item-node)
         (render:region-add-box into (item-rect old))))
     into)))

(defun scene-consume-damage (items)
  "Clear the content damage ITEMS carried, after a frame has painted it.

Called once per drawn frame, not per built list: a frame that could not be drawn
(no buffer from the parent yet) must keep its damage for the frame that can."
  (dolist (item items)
    (let ((surface (draw-item-surface item)))
      (when surface
        (setf (surface-damage-since-frame surface) nil))))
  nil)

;;; ---------------------------------------------------------------------------
;;; The draw
;;; ---------------------------------------------------------------------------

(defun scene-background-region (scene items damage)
  "Where the output's background is visible this frame: DAMAGE minus everything opaque.

The background is the bottom layer of a frame, so it is needed exactly where no item
paints over it opaquely -- and painted anywhere else it is a full-screen write that the
next item overwrites.  On a 3840x2160 VT with a 1630x1631 client that is the largest
single piece of work in a frame and the half of it that never reaches a pixel: the
client's own opaque region covered its whole window (D68).  DAMAGE is a region, or NIL
for the whole output.

The answer belongs to SCENE and is valid until the next call, which is what lets one
scratch region serve it: the caller paints it and nothing else."
  (let ((region (scene-region scene 0))
        (box (scene-region scene 1)))
    (if damage
        (render:region-copy region damage)
        ;; Device pixels, not layout: a scale-2 output fills a target twice the size of
        ;; its coordinate space, and a clip in layout coordinates would fill a quarter
        ;; of it -- which the old unclipped fill could not have got wrong (D68).
        (render:region-set-rect region 0 0
                                (* (scene-width scene) (scene-scale scene))
                                (* (scene-height scene) (scene-scale scene))))
    (dolist (item items)
      (dolist (rect (draw-item-opaque item))
        (render:region-set-rect box (first rect) (second rect)
                                (third rect) (fourth rect))
        (render:region-subtract region region box)))
    region))

(defun scene-clip-regions (scene items damage)
  "One clip per item: its rectangle, minus everything opaque above it, minus damage.

Front to back, because that is the only order in which \"what is above\" is known
without looking ahead: the region covered so far is the union of the opaque
rectangles already passed.  A NIL clip means \"draw the item as it is\" -- no clip
is needed when nothing opaque is above it and the whole output is being repainted,
which is the common frame (D48)."
  (let* ((count (length items))
         (clips (make-list count))
         ;; Region 0 is SCENE-BACKGROUND-REGION's answer for this frame, so the clip
         ;; arithmetic starts at 1 and never overwrites it while it is being painted.
         ;; Region 1 doubles as that function's own scratch box, which is free by then:
         ;; the background is computed and painted before any clip is worked out.
         (covered (scene-region scene 1))
         (visible (scene-region scene 2))
         (pool-index 3))
    (render:region-clear covered)
    (loop for index from (1- count) downto 0
          for item = (nth index items)
          do (if damage
                 (render:region-intersect-rect
                  visible damage
                  (draw-item-x item) (draw-item-y item)
                  (draw-item-width item) (draw-item-height item))
                 (render:region-set-rect
                  visible
                  (draw-item-x item) (draw-item-y item)
                  (draw-item-width item) (draw-item-height item)))
             (render:region-subtract visible visible covered)
             (setf (nth index clips)
                   (cond
                     ;; :empty is "not drawn at all"; NIL is "drawn unclipped".
                     ((render:region-empty-p visible) :empty)
                     ((and (null damage) (render:region-empty-p covered)) nil)
                     (t (let ((clip (scene-region scene pool-index)))
                          (incf pool-index)
                          (render:region-copy clip visible)))))
             (dolist (rect (draw-item-opaque item))
               (render:region-add-box covered rect)))
    clips))

(defun draw-item (target item)
  "Draw ITEM through its clip, if it has one."
  (let ((clip (draw-item-clip item)))
    (if clip
        (render:target-set-clip target clip)
        (render:target-clear-clip target)))
  (ecase (draw-item-kind item)
    (:buffer
     (render:composite-buffer target (draw-item-buffer item)
                              :x (draw-item-x item)
                              :y (draw-item-y item)
                              :width (draw-item-width item)
                              :height (draw-item-height item)
                              :transform (draw-item-transform item)))
    (:rect
     (render:fill-rect target (draw-item-x item) (draw-item-y item)
                       (draw-item-width item) (draw-item-height item)
                       (draw-item-colour item)))
    (:image
     (render:composite-bitmap target (draw-item-octets item)
                              (draw-item-source-width item)
                              (draw-item-source-height item)
                              :x (draw-item-x item) :y (draw-item-y item)
                              :dest-width (draw-item-width item)
                              :dest-height (draw-item-height item)))))

(defun scene-render-items (scene target &key items damage)
  "Draw ITEMS onto TARGET; return the surfaces to release and present.

DAMAGE is a region in device pixels, or NIL for \"the whole target\".  An item with
an empty clip after damage and occlusion is not drawn at all -- but its surface is
still returned, because a client whose window is hidden behind another still has to
get its buffer back and its frame callback (D25).

The cursor is drawn last and is not returned: the compositor holds a cursor image
until the client replaces it rather than releasing it per frame, which is what
cursor images expect (D41)."
  (let* ((items (or items (scene-draw-list scene)))
         (clips (scene-clip-regions scene items damage))
         (drawn '()))
    (loop for item in items
          for clip in clips
          do (setf (draw-item-clip item) (if (eq clip :empty) nil clip))
             (unless (eq clip :empty)
               (draw-item target item))
             (when (and (eq (draw-item-kind item) :buffer)
                        (not (draw-item-cursor-p item)))
               (push (draw-item-surface item) drawn)))
    (render:target-clear-clip target)
    (nreverse drawn)))

(defun scene-render (scene target &key (scale nil) damage items)
  "Draw the scene onto TARGET; returns (values drawn-surfaces items).

The one call for a compositor that does not track damage: SCENE-DRAW-LIST plus
SCENE-RENDER-ITEMS with the whole target as the damage."
  (let ((items (or items (scene-draw-list scene :scale scale))))
    (values (scene-render-items scene target :items items :damage damage)
            items)))
;;; ---------------------------------------------------------------------------
;;; The built-in cursor
;;; ---------------------------------------------------------------------------
;;
;; No theme, no libxcursor, no Xcursor files: phase 3 needs one cursor that is
;; visibly a pointer and provably drawn last, and a 16x16 arrow from a table is
;; both.  Phase 5 replaces the table with theme lookup (docs/framework.md §5);
;; the node, the hotspot and the composite-last rule stay.

(defparameter +cursor-shape+
  '("X..............."
    "XX.............."
    "XWX............."
    "XWWX............"
    "XWWWX..........."
    "XWWWWX.........."
    "XWWWWWX........."
    "XWWWWWWX........"
    "XWWWWWWWX......."
    "XWWWWWWWWX......"
    "XWWWWWWWWWX....."
    "XWWWWWXXXXX....."
    "XWWXWWX........."
    "XWX.XWWX........"
    "XX..XWWX........"
    "X....XX.........")
  "The arrow: X is an opaque black outline, W opaque white, . transparent.")

(defun make-cursor-image ()
  "The cursor as premultiplied ARGB8888 octets, row-major, 16 x 16.

Both colours are opaque, so premultiplied and straight are the same numbers --
which is why this table can be written by hand without lying about colour."
  (let ((octets (make-array (* 4 +cursor-width+ +cursor-height+)
                            :element-type '(unsigned-byte 8)
                            :initial-element 0)))
    (loop for row in +cursor-shape+
          for y from 0
          do (loop for character across row
                   for x from 0
                   do (let ((argb (case character
                                    (#\X #xFF000000)
                                    (#\W #xFFFFFFFF)
                                    (t 0)))
                            (offset (* 4 (+ x (* +cursor-width+ y)))))
                        (when (plusp argb)
                          (setf (aref octets offset)          (ldb (byte 8 0) argb)
                                (aref octets (+ offset 1))     (ldb (byte 8 8) argb)
                                (aref octets (+ offset 2))     (ldb (byte 8 16) argb)
                                (aref octets (+ offset 3))     (ldb (byte 8 24) argb))))))
    octets))
