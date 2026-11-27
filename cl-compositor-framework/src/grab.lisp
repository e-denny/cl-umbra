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
  ((node :initarg :node :initform nil :reader grab-node)
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
;;; Popup grabs
;;;
;;; An explicit grab (xdg_popup.grab) is an *owner-events* grab: the popup's client
;;; hears the pointer as usual, and a press outside the popup's stack dismisses it
;;; instead of reaching the window underneath.  The class lives here because it is
;;; an interaction with a lifetime; its methods live in the compositor, because they
;;; need a seat, a scene and a dismissal -- this package has none of those.

(defclass popup-grab (grab)
  ((popup :initarg :popup :reader popup-grab-popup)
   ;; Buttons whose press this grab swallowed -- the press that dismissed the popup.
   ;; Its release must be swallowed too: a client that never saw a press must not
   ;; see a release, and the client that *did* see the press has been dismissed.
   (swallowed :initform nil :accessor popup-grab-swallowed))
  (:documentation
   "The interaction a client's xdg_popup.grab owns the pointer with.

It does not move or resize anything: it decides who hears each event, and it ends
when the popup is dismissed.  GRAB-MOTION, GRAB-BUTTON and GRAB-KEY are specialised
by the compositor (cf.backend.headless), which is where the pointer, the scene and
the popup's stack are."))

(defun begin-popup-grab (popup &key (button #x110))
  "A grab for POPUP.  The button is what the client's user action used; it is only a
record, because the popup's grab ends by dismissal, not by release."
  (make-instance 'popup-grab :popup popup :button button))

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

(defun clamp-node-to-output (node output-width output-height)
  "Move NODE so its window's *visible* box stays inside the output; returns NODE.

The node's position is where its buffer starts, and a decorated client's buffer starts
earlier than its window (a shadow): clamping the node would leave the shadow's width
of slack, so the arithmetic is in window geometry and the node is placed back from it
(D43, D46).  A window larger than the output is placed so it covers the output rather
than sliding off it, which is CLAMP-TO-OUTPUT's rule.

Either output dimension may be NIL, meaning 'do not clamp on that axis'."
  (multiple-value-bind (geometry-x geometry-y width height) (node-geometry node)
    (let ((x (scene:node-x node))
          (y (scene:node-y node)))
      (when output-width
        (setf x (- (clamp-to-output (+ x geometry-x) (max 1 width) output-width)
                   geometry-x)))
      (when output-height
        (setf y (- (clamp-to-output (+ y geometry-y) (max 1 height) output-height)
                   geometry-y)))
      (scene:set-node-position node x y))))

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
  (let ((node (grab-node grab)))
    (scene:set-node-position node
                             (+ (move-grab-origin-x grab) (- x (move-grab-start-x grab)))
                             (+ (move-grab-origin-y grab) (- y (move-grab-start-y grab))))
    (when (or (move-grab-output-width grab) (move-grab-output-height grab))
      (clamp-node-to-output node (move-grab-output-width grab) (move-grab-output-height grab)))
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
   ;; The size the client is believed to have: updated only when a commit shows it
   ;; has changed, so a commit that is a repaint and nothing else does not undo a
   ;; placement made for a request still in flight (D53).
   (seen-width :initarg :seen-width :accessor resize-grab-seen-width)
   (seen-height :initarg :seen-height :accessor resize-grab-seen-height)
   ;; The edge that must not move: the opposite one's position at the start.  A
   ;; resize from the left edge keeps the right edge where it was, so the node's
   ;; position is derived from it and the client's *actual* size (D42).
   (anchor-right :initarg :anchor-right :reader resize-grab-anchor-right)
   (anchor-bottom :initarg :anchor-bottom :reader resize-grab-anchor-bottom)
   ;; The *other* pair, in output space: the edge a drag pushes is the one that must
   ;; stop at the output's border, so its maximum is measured from here (D46).
   (anchor-left :initarg :anchor-left :initform nil :reader resize-grab-anchor-left)
   (anchor-top :initarg :anchor-top :initform nil :reader resize-grab-anchor-top)
   ;; The output the node lives in, when the caller knows it: a resize, like a move,
   ;; is clamped to it.  NIL means unbounded, as for MOVE-GRAB.
   (output-width :initarg :output-width :initform nil :reader resize-grab-output-width)
   (output-height :initarg :output-height :initform nil :reader resize-grab-output-height))
  (:documentation
   "An interactive resize from EDGES (an xdg_toplevel.resize_edge bitmask).

A resize asks the client for a size and the client answers with one, so the node's
size is not the grab's to set.  What the grab *can* do is keep the edge opposite the
one being dragged still while the dragged edge follows the pointer: dragging the left
edge moves the window's left side under the hand and lets its right side stay put.

The placement happens twice, and the two calls are different questions.  On every
motion the window is placed at the size the drag *asked for* (PLACE-ANCHORED with the
requested size), so the edge under the pointer is under the pointer now rather than
one configure round trip later (D53).  When the client's answer arrives the window is
placed at the size the client *chose* (GRAB-ANCHORED), which is the same place for a
client that honours the configure and keeps the anchored edge exact for one that does
not (D42).

What is inside the window is the client's: while the answer is in flight the content
is still the old size, so it is either short of the far edge or overlapping it by the
difference.  That is the trade this makes -- the hand leads, the pixels follow -- and
it is what every compositor with client-side decorations shows."))

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

(defun begin-resize-grab (node x y edges &key (button #x110) (min-width 1) (min-height 1)
                                          output-width output-height)
  "A resize grab for NODE from EDGES, with the pointer starting at (X, Y) in output space.

OUTPUT-WIDTH and OUTPUT-HEIGHT bound the drag: the edge under the pointer stops at the
output's border, with the opposite edge anchored where it is (D46).  NIL means
unbounded, which is what a compositor that does not know its output gets."
  (multiple-value-bind (geometry-x geometry-y width height) (node-geometry node)
    (make-instance 'resize-grab
                   :node node
                   :button button
                   :start-x x
                   :start-y y
                   :start-width (max 1 width)
                   :start-height (max 1 height)
                   :seen-width (max 1 width)
                   :seen-height (max 1 height)
                   :edges edges
                   :min-width min-width
                   :min-height min-height
                   ;; The anchored edges are the *geometry's*, in output space: that is
                   ;; the edge a person sees and drags.
                   :anchor-left (+ (scene:node-x node) geometry-x)
                   :anchor-top (+ (scene:node-y node) geometry-y)
                   :anchor-right (+ (scene:node-x node) geometry-x width)
                   :anchor-bottom (+ (scene:node-y node) geometry-y height)
                   :output-width output-width
                   :output-height output-height)))

(defun resize-grab-max-size (grab)
  "The largest size a drag may ask for, as (values WIDTH HEIGHT) or NIL per axis.

The dragged edge may travel as far as the output's border and no further, with the
opposite edge anchored: dragging a right edge from x=100 in a 400-wide output asks for
at most 300, and dragging a left edge whose right edge is at 300 asks for at most 300.
This is the rule CLAMP-TO-OUTPUT applies to a move (D43), applied to the edge the
pointer is on -- a window cannot be resized out of reach any more than it can be
dragged out of reach."
  (let ((edges (resize-grab-edges grab))
        (output-width (resize-grab-output-width grab))
        (output-height (resize-grab-output-height grab)))
    (values
     (cond ((logtest +edge-right+ edges)
            (and output-width (- output-width (resize-grab-anchor-left grab))))
           ((logtest +edge-left+ edges)
            (resize-grab-anchor-right grab))
           (t nil))
     (cond ((logtest +edge-bottom+ edges)
            (and output-height (- output-height (resize-grab-anchor-top grab))))
           ((logtest +edge-top+ edges)
            (resize-grab-anchor-bottom grab))
           (t nil)))))

(defun resize-target-size (edges start-width start-height dx dy
                           &key (min-width 1) (min-height 1) max-width max-height)
  "The size a drag of (DX, DY) from EDGES asks for, clamped to the bounds.

A pure function on purpose: the arithmetic is the part that can be wrong in a
way a screenshot will not show.  MAX-WIDTH and MAX-HEIGHT are the output's terms
(see RESIZE-GRAB-MAX-SIZE); NIL means unbounded.  The minimum wins when the two
disagree, because a window smaller than its client's minimum is a window the client
cannot draw."
  (values
   (let ((wanted (cond ((logtest +edge-right+ edges) (+ start-width dx))
                       ((logtest +edge-left+ edges) (- start-width dx))
                       (t start-width))))
     (max min-width (if max-width (min wanted max-width) wanted)))
   (let ((wanted (cond ((logtest +edge-bottom+ edges) (+ start-height dy))
                       ((logtest +edge-top+ edges) (- start-height dy))
                       (t start-height))))
     (max min-height (if max-height (min wanted max-height) wanted)))))

(defun place-anchored (grab width height)
  "Put GRAB's node where the anchored edge says a WIDTH x HEIGHT window belongs.

WIDTH and HEIGHT are *window geometry* numbers, not buffer sizes, so a decorated
client's shadow stays outside the arithmetic (D42).  Only the edges being dragged
move the node: a right or bottom drag places nothing, because the anchored edge is
the left or top one and it has not moved.

This is the whole positioning rule of a resize, and it is a pure consequence of the
anchors taken when the grab began -- which is why it can be called with the size that
was asked for (during the drag) and with the size that came back (on the client's
answer) and mean something both times."
  (let ((node (grab-node grab))
        (edges (resize-grab-edges grab)))
    (multiple-value-bind (geometry-x geometry-y) (node-geometry node)
      (when (logtest +edge-left+ edges)
        (setf (scene:node-x node) (- (resize-grab-anchor-right grab)
                                     geometry-x
                                     (max 1 width))))
      (when (logtest +edge-top+ edges)
        (setf (scene:node-y node) (- (resize-grab-anchor-bottom grab)
                                     geometry-y
                                     (max 1 height)))))
    node))

(defgeneric grab-anchored (grab)
  (:documentation
   "Put the node back where the edge it is anchored to says it belongs, by its size.

The size is the node's *own* -- the client's answer -- so this is the call that makes
the anchored edge exact however the client answered.  Called when a commit arrives
for the grabbed surface; a grab that has no anchors (a move) does nothing.")
  (:method (grab) nil))

(defmethod grab-anchored ((grab resize-grab))
  "Keep the edge opposite the dragged one still, using the node's *actual* size.

Only when the client's size has actually changed: a commit that repaints without
resizing is a client doing its work, not an answer to the request in flight, and
re-placing the node for it would undo the placement the last motion made (D53)."
  (let ((node (grab-node grab)))
    (multiple-value-bind (geometry-x geometry-y width height) (node-geometry node)
      (declare (ignore geometry-x geometry-y))
      (unless (and (= (max 1 width) (resize-grab-seen-width grab))
                   (= (max 1 height) (resize-grab-seen-height grab)))
        (setf (resize-grab-seen-width grab) (max 1 width)
              (resize-grab-seen-height grab) (max 1 height))
        (place-anchored grab width height)))
    node))

(defmethod grab-motion ((grab resize-grab) x y)
  (multiple-value-bind (max-width max-height) (resize-grab-max-size grab)
    (multiple-value-bind (width height)
        (resize-target-size (resize-grab-edges grab)
                            (resize-grab-start-width grab)
                            (resize-grab-start-height grab)
                            (- x (resize-grab-start-x grab))
                            (- y (resize-grab-start-y grab))
                            :min-width (resize-grab-min-width grab)
                            :min-height (resize-grab-min-height grab)
                            :max-width max-width
                            :max-height max-height)
      (unless (and (= width (resize-grab-requested-width grab))
                   (= height (resize-grab-requested-height grab)))
        (setf (resize-grab-requested-width grab) width
              (resize-grab-requested-height grab) height)
        (grab-resize grab width height)
        ;; The dragged edge follows the *pointer*, not the answer (D53): the node is
        ;; placed at the size this drag asked for, so a left-edge drag has its left
        ;; edge under the hand now.  The client's content follows one configure later,
        ;; and when it does, GRAB-ANCHORED places the node by the size the client
        ;; chose -- the same place for a client that honours the request.
        (place-anchored grab width height)
        (grab-changed grab)))))
