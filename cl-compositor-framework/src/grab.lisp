;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Grabs: an interaction the pointer belongs to for a while (docs/framework.md
;;;; §5).  A grab is an object, not a modal flag, and it ends exactly once.
;;;;
;;;; v0 has the two a window manager cannot do without: move and resize, both
;;;; started by a client's validated xdg_toplevel.move/.resize request (D33).
;;;;
;;;; The split here is deliberate.  A grab knows about *nodes* and *sizes*; it does
;;;; not know about frames, seats or configure events.  Those are the compositor's,
;;;; and it learns about them through two notification hooks -- GRAB-CHANGED when
;;;; the interaction changed something that must be presented, and GRAB-RESIZE
;;;; when the client should be asked for a new size.  That is why this package can
;;;; be tested with a scene and no compositor at all.

(in-package #:cf.grab)

;;; ---------------------------------------------------------------------------
;;; The base class
;;; ---------------------------------------------------------------------------

(defclass grab ()
  ((node :initarg :node :reader grab-node)
   ;; The compositor that adopted this grab, set when it becomes active; the
   ;; compositor drops its own reference here rather than tracking a second list.
   (owner :initform nil :accessor grab-owner)
   ;; The button that started the grab: the grab ends when *it* is released, not
   ;; when any button is (a right-click during a drag must not end the drag).
   (button :initarg :button :initform #x110 :reader grab-button-code)
   (active-p :initform t :accessor grab-active-p))
  (:documentation
   "An interaction that owns the pointer until it ends.

It ends on the button that started it, or when the compositor ends it (an Escape
binding, the client going away).  END-GRAB is idempotent: two releases of the
same button, or a release racing a cancel, must not move a window twice."))

(defgeneric grab-motion (grab x y)
  (:documentation "The pointer moved to (X, Y) in output space."))

(defgeneric grab-button (grab button state)
  (:documentation
   "A pointer button event while GRAB holds the pointer.  Returns true if the
grab consumed it -- a release of the starting button does, and must not also be
delivered to the client as a click.")
  (:method ((grab grab) button state)
    (if (and (eq state :released) (= button (grab-button-code grab)))
        (progn (grab-end grab :reason :button-release) t)
        nil)))

(defgeneric grab-key (grab key-name state)
  (:documentation
   "A key event while GRAB holds the pointer; true when the grab consumed it.
The default consumes nothing: Escape ends a grab only because a compositor binds
it to END-GRAB, which is policy (D33).")
  (:method (grab key-name state)
    (declare (ignore grab key-name state))
    nil))

(defgeneric grab-changed (grab)
  (:documentation
   "The interaction changed something that has to be presented.  The default does
nothing, so a grab can be driven in a test with no compositor attached.")
  (:method (grab)
    (declare (ignore grab))
    nil))

(defgeneric grab-resize (grab width height)
  (:documentation
   "The interaction wants WIDTH x HEIGHT now.  For a client-drawn window that
means an xdg_toplevel.configure: the compositor cannot resize a buffer it does
not own.  The default does nothing.")
  (:method (grab width height)
    (declare (ignore grab width height))
    nil))

(defgeneric grab-ended (grab reason)
  (:documentation
   "GRAB has ended, for REASON.  Called exactly once per grab; a compositor uses
it to drop its own reference and release the pointer.")
  (:method (grab reason)
    (declare (ignore grab reason))
    nil))

(defun grab-end (grab &key reason)
  "End GRAB.  Idempotent: the second call does nothing and returns NIL."
  (when (grab-active-p grab)
    (setf (grab-active-p grab) nil)
    (grab-ended grab reason)
    t))

;;; ---------------------------------------------------------------------------
;;; Move
;;; ---------------------------------------------------------------------------

(defun clamp-to-output (position size output-size)
  "Where a window of SIZE may start, on one axis, to stay recoverable in OUTPUT-SIZE.

A window that fits inside the output is kept fully inside it -- dragged right, its
far edge stops at the output's.  A window larger than the output may be moved as far
as the output's opposite edge and no further, so it always covers the output instead
of sliding off it: a window you cannot see and cannot click is a window you cannot
get back (the sixth manual test's second finding, D43)."
  (let ((limit (- output-size size)))
    (max (min 0 limit) (min (max 0 limit) position))))

(defclass move-grab (grab)
  ((start-x :initarg :start-x :reader move-grab-start-x)
   (start-y :initarg :start-y :reader move-grab-start-y)
   (origin-x :initarg :origin-x :reader move-grab-origin-x)
   (origin-y :initarg :origin-y :reader move-grab-origin-y)
   ;; The output the node lives in, when the caller knows it: a move is clamped to it
   ;; so the window cannot be dragged out of reach.
   (output-width :initarg :output-width :initform nil :reader move-grab-output-width)
   (output-height :initarg :output-height :initform nil :reader move-grab-output-height))
  (:documentation
   "An interactive move: the node's position follows the pointer's delta.

The position is remembered at the start rather than accumulated per event, so a
lost motion event cannot leave the window drifting behind the pointer.  With an
output size it is clamped to it (CLAMP-TO-OUTPUT); without one the framework does not
know where the edges are and the position is free."))

(defun begin-move-grab (node x y &key (button #x110) output-width output-height)
  "A move grab for NODE, with the pointer starting at (X, Y) in output space."
  (make-instance 'move-grab
                 :node node
                 :button button
                 :start-x x
                 :start-y y
                 :origin-x (scene:node-x node)
                 :origin-y (scene:node-y node)
                 :output-width output-width
                 :output-height output-height))

(defmethod grab-motion ((grab move-grab) x y)
  (let* ((node (grab-node grab))
         (new-x (+ (move-grab-origin-x grab) (- x (move-grab-start-x grab))))
         (new-y (+ (move-grab-origin-y grab) (- y (move-grab-start-y grab))))
         (output-width (move-grab-output-width grab))
         (output-height (move-grab-output-height grab)))
    (when output-width
      (setf new-x (clamp-to-output new-x (scene:node-width node) output-width)))
    (when output-height
      (setf new-y (clamp-to-output new-y (scene:node-height node) output-height)))
    (scene:set-node-position node new-x new-y)
    (grab-changed grab)))

;;; ---------------------------------------------------------------------------
;;; Resize
;;; ---------------------------------------------------------------------------
;;
;; An interactive resize cannot resize a client's buffer: it configures a size
;; and the client comes back with one.  So the grab computes the size a drag is
;; asking for and hands it to the compositor, which sends the configure.

(defconstant +edge-top+ 1)
(defconstant +edge-bottom+ 2)
(defconstant +edge-left+ 4)
(defconstant +edge-right+ 8)

(defclass resize-grab (grab)
  ((start-x :initarg :start-x :reader resize-grab-start-x)
   (start-y :initarg :start-y :reader resize-grab-start-y)
   (start-width :initarg :start-width :reader resize-grab-start-width)
   (start-height :initarg :start-height :reader resize-grab-start-height)
   (edges :initarg :edges :reader resize-grab-edges)
   (min-width :initarg :min-width :initform 1 :reader resize-grab-min-width)
   (min-height :initarg :min-height :initform 1 :reader resize-grab-min-height)
   ;; Last size asked for, so a quiet pointer does not send a configure per event.
   (requested-width :initarg :start-width :accessor resize-grab-requested-width)
   (requested-height :initarg :start-height :accessor resize-grab-requested-height)
   ;; The edge that must not move: the opposite one's position at the start.  A
   ;; resize from the left edge keeps the right edge where it was, so the node's
   ;; position is derived from it and the client's *actual* size (D42).
   (anchor-right :initarg :anchor-right :reader resize-grab-anchor-right)
   (anchor-bottom :initarg :anchor-bottom :reader resize-grab-anchor-bottom))
  (:documentation
   "An interactive resize from EDGES (an xdg_toplevel.resize_edge bitmask).

A resize asks the client for a size and the client answers with one, so the node's
size is not the grab's to set.  What the grab *can* do is keep the edge opposite the
one being dragged still: dragging the left edge moves the window's left side while
its right side stays put, which is what a person sees themselves doing.  It is
anchored to the client's real size (GRAB-ANCHORED), not to the size requested, so
the window never slides while its content does not (D42)."))

(defun node-geometry (node)
  "The window NODE's geometry in its own coordinates: (values x y width height).

An `xdg_toplevel.configure` carries the *window geometry* of a surface, not its
buffer: a client with client-side decorations puts its shadow outside the geometry,
so a window whose buffer is 806 wide can have a 742-wide geometry and a 32-pixel
shadow either side.  Resize arithmetic in buffer coordinates therefore asks for the
wrong number by exactly the decoration: the client answers with a window 68 pixels
wider than asked, which is a jump on the first motion and a 1:1 drag afterwards (the
sixth manual test).  A surface that sets no geometry -- no decoration, or an older
client -- is its own buffer."
  (let* ((surface (and (typep node 'scene:buffer-node) (scene:buffer-node-surface node)))
         (shell (and surface (srv:surface-shell-surface surface)))
         (geometry (and shell (srv:xdg-surface-window-geometry shell))))
    (if geometry
        (values (first geometry) (second geometry) (third geometry) (fourth geometry))
        (values 0 0 (max 1 (scene:node-width node)) (max 1 (scene:node-height node))))))

(defun begin-resize-grab (node x y edges &key (button #x110) (min-width 1) (min-height 1))
  "A resize grab for NODE from EDGES, with the pointer starting at (X, Y)."
  (multiple-value-bind (geometry-x geometry-y width height) (node-geometry node)
    (make-instance 'resize-grab
                   :node node
                   :button button
                   :start-x x
                   :start-y y
                   :start-width (max 1 width)
                   :start-height (max 1 height)
                   :edges edges
                   :min-width min-width
                   :min-height min-height
                   ;; The anchored edge is the *geometry's*, in output space: that is
                   ;; the edge a person sees and drags.
                   :anchor-right (+ (scene:node-x node) geometry-x width)
                   :anchor-bottom (+ (scene:node-y node) geometry-y height))))

(defun resize-target-size (edges start-width start-height dx dy
                           &key (min-width 1) (min-height 1))
  "The size a drag of (DX, DY) from EDGES asks for, clamped to the minimum.

A pure function on purpose: the arithmetic is the part that can be wrong in a
way a screenshot will not show."
  (values
   (max min-width
        (cond ((logtest +edge-right+ edges) (+ start-width dx))
              ((logtest +edge-left+ edges) (- start-width dx))
              (t start-width)))
   (max min-height
        (cond ((logtest +edge-bottom+ edges) (+ start-height dy))
              ((logtest +edge-top+ edges) (- start-height dy))
              (t start-height)))))

(defgeneric grab-anchored (grab)
  (:documentation
   "Put the node back where the edge it is anchored to says it belongs.

Called after the request (nothing has changed yet, so it is cheap and harmless) and
again when the client's new size arrives, which is the call that matters: the size
is the client's, and this is how a compositor keeps the opposite edge still while
the client's answer comes back.")
  (:method (grab) nil))

(defmethod grab-anchored ((grab resize-grab))
  "Keep the edge opposite the dragged one still, using the node's *actual* size."
  (let ((node (grab-node grab))
        (edges (resize-grab-edges grab)))
    (multiple-value-bind (geometry-x geometry-y width height) (node-geometry node)
      (when (logtest +edge-left+ edges)
        (setf (scene:node-x node)
              (- (resize-grab-anchor-right grab) geometry-x (max 1 width))))
      (when (logtest +edge-top+ edges)
        (setf (scene:node-y node)
              (- (resize-grab-anchor-bottom grab) geometry-y (max 1 height)))))
    node))

(defmethod grab-motion ((grab resize-grab) x y)
  (multiple-value-bind (width height)
      (resize-target-size (resize-grab-edges grab)
                          (resize-grab-start-width grab)
                          (resize-grab-start-height grab)
                          (- x (resize-grab-start-x grab))
                          (- y (resize-grab-start-y grab))
                          :min-width (resize-grab-min-width grab)
                          :min-height (resize-grab-min-height grab))
    (unless (and (= width (resize-grab-requested-width grab))
                 (= height (resize-grab-requested-height grab)))
      (setf (resize-grab-requested-width grab) width
            (resize-grab-requested-height grab) height)
      (grab-resize grab width height)
      ;; The client's size may already be the new one (it may have answered the
      ;; previous event), so the anchor is applied on every motion as well as on
      ;; every size change.
      (grab-anchored grab)
      (grab-changed grab))))
