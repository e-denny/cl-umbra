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
;;;; The tree is retained, not rebuilt per frame, because rules, workspaces,
;;;; overview and animations all need the node to exist between frames (D10).
;;;;
;;;; Deliberately *not* here yet: damage regions (the compositor repaints the
;;;; whole target, 2b), clip rectangles (pixman clips to the target, which is
;;;; enough until a node can overflow its parent), culling, and layers
;;;; (layer-shell arrives with the shell that needs them, phase 6).

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

(defmethod node-width ((node buffer-node))
  (let ((buffer (and (buffer-node-surface node)
                     (surface-current-buffer (buffer-node-surface node)))))
    (if buffer (shm-buffer-width buffer) 0)))

(defmethod node-height ((node buffer-node))
  (let ((buffer (and (buffer-node-surface node)
                     (surface-current-buffer (buffer-node-surface node)))))
    (if buffer (shm-buffer-height buffer) 0)))

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
   (cursor-hotspot-y :initform 0 :accessor scene-cursor-hotspot-y))
  (:documentation
   "One output's tree plus its cursor.

The output size is here because the scene is the thing that knows what fits; the
compositor still owns the target, the background fill and the frame clock."))

(defun make-scene (width height &key (cursor-image (make-cursor-image)))
  "A scene for a WIDTH x HEIGHT output, with the built-in cursor image."
  (let* ((root (make-instance 'tree-node))
         (cursor (make-instance 'image-node
                                :octets cursor-image
                                :width +cursor-width+
                                :height +cursor-height+)))
    (make-instance 'scene :width width :height height
                          :root root :cursor cursor)))

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
;;; Drawing
;;; ---------------------------------------------------------------------------

(defun node-drawn-surface (node)
  "The wl_surface NODE draws, or NIL for any other node kind."
  (and (buffer-node-p node) (buffer-node-surface node)))

(defun render-node (target node base-x base-y)
  "Draw NODE and its children at (BASE-X, BASE-Y); return the surfaces drawn.

The list is returned rather than pushed into a caller's variable, because a
pushed list is a *new* head: the caller would keep the old, empty one and the
compositor would never release the buffers it drew (found by the xdg gate: the
client stopped after one frame, waiting for a wl_buffer.release)."
  (let ((drawn '()))
    (when (node-visible-p node)
      (let ((x (+ base-x (node-x node)))
            (y (+ base-y (node-y node))))
        (cond
          ((tree-node-p node)
           (dolist (child (node-children node))
             (setf drawn (append drawn (render-node target child x y)))))
          ((buffer-node-p node)
           (let ((surface (buffer-node-surface node)))
             (when (and (surface-mapped-p surface)
                        (surface-current-buffer surface)
                        ;; The attach offset is the client's own coordinate: it
                        ;; says where its buffer sits inside the surface.
                        (render:composite-buffer target (surface-current-buffer surface)
                                                 :x (+ x (surface-current-x surface))
                                                 :y (+ y (surface-current-y surface))))
               (setf drawn (list surface)))))
          ((rect-node-p node)
           (render:fill-rect target x y (node-width node) (node-height node)
                             (rect-node-color node)))
          ((image-node-p node)
           (render:composite-bitmap target (image-node-octets node)
                                    (node-width node) (node-height node)
                                    :x x :y y)))))
    drawn))

(defun client-cursor-usable-p (surface)
  "Is SURFACE a pointer image that can be drawn right now?

A cursor surface is a wl_surface like any other: it needs a current buffer, and it
must not have been destroyed.  It is deliberately *not* held to SURFACE-MAPPED-P:
that predicate is about a surface's role being mapped, and a cursor image is not a
window -- it is drawn whenever the client has put pixels in it."
  (and surface
       (not (resource-destroyed-p surface))
       (surface-current-buffer surface)))

(defun scene-render (scene target)
  "Draw the scene onto TARGET; returns the list of surfaces that were drawn.

The cursor is drawn last, from its own node position: the client's image if the client
installed one, otherwise the built-in arrow and only when SCENE-CURSOR-VISIBLE-P.  A
client's image is drawn at (pointer - hotspot), which is what makes the hotspot mean
what the protocol says it means.  It is not returned as *drawn*: the compositor holds
a cursor image until the client replaces it rather than releasing it per frame, which
is what cursor images expect (D41)."
  (let ((drawn (render-node target (scene-root scene) 0 0)))
    (let ((surface (scene-cursor-surface scene)))
      (cond
        ((client-cursor-usable-p surface)
         (render:composite-buffer target (surface-current-buffer surface)
                                  :x (- (node-x (scene-cursor scene))
                                        (scene-cursor-hotspot-x scene))
                                  :y (- (node-y (scene-cursor scene))
                                        (scene-cursor-hotspot-y scene))))
        ((and (scene-cursor-visible-p scene)
              (node-visible-p (scene-cursor scene)))
         (setf drawn (append drawn (render-node target (scene-cursor scene) 0 0))))))
    drawn))

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
