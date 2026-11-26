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

(defclass move-grab (grab)
  ((start-x :initarg :start-x :reader move-grab-start-x)
   (start-y :initarg :start-y :reader move-grab-start-y)
   (origin-x :initarg :origin-x :reader move-grab-origin-x)
   (origin-y :initarg :origin-y :reader move-grab-origin-y))
  (:documentation
   "An interactive move: the node's position follows the pointer's delta.

The position is remembered at the start rather than accumulated per event, so a
lost motion event cannot leave the window drifting behind the pointer."))

(defun begin-move-grab (node x y &key (button #x110))
  "A move grab for NODE, with the pointer starting at (X, Y) in output space."
  (make-instance 'move-grab
                 :node node
                 :button button
                 :start-x x
                 :start-y y
                 :origin-x (scene:node-x node)
                 :origin-y (scene:node-y node)))

(defmethod grab-motion ((grab move-grab) x y)
  (scene:set-node-position (grab-node grab)
                           (+ (move-grab-origin-x grab)
                              (- x (move-grab-start-x grab)))
                           (+ (move-grab-origin-y grab)
                              (- y (move-grab-start-y grab))))
  (grab-changed grab))

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
   (requested-height :initarg :start-height :accessor resize-grab-requested-height))
  (:documentation
   "An interactive resize from EDGES (an xdg_toplevel.resize_edge bitmask).

v0 asks for the size; it does not move the node when the top or left edge is
dragged, because until the client comes back with a buffer of the requested size
there is nothing to anchor.  That is a documented simplification, not an
oversight: the alternative is a window that slides while its content does not."))

(defun begin-resize-grab (node x y edges &key (button #x110) (min-width 1) (min-height 1))
  "A resize grab for NODE from EDGES, with the pointer starting at (X, Y)."
  (let ((width (max 1 (scene:node-width node)))
        (height (max 1 (scene:node-height node))))
    (make-instance 'resize-grab
                   :node node
                   :button button
                   :start-x x
                   :start-y y
                   :start-width width
                   :start-height height
                   :edges edges
                   :min-width min-width
                   :min-height min-height)))

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
      (grab-changed grab))))
