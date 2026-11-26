;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cf.scene v0: a retained node tree per output (docs/framework.md §4).
;;;;
;;;; Four node kinds are enough for a tinywl-shaped compositor and for the
;;;; compositing that phase 2a already did:
;;;;
;;;;   TREE-NODE    a group with children, drawn in order: the root is one
;;;;   BUFFER-NODE  a mapped wl_surface, drawn from its current buffer
;;;;   RECT-NODE    a solid rectangle: backgrounds, borders, letterboxing
;;;;   IMAGE-NODE   premultiplied ARGB8888 pixels: the software cursor
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

(defclass image-node (scene-node)
  ((octets :initarg :octets :reader image-node-octets)
   (width :initarg :width :accessor node-width)
   (height :initarg :height :accessor node-height))
  (:documentation
   "Premultiplied ARGB8888 pixels owned by us, not by a client: today only the
software cursor, because a cursor is composited last and must not be a client
surface (a client may set a cursor *surface*, which is a different object --
phase 5)."))

;;; ---------------------------------------------------------------------------
;;; DEFCLASS defines no type predicates (that is DEFSTRUCT), and the walk below
;;; reads better with names than with TYPEP forms in every branch.
(declaim (inline tree-node-p buffer-node-p rect-node-p image-node-p))
(defun tree-node-p (node) (typep node 'tree-node))
(defun buffer-node-p (node) (typep node 'buffer-node))
(defun rect-node-p (node) (typep node 'rect-node))
(defun image-node-p (node) (typep node 'image-node))

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
  (make-instance 'image-node :octets octets :width width :height height))

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

;;; ---------------------------------------------------------------------------
;;; The scene
;;; ---------------------------------------------------------------------------

(defclass scene ()
  ((width :initarg :width :accessor scene-width)
   (height :initarg :height :accessor scene-height)
   (root :initarg :root :reader scene-root)
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
   "One output's tree plus its cursor.

The output size is here because the scene is the thing that knows what fits;
SCALE is the device pixels per layout coordinate; the compositor still owns the
target, the background fill and the frame clock."))

(defun make-scene (width height &key (cursor-image (make-cursor-image)) (scale 1))
  "A scene for a WIDTH x HEIGHT output at SCALE device pixels per coordinate."
  (let* ((root (make-instance 'tree-node))
         (cursor (make-instance 'image-node
                                :octets cursor-image
                                :width +cursor-width+
                                :height +cursor-height+)))
    (make-instance 'scene :width width :height height :scale scale
                          :root root :cursor cursor)))

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

(defun set-node-position (node x y)
  "Move NODE; returns it."
  (setf (node-x node) x
        (node-y node) y)
  node)

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
        ((image-node-p node)
         (push (%make-draw-item :node node :kind :image
                                :x (scale-coordinate x scale)
                                :y (scale-coordinate y scale)
                                :width (scale-length (node-width node) scale)
                                :height (scale-length (node-height node) scale)
                                :octets (image-node-octets node)
                                :source-width (node-width node)
                                :source-height (node-height node)
                                :cursor-p nil)
               items))))
    items))

(defun scene-draw-list (scene &key (scale nil))
  "Everything the scene would draw this frame, back to front, in device pixels.

The cursor comes last, after everything in the tree, and it is the only item that
is not in the tree: a pointer is above every window and must never be hit-tested
(D31).  The list is what the damage diff and the draw both read, so they cannot
disagree about what a frame contains (D48)."
  (let* ((scale (or scale (scene-scale scene)))
         ;; SETF, not a bare call: PUSH extends a *local* head, so the returned
         ;; list is the only one that has the tree's items in it (the same trap
         ;; RENDER-NODE documented before this list existed).
         (items (nreverse (collect-draw-items (scene-root scene) 0 0 scale nil)))
         (cursor (make-cursor-item scene scale)))
    ;; Appended, not pushed: the cursor is drawn *after* everything in the tree,
    ;; and a pointer that is drawn under a window is a pointer nobody can see.
    (if cursor (append items (list cursor)) items)))

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

(defun scene-clip-regions (scene items damage)
  "One clip per item: its rectangle, minus everything opaque above it, minus damage.

Front to back, because that is the only order in which \"what is above\" is known
without looking ahead: the region covered so far is the union of the opaque
rectangles already passed.  A NIL clip means \"draw the item as it is\" -- no clip
is needed when nothing opaque is above it and the whole output is being repainted,
which is the common frame (D48)."
  (let* ((count (length items))
         (clips (make-list count))
         (covered (scene-region scene 0))
         (visible (scene-region scene 1))
         (pool-index 2))
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
