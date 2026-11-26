;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Scene tests: the node tree, hit testing, and the cursor.
;;;;
;;;; Two levels, deliberately:
;;;;
;;;;   * the tree on its own -- positions, stacking, coordinates, buffer sizes and
;;;;     input regions -- with surfaces made by hand, because the arithmetic is
;;;;     the thing that can be wrong in a way pixels cannot show;
;;;;   * a real headless compositor, an injected pointer and a rendered frame,
;;;;     because "the cursor is drawn where the pointer is" is a claim about
;;;;     pixels.
;;;;
;;;; The two-window, click-to-focus story needs two real clients and lives in
;;;; scripts/scene-gate.lisp; this file proves the parts it is built from.

(in-package #:cl-user)

(defpackage #:wayland.test.scene
  (:use #:cl #:rove)
  (:local-nicknames (#:scene #:cf.scene)
                    (#:grab #:cf.grab)
                    (#:srv #:wayland.server))
  (:documentation "Tests for cf.scene: hit testing, stacking, positions, cursor."))

(in-package #:wayland.test.scene)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defvar *directory-counter* 0)

(defun make-test-directory ()
  (let ((path (format nil "/tmp/cl-wayland-scene-test-~D-~D/"
                      (get-universal-time) (incf *directory-counter*))))
    (ensure-directories-exist path)
    (wayland.ffi:chmod-path (string-right-trim "/" path) #o700)
    path))

(defmacro with-compositor ((compositor &key (width 64) (height 64)) &body body)
  "A headless compositor on a private socket, and a quiet server."
  (let ((directory (gensym "DIRECTORY")))
    `(let ((,directory (make-test-directory))
           (srv:*log-level* :warn))
       (unwind-protect
            (let ((,compositor (cf:make-headless-compositor
                                :width ,width :height ,height
                                :display-name "scene-0"
                                :runtime-dir ,directory)))
              (unwind-protect (locally ,@body)
                (srv:close-display (cf:compositor-display ,compositor))))
         (uiop:delete-empty-directory ,directory)
         (ignore-errors (uiop:delete-directory-tree (pathname ,directory)
                                                    :validate t))))))

(defun fake-surface (&key (width 10) (height 10) mapped-p)
  "A wl_surface with a buffer of a known size and nothing else.

The scene only asks a surface three things -- its buffer, its size and its input
region -- so a surface with those three is a surface as far as this file is
concerned; the protocol state machine has its own tests in wayland.test.server."
  (let ((surface (make-instance 'srv:surface
                                :client nil :id 9 :interface nil :version 1))
        (buffer (make-instance 'srv:shm-buffer
                               :pool nil :offset 0
                               :width width :height height
                               :stride (* 4 width) :format 0)))
    (when mapped-p
      (setf (srv:surface-current-buffer surface) buffer
            (srv:surface-mapped-p surface) t))
    surface))

;;; ---------------------------------------------------------------------------
;;; The tree
;;; ---------------------------------------------------------------------------

(deftest a-scene-hits-the-topmost-node
  (let* ((scene (scene:make-scene 100 100))
         (under (scene:scene-add-node scene (scene:make-rect-node 40 40 #xFF112233)
                                      :x 10 :y 10))
         (over (scene:scene-add-node scene (scene:make-rect-node 40 40 #xFF445566)
                                     :x 20 :y 20)))
    (ok (eq over (scene:scene-hit-test scene 30 30))
        "the node added last is on top where they overlap")
    (ok (eq under (scene:scene-hit-test scene 12 12))
        "and the lower one still takes the part that is not covered")
    (scene:node-raised under)
    (ok (eq under (scene:scene-hit-test scene 30 30))
        "raising the lower node moves it to the top")
    (ok (eq over (scene:scene-hit-test scene 52 52))
        "and leaves the other one where it was")))

(deftest hit-testing-reports-node-local-coordinates
  ;; A group of its own, so the coordinate conversion has two levels to undo.
  (let* ((scene (scene:make-scene 200 200))
         (tree (scene:scene-add-node scene (make-instance 'scene:tree-node)
                                     :x 100 :y 100))
         (leaf (scene:make-rect-node 10 10 #xFF000000)))
    (setf (scene:node-children tree) (list leaf)
          (scene:node-parent leaf) tree
          (scene:node-x leaf) 5
          (scene:node-y leaf) 7)
    (multiple-value-bind (node x y) (scene:scene-hit-test scene 108 113)
      (ok (eq node leaf) "the leaf inside the group is found")
      (ok (= 3 x) "x is in the leaf's own space")
      (ok (= 6 y) "y is in the leaf's own space"))
    (multiple-value-bind (node x y) (scene:scene-hit-test scene 104 104)
      (declare (ignore x y))
      (ok (null node) "outside the leaf but inside the group is nothing"))))

(deftest nothing-is-hit-on-the-bare-output
  (let ((scene (scene:make-scene 50 50)))
    (multiple-value-bind (node x y) (scene:scene-hit-test scene 0 0)
      (declare (ignore x y))
      (ok (null node) "v0 has no background node, so the output is nothing"))))

(deftest an-invisible-node-takes-no-input
  (let* ((scene (scene:make-scene 50 50))
         (rect (scene:scene-add-node scene (scene:make-rect-node 10 10 #xFF000000)
                                     :x 5 :y 5)))
    (ok (eq rect (scene:scene-hit-test scene 6 6)))
    (setf (scene:node-visible-p rect) nil)
    (multiple-value-bind (node x y) (scene:scene-hit-test scene 6 6)
      (declare (ignore x y))
      (ok (null node) "hidden means not there"))))

(deftest a-buffer-node-is-exactly-its-buffer
  (let* ((scene (scene:make-scene 50 50))
         (surface (fake-surface :width 10 :height 6 :mapped-p t))
         (node (scene:scene-add-node scene (scene:make-buffer-node surface)
                                     :x 4 :y 8)))
    (ok (= 10 (scene:node-width node)) "width comes from the buffer")
    (ok (= 6 (scene:node-height node)) "height comes from the buffer")
    (multiple-value-bind (hit x y) (scene:scene-hit-test scene 5 9)
      (ok (eq hit node) "a point inside the buffer hits it")
      (ok (= 1 x))
      (ok (= 1 y)))
    (multiple-value-bind (hit x y) (scene:scene-hit-test scene 14 9)
      (declare (ignore x y))
      (ok (null hit) "one pixel past the right edge does not"))
    ;; A surface with no buffer is a zero-size node: a client that attached
    ;; nothing, or released everything, is not a window.
    (let ((empty-node (scene:scene-add-node
                       scene (scene:make-buffer-node (fake-surface)) :x 40 :y 40)))
      (ok (zerop (scene:node-width empty-node)))
      (multiple-value-bind (hit x y) (scene:scene-hit-test scene 40 40)
        (declare (ignore x y))
        (ok (null hit) "an unmapped surface is not hit")))))

(deftest a-surface-input-region-decides-what-it-takes
  (let* ((scene (scene:make-scene 50 50))
         (surface (fake-surface :width 20 :height 20 :mapped-p t))
         (node (scene:scene-add-node scene (scene:make-buffer-node surface)
                                     :x 10 :y 10)))
    (ok (eq node (scene:scene-hit-test scene 15 15))
        "no region set: the whole surface takes input")
    (setf (srv:surface-input-region surface) :empty)
    (multiple-value-bind (hit x y) (scene:scene-hit-test scene 15 15)
      (declare (ignore x y))
      (ok (null hit) "an empty region makes the surface click-through"))
    (setf (srv:surface-input-region surface) '((2 3 4 5)))
    (ok (eq node (scene:scene-hit-test scene 13 15))
        "inside the region: hit")
    (multiple-value-bind (hit x y) (scene:scene-hit-test scene 12 20)
      (declare (ignore x y))
      (ok (null hit) "outside the region: no hit"))
    (multiple-value-bind (hit x y) (scene:scene-hit-test scene 16 15)
      (declare (ignore x y))
      (ok (null hit) "the region's far edge is exclusive, as rectangles are"))))

(deftest a-node-remembers-its-own-parent
  (let* ((scene (scene:make-scene 20 20))
         (node (scene:scene-add-node scene (scene:make-rect-node 5 5 #xFF000000)
                                     :x 1 :y 2)))
    (ok (eq (scene:scene-root scene) (scene:node-parent node)))
    (ok (equal '(1 2) (multiple-value-list (scene:node-position node))))
    (scene:set-node-position node 7 8)
    (ok (equal '(7 8) (multiple-value-list (scene:node-position node))))
    (ok (eq node (scene:scene-hit-test scene 8 9)) "the new position is the real one")
    (scene:scene-remove-node node)
    (ok (null (scene:node-parent node)))
    (multiple-value-bind (hit x y) (scene:scene-hit-test scene 8 9)
      (declare (ignore x y))
      (ok (null hit) "a removed node is gone"))))

;;; ---------------------------------------------------------------------------
;;; The cursor, and a real frame
;;; ---------------------------------------------------------------------------

(deftest the-cursor-is-drawn-where-the-pointer-is
  (with-compositor (compositor :width 64 :height 64)
    ;; (1,3) is white in the arrow, (0,0) its black tip, (25,25) untouched.
    (cf:inject-pointer-motion compositor 10 10)
    (cf:render-frame compositor)
    (ok (= #xFF000000 (cf:frame-pixel compositor 10 10)) "the tip is black")
    (ok (= #xFFFFFFFF (cf:frame-pixel compositor 11 13)) "the body is white")
    (ok (= #xFF000000 (cf:frame-pixel compositor 25 25))
        "and the arrow is 16x16, so nothing was drawn there")
    (ok (= 10 (cf:compositor-cursor-x compositor))
        "the cursor position is the cursor node's position")
    (ok (= 10 (cf:compositor-cursor-y compositor)))
    ;; Moving redraws: the old place goes back to the background, the new place
    ;; gets the arrow.  A smear here would be a frame that kept stale pixels.
    (cf:inject-pointer-motion compositor 30 20)
    (cf:render-frame compositor)
    (ok (= #xFFFFFFFF (cf:frame-pixel compositor 31 23)) "drawn at the new place")
    (ok (= #xFF000000 (cf:frame-pixel compositor 11 13)) "and not at the old one")))

(deftest a-target-survives-a-full-gc
  "pixman keeps the target's address for the image's life.

A Lisp vector handed to pixman as a SAP is not safe: SBCL's GC may move it, and the
symptom is a frame that draws into an address nobody reads -- every pixel background,
no error anywhere.  This test forces a full GC between creating the target and drawing
into it; it failed 100% of the time before targets moved to foreign memory (D35)."
  (with-compositor (compositor :width 64 :height 64)
    (dotimes (i 200) (make-array 4096))
    (sb-ext:gc :full t)
    (cf:inject-pointer-motion compositor 10 10)
    (cf:render-frame compositor)
    (ok (= #xFFFFFFFF (cf:frame-pixel compositor 11 13))
        "the cursor is still drawn after a full GC")
    (ok (= #xFF000000 (cf:frame-pixel compositor 25 25))
        "and nothing appeared where nothing was drawn")))

(deftest the-cursor-is-not-hit-testable
  (with-compositor (compositor :width 64 :height 64)
    (cf:inject-pointer-motion compositor 10 10)
    (ok (null (scene:scene-hit-test (cf:compositor-scene compositor) 10 10))
        "the pointer cannot be standing on the pointer")))

(deftest a-hidden-cursor-is-not-drawn
  (with-compositor (compositor :width 32 :height 32)
    (cf:inject-pointer-motion compositor 5 5)
    ;; The compositor's flag is the one a session sets (a nested session sets it to
    ;; NIL, D39); RENDER-FRAME projects it onto the scene the renderer reads.
    (setf (cf:compositor-cursor-visible-p compositor) nil)
    (cf:render-frame compositor)
    (ok (= #xFF000000 (cf:frame-pixel compositor 6 8))
        "the arrow's white pixel is background when the cursor is hidden")))

;;; ---------------------------------------------------------------------------
;;; A client's cursor image is not a window
;;;
;; A cursor surface has no shell role, so it takes the roleless path: a node at the
;; scene origin, drawn where the client's attach offset says, hit-testable and first
;; in stack order.  It must not be: that is a stray cursor stuck at the output's
;; origin, updating whenever the client changes it (D40).

(defun cursor-image-surface (&key (width 16) (height 16))
  "A cf-surface with a buffer and no role: what a client's cursor image looks like."
  (let ((surface (make-instance 'cf.backend.headless:cf-surface
                                :client nil :id 9 :interface nil :version 1))
        (buffer (make-instance 'srv:shm-buffer
                               :pool nil :offset 0
                               :width width :height height
                               :stride (* 4 width) :format 0)))
    (setf (srv:surface-current-buffer surface) buffer
          (srv:surface-mapped-p surface) t)
    surface))

(defun node-for (compositor surface)
  "The node SURFACE is drawn through after a mapped commit: NIL when it has none.

The slot, not the return value of the step that creates it -- 'the commit created no
node' and 'the surface is still drawn through the node it already had' are
different states, and only the first is acceptable for a cursor image."
  (cf.backend.headless::ensure-scene-node compositor surface)
  (cf:surface-scene-node surface))

(deftest a-surface-named-as-the-pointer-image-is-never-drawn
  (with-compositor (compositor :width 64 :height 64)
    (let* ((seat (cf:compositor-seat compositor))
           (owner (make-instance 'cf.backend.headless:cf-compositor
                                 :client nil :id 3 :interface nil :version 3
                                 :surface-class 'cf.backend.headless:cf-surface
                                 :headless compositor))
           ;; Ordinary order: the client names its cursor surface, then commits it.
           (named-first (cursor-image-surface))
           ;; The order the protocol also allows: commit, then name.  This is the
           ;; one that used to leave a node behind for good.
           (committed-first (cursor-image-surface)))
      (setf (srv:surface-owner named-first) owner
            (srv:surface-owner committed-first) owner)
      (srv:seat-cursor-changed seat nil named-first)
      (ok (null (node-for compositor named-first))
          "a surface named before it is committed gets no node")
      (ok (node-for compositor committed-first)
          "one committed before it is named does -- the roleless path")
      (srv:seat-cursor-changed seat nil committed-first)
      (ok (null (node-for compositor committed-first))
          "and naming it takes the node back")
      (ok (null (node-for compositor committed-first))
          "and the next commit does not bring it back")
      (ok (cf.backend.headless:surface-pointer-image-p committed-first)
          "because the surface is recorded as a pointer image for good"))))

(deftest a-client-cursor-image-needs-pixels-to-be-drawn
  ;; The rule SCENE-RENDER applies before it draws a client's pointer image: a
  ;; surface with no current buffer (or a destroyed one) is not a picture, and the
  ;; session falls back to its own cursor.  Getting this wrong is not a hang -- it is
  ;; a compositor that draws a stale or absent cursor (D41).
  (let ((surface (fake-surface :width 16 :height 16)))
    (ok (null (scene:client-cursor-usable-p surface))
        "a cursor surface with no buffer is not a picture")
    (setf (srv:surface-current-buffer surface)
          (make-instance 'srv:shm-buffer :pool nil :offset 0
                                         :width 16 :height 16 :stride 64 :format 0))
    (ok (scene:client-cursor-usable-p surface)
        "one with a buffer is")
    (setf (srv:resource-destroyed-p surface) t)
    (ok (null (scene:client-cursor-usable-p surface))
        "and a destroyed one is not, whatever it still holds")))

(deftest a-resize-keeps-the-edge-opposite-the-dragged-one-still
  ;; A resize asks the client for a size and the client answers with one, so the
  ;; grab anchors the opposite edge to the size the client *came back with* -- not to
  ;; the size it asked for, which would slide the window while its content stayed
  ;; (D42).
  (let* ((node (scene:make-rect-node 200 150 #xFF000000))
         (grab (progn (scene:set-node-position node 100 50)
                      (grab:begin-resize-grab node 102 125 grab:+edge-left+))))
    (ok (= 300 (grab:resize-grab-anchor-right grab))
        "the anchored edge is where the node's right edge started")
    ;; The client comes back 50 pixels narrower: the left edge must move 50 right.
    (setf (scene:node-width node) 150)
    (grab:grab-anchored grab)
    (ok (= 150 (scene:node-x node))
        (format nil "the left edge moved to keep the right one where it was (x = ~D)"
                (scene:node-x node)))
    (ok (= 300 (+ (scene:node-x node) (scene:node-width node)))
        "and the right edge is where it started"))
  ;; A resize from the right edge does not move the node at all.
  (let* ((node (scene:make-rect-node 200 150 #xFF000000))
         (grab (progn (scene:set-node-position node 100 50)
                      (grab:begin-resize-grab node 295 125 grab:+edge-right+))))
    (setf (scene:node-width node) 260)
    (grab:grab-anchored grab)
    (ok (= 100 (scene:node-x node))
        "a right-edge resize leaves the left edge alone")))

(deftest a-move-is-clamped-so-the-window-cannot-be-lost
  ;; A window narrower than the output is kept fully inside it; one wider than the
  ;; output may be pushed as far as the output's other edge and no further, so it
  ;; always covers the output rather than sliding off it (D43).
  (ok (= 312 (grab:clamp-to-output 900 200 512))
      "a window that fits stops with its far edge at the output's (800 -> 312)")
  (ok (= 0 (grab:clamp-to-output -50 200 512))
      "and one dragged the other way stops at the near edge")
  (ok (= 100 (grab:clamp-to-output 100 200 512))
      "a position inside the range is left alone")
  (ok (= 0 (grab:clamp-to-output 400 900 512))
      "a window wider than the output stops when its far edge reaches the output's")
  (ok (= -388 (grab:clamp-to-output -900 900 512))
      "and when its near edge does (512 - 900)"))

(deftest a-grab-motion-clamps-a-move-to-the-output
  (with-compositor (compositor :width 512 :height 512)
    (let* ((scene (cf:compositor-scene compositor))
           (node (scene:scene-add-node scene (scene:make-rect-node 200 150 #xFF00FF00)))
           (grab (grab:begin-move-grab node 100 100 :button #x110
                                       :output-width 512 :output-height 512)))
      (setf (cf:compositor-grab compositor) grab)
      (cf:inject-pointer-motion compositor 500 500)
      (ok (equal (list (scene:node-x node) (scene:node-y node)) '(312 362))
          (format nil "a drag past the corner leaves the window at the output's edge (~S)"
                  (list (scene:node-x node) (scene:node-y node))))
      ;; The pointer itself is not clamped: it is wherever the device says.
      (ok (= 500 (cf:compositor-cursor-x compositor))
          "the pointer is still where the device put it"))))

(deftest the-scene-draws-over-the-background-in-stacking-order
  (with-compositor (compositor :width 32 :height 32)
    (let* ((scene (cf:compositor-scene compositor))
           (low (scene:scene-add-node scene (scene:make-rect-node 10 10 #xFF00FF00)
                                      :x 2 :y 2))
           (high (scene:scene-add-node scene (scene:make-rect-node 10 10 #xFF0000FF)
                                       :x 6 :y 6)))
      (declare (ignore low high))
      (setf (cf:compositor-cursor-visible-p compositor) nil)
      (cf:render-frame compositor)
      (ok (= #xFF00FF00 (cf:frame-pixel compositor 3 3))
          "the lower rectangle is drawn")
      (ok (= #xFF0000FF (cf:frame-pixel compositor 8 8))
          "the upper rectangle is drawn over it"))))

;;; ---------------------------------------------------------------------------
;;; Grabs
;;; ---------------------------------------------------------------------------
;;
;; A grab is driven the way a backend drives it: injected motion and buttons.
;; The parts worth asserting are the ones a screenshot cannot show -- that the
;; node follows the pointer's *delta* (not the pointer), that a release ends the
;; grab exactly once, and that a size asked for is the size the edge implies.

(defclass counting-move-grab (cf.grab:move-grab)
  ((end-count :initform 0 :accessor end-count)))

(defmethod cf.grab:grab-ended ((grab counting-move-grab) reason)
  (declare (ignore reason))
  (incf (end-count grab))
  (call-next-method))

(defclass recording-resize-grab (cf.grab:resize-grab)
  ((requests :initform nil :accessor requests)))

(defmethod cf.grab:grab-resize ((grab recording-resize-grab) width height)
  (push (list width height) (requests grab)))

(defun window-node (compositor x y &key (width 100) (height 80))
  "A cf-surface with a mapped buffer, a shell role and a node at (X, Y).

The role matters: a window is a surface a shell gave a role to, and CF's cycle-views
(and anything else that asks what a window is) says so.  A bare xdg_surface with no
role of its own is enough here -- nothing in this file goes through xdg-shell's
state machine -- but a *roleless* surface is not a window and must not be cycled.
Returns (values surface node)."
  (let* ((surface (make-instance 'cf:cf-surface
                                 :client nil :id 9 :interface nil :version 1))
         (shell (make-instance 'srv:xdg-surface
                               :client nil :id 11 :interface nil :version 1))
         (node (scene:scene-add-node (cf:compositor-scene compositor)
                                     (scene:make-buffer-node surface)
                                     :x x :y y)))
    ;; The role *name* is what WINDOW-NODE-P asks about: a popup has a shell role too,
    ;; and a menu is not a window to cycle (D44).
    (setf (srv:xdg-surface-role-name shell) :toplevel
          (srv:surface-current-buffer surface)
          (make-instance 'srv:shm-buffer
                         :pool nil :offset 0 :width width :height height
                         :stride (* 4 width) :format 0)
          (srv:surface-mapped-p surface) t
          (srv:surface-shell-surface surface) shell
          (cf:surface-scene-node surface) node)
    (values surface node)))

(deftest a-move-grab-follows-the-pointer-and-ends-exactly-once
  (with-compositor (compositor :width 200 :height 200)
    (multiple-value-bind (surface node) (window-node compositor 10 10)
      (declare (ignore surface))
      (let ((grab (make-instance 'counting-move-grab
                                 :node node :start-x 20 :start-y 20
                                 :origin-x 10 :origin-y 10)))
        (cf:start-grab compositor grab)
        (cf:inject-pointer-motion compositor 35 50)
        (ok (equal '(25 40) (multiple-value-list (scene:node-position node)))
            "the node moved by the pointer's delta, not to the pointer")
        (cf:inject-pointer-button compositor :left :released)
        (ok (null (cf:compositor-grab compositor)) "the release ended the grab")
        (ok (= 1 (end-count grab)) "and it ended once")
        (cf:inject-pointer-button compositor :left :released)
        (ok (= 1 (end-count grab)) "a second release is not a second end")
        (cf:inject-pointer-motion compositor 150 150)
        (ok (equal '(25 40) (multiple-value-list (scene:node-position node)))
            "and motion after the end moves nothing")))))

(deftest a-resize-grab-asks-for-the-size-the-edge-implies
  (with-compositor (compositor :width 400 :height 400)
    (multiple-value-bind (surface node) (window-node compositor 0 0 :width 200 :height 150)
      (declare (ignore surface))
      (let ((grab (make-instance 'recording-resize-grab
                                 :node node :start-x 0 :start-y 0
                                 :start-width 200 :start-height 150
                                 :edges (logior cf.grab:+edge-right+
                                                cf.grab:+edge-bottom+))))
        (cf:start-grab compositor grab)
        (cf:inject-pointer-motion compositor 40 30)
        (ok (equal '((240 180)) (requests grab))
            "a bottom-right drag asks for the start size plus the delta")
        (cf:inject-pointer-motion compositor 40 30)
        (ok (equal '((240 180)) (requests grab))
            "and the same size is not asked for twice")
        (cf:inject-pointer-motion compositor 45 35)
        (ok (equal '((245 185) (240 180)) (requests grab))
            "a further drag asks again")
        (cf:inject-pointer-button compositor :left :released)
        (ok (null (cf:compositor-grab compositor)) "the release ended the resize")))))

(deftest resize-target-size-answers-each-edge
  (flet ((size (edges dx dy)
           (multiple-value-list (cf.grab:resize-target-size edges 200 150 dx dy))))
    (ok (equal '(240 180) (size (logior cf.grab:+edge-right+ cf.grab:+edge-bottom+) 40 30)))
    (ok (equal '(160 150) (size cf.grab:+edge-left+ 40 30))
        "dragging the left edge inward makes the window narrower")
    (ok (equal '(200 120) (size cf.grab:+edge-top+ 40 30))
        "and the top edge shorter")
    (ok (equal '(200 150) (size 0 40 30))
        "a resize with no edge changes nothing")
    (ok (equal '(1 1) (size (logior cf.grab:+edge-right+ cf.grab:+edge-bottom+) -500 -500))
        "and a drag past the origin is clamped, not negative")))

;;; ---------------------------------------------------------------------------
;;; Keybindings
;;; ---------------------------------------------------------------------------

(deftest alt-escape-stops-the-compositor
  (with-compositor (compositor :width 64 :height 64)
    (cf:inject-key compositor "Alt_L" :pressed)
    (ok (cf:handle-key compositor "Escape" :pressed)
        "the binding consumed the press")
    (ok (member "Escape" (cf:compositor-consumed-keys compositor) :test #'string-equal)
        "and remembered it, so its release is swallowed too")
    (ok (cf:handle-key compositor "Escape" :released) "the release was consumed")
    (ok (null (cf:compositor-consumed-keys compositor)) "and then forgotten")
    (ok (wayland.reactor:stopped-p
         (wayland.server:display-reactor (cf:compositor-display compositor)))
        "the main loop was asked to stop")))

(deftest alt-f1-cycles-the-bottom-window-to-the-top
  (with-compositor (compositor :width 200 :height 200)
    (multiple-value-bind (surface-a node-a) (window-node compositor 0 0)
      (multiple-value-bind (surface-b node-b) (window-node compositor 10 10)
        (srv:set-keyboard-focus (cf:compositor-seat compositor) surface-b)
        (ok (eq node-b (car (last (scene:node-children
                                   (scene:scene-root (cf:compositor-scene compositor))))))
            "the second window is on top to start with")
        (cf:inject-key compositor "Alt_L" :pressed)
        (cf:inject-key compositor "F1" :pressed)
        (cf:inject-key compositor "F1" :released)
        (cf:inject-key compositor "Alt_L" :released)
        (ok (eq node-a (car (last (scene:node-children
                                   (scene:scene-root (cf:compositor-scene compositor))))))
            "alt+F1 brought the bottom window to the top")
        (ok (eq surface-a (srv:seat-keyboard-focus (cf:compositor-seat compositor)))
            "and focused it")))))

(deftest an-unbound-key-is-not-consumed
  (with-compositor (compositor :width 64 :height 64)
    (ok (null (cf:handle-key compositor "a" :pressed))
        "nothing bound 'a', so it goes to the client (and nowhere, with no focus)")
    (ok (null (cf:compositor-consumed-keys compositor)))))

;;; ---------------------------------------------------------------------------
;;; Popups: a menu is not a window, and it follows the window it belongs to
;;; ---------------------------------------------------------------------------

(defun popup-under-window (compositor window-surface &key (x 10) (y 10)
                                                     (width 100) (height 80)
                                                     (geometry '(30 30 120 80)))
  "A popup role, its surface and its node, hanging off WINDOW-SURFACE's window.

Nothing goes through the protocol state machine: this file tests the *placement*,
which is a question about nodes and the numbers the configure left behind.  Returns
(values popup-node popup toplevel-role).
"
  (let* ((shell (srv:surface-shell-surface window-surface))
         (toplevel (or (srv:xdg-surface-role shell)
                       (let ((role (make-instance 'srv:xdg-toplevel
                                                  :client nil :id 12 :interface nil :version 1)))
                         (setf (srv:xdg-surface-role shell) role
                               (srv:xdg-toplevel-shell-surface role) shell)
                         role)))
         (popup-shell (make-instance 'srv:xdg-surface
                                     :client nil :id 21 :interface nil :version 1))
         (popup (make-instance 'srv:xdg-popup
                               :client nil :id 22 :interface nil :version 1))
         (popup-surface (make-instance 'cf:cf-surface
                                       :client nil :id 23 :interface nil :version 1))
         (popup-node (scene:scene-add-node (cf:compositor-scene compositor)
                                           (scene:make-buffer-node popup-surface)
                                           :x x :y y)))
    (setf (srv:xdg-surface-surface shell) window-surface
          (srv:xdg-surface-role-name popup-shell) :popup
          (srv:xdg-surface-role popup-shell) popup
          (srv:xdg-surface-surface popup-shell) popup-surface
          (srv:xdg-popup-shell-surface popup) popup-shell
          (srv:xdg-popup-parent popup) shell
          (srv:xdg-popup-geometry popup) geometry
          (srv:xdg-toplevel-popups toplevel)
          (append (srv:xdg-toplevel-popups toplevel) (list popup))
          (srv:surface-current-buffer popup-surface)
          (make-instance 'srv:shm-buffer :pool nil :offset 0
                                         :width width :height height
                                         :stride (* 4 width) :format 0)
          (srv:surface-mapped-p popup-surface) t
          (srv:surface-shell-surface popup-surface) popup-shell
          (cf:surface-scene-node popup-surface) popup-node)
    (values popup-node popup toplevel)))

(deftest a-menu-is-not-a-window
  (with-compositor (compositor :width 200 :height 200)
    (multiple-value-bind (window-surface window-node) (window-node compositor 0 0)
      (multiple-value-bind (popup-node popup toplevel)
          (popup-under-window compositor window-surface)
        (declare (ignore popup toplevel))
        (ok (cf:window-node-p window-node) "the window is a window")
        (ok (not (cf:window-node-p popup-node))
            "a popup has a shell role and a node, but it is not something to cycle")))))

(deftest a-menu-follows-the-window-it-belongs-to
  (with-compositor (compositor :width 320 :height 240)
    (multiple-value-bind (window-surface window-node) (window-node compositor 50 40)
      (multiple-value-bind (popup-node popup toplevel)
          (popup-under-window compositor window-surface)
        (declare (ignore popup toplevel))
        (setf (cf:compositor-surfaces compositor) (list window-surface))
        (let ((popup-surface (scene:buffer-node-surface popup-node)))
          (push popup-surface (cf:compositor-surfaces compositor))
          ;; The configure said (30, 30) relative to the window's geometry, and the
          ;; window is at (50, 40) with no window geometry of its own.
          (cf:sync-popup-positions compositor)
          (ok (equal '(80 70) (multiple-value-list (scene:node-position popup-node)))
              "the popup is placed parent + configure, in output space")
          ;; A drag moves the window; the menu must travel with it, which is why the
          ;; placement is asked for every frame rather than stored at configure time.
          (scene:set-node-position window-node 10 20)
          (cf:sync-popup-positions compositor)
          (ok (equal '(40 50) (multiple-value-list (scene:node-position popup-node)))
              "moving the window moves the menu")
          ;; A raise takes the menu with the window: raising the window alone would
          ;; bury the menu, raising the menu alone would be true only until the next
          ;; click raised the window.
          (let ((root (scene:scene-root (cf:compositor-scene compositor))))
            (scene:node-raised window-node)
            (ok (eq window-node (car (last (scene:node-children root))))
                "raising the window alone puts the window over its own menu...")
            (cf:raise-window-with-popups compositor window-node)
            (ok (eq popup-node (car (last (scene:node-children root))))
                "...and RAISE-WINDOW-WITH-POPUPS puts the menu back on top")
            (ok (eq window-node (car (last (butlast (scene:node-children root)))))
                "directly above the window it belongs to")))))))

;;; ---------------------------------------------------------------------------
;;; The focus stack (D45)
;;;
;;; History, not draw order.  These tests use the same fake surfaces as the rest of
;;; the file, so what is under test is the stack's own rules: what goes in, what
;;; leaves, what happens to the keys when the focused window goes away, and what
;;; Alt+Tab visits.
;;; ---------------------------------------------------------------------------

(defun window-at (compositor x y)
  "A mapped window surface and its node at (X, Y); returns (values surface node)."
  (window-node compositor x y))

(deftest focusing-a-window-puts-it-at-the-front-of-the-stack
  (with-compositor (compositor :width 300 :height 300)
    (multiple-value-bind (a node-a) (window-at compositor 0 0)
      (declare (ignore node-a))
      (multiple-value-bind (b node-b) (window-at compositor 10 10)
        (declare (ignore node-b))
        (multiple-value-bind (c node-c) (window-at compositor 20 20)
          (declare (ignore node-c))
          (cf:focus-surface compositor a)
          (ok (equal (list a) (cf:compositor-focus-stack compositor)))
          (cf:focus-surface compositor b)
          (cf:focus-surface compositor c)
          (ok (equal (list c b a) (cf:compositor-focus-stack compositor))
              "most recently focused first")
          (cf:focus-surface compositor a)
          (ok (equal (list a c b) (cf:compositor-focus-stack compositor))
              "focusing a window again moves it, it does not duplicate it")
          (ok (= 3 (length (cf:compositor-focus-stack compositor)))
              "and the stack has one entry per window"))))))

(deftest a-menu-pushes-the-window-it-belongs-to
  ;; A popup takes the keyboard while it is up, but it is not a window: the stack
  ;; must name the window the menu belongs to, or Alt+Tab could return to a menu
  ;; that has already gone.
  (with-compositor (compositor :width 320 :height 240)
    (multiple-value-bind (window-surface window-node) (window-at compositor 0 0)
      (declare (ignore window-node))
      (multiple-value-bind (other other-node) (window-at compositor 40 40)
        (declare (ignore other-node))
        (multiple-value-bind (popup-node popup toplevel)
            (popup-under-window compositor window-surface)
          (declare (ignore popup toplevel))
          (let ((popup-surface (scene:buffer-node-surface popup-node)))
            (cf:focus-surface compositor other)
            (cf:focus-surface compositor popup-surface)
            (ok (eq popup-surface (srv:seat-keyboard-focus (cf:compositor-seat compositor)))
                "the popup has the keyboard")
            (ok (equal (list window-surface other)
                       (cf:compositor-focus-stack compositor))
                "but the stack holds the window the menu belongs to")
            (ok (not (member popup-surface (cf:compositor-focus-stack compositor)))
                "never the popup itself")))))))

(deftest a-roleless-surface-never-enters-the-stack
  (with-compositor (compositor :width 100 :height 100)
    (let ((bare (make-instance 'cf:cf-surface :client nil :id 31 :interface nil :version 1)))
      (setf (srv:surface-current-buffer bare)
            (make-instance 'srv:shm-buffer :pool nil :offset 0 :width 8 :height 8
                                           :stride 32 :format 0)
            (srv:surface-mapped-p bare) t)
      (cf:focus-surface compositor bare)
      (ok (null (cf:compositor-focus-stack compositor))
          "a surface with no shell role is nobody's window"))))

(deftest alt-tab-visits-every-window-once-and-wraps
  (with-compositor (compositor :width 300 :height 300)
    (multiple-value-bind (a node-a) (window-at compositor 0 0)
      (multiple-value-bind (b node-b) (window-at compositor 10 10)
        (multiple-value-bind (c node-c) (window-at compositor 20 20)
          (cf:focus-surface compositor a)
          (cf:focus-surface compositor b)
          (cf:focus-surface compositor c)
          (ok (eq a (cf:focus-stack-cycle compositor))
              "the first Alt+Tab takes the least recently focused window")
          (ok (eq a (srv:seat-keyboard-focus (cf:compositor-seat compositor))))
          (ok (eq node-a (car (last (scene:node-children
                                     (scene:scene-root (cf:compositor-scene compositor))))))
              "and raises it: a cycle you cannot see is not a cycle")
          (ok (equal (list a c b) (cf:compositor-focus-stack compositor))
              "the stack rotated rather than reordered by draw order")
          (cf:focus-stack-cycle compositor)   ; b
          (cf:focus-stack-cycle compositor)   ; c
          (ok (eq c (srv:seat-keyboard-focus (cf:compositor-seat compositor)))
              "three presses visit three windows")
          (ok (equal (list c b a) (cf:compositor-focus-stack compositor))
              "and come back to where they started")
          (ok (eq a (cf:focus-stack-cycle compositor))
              "a fourth press starts the cycle again"))))))

(deftest alt-tab-with-two-windows-is-a-toggle
  (with-compositor (compositor :width 200 :height 200)
    (multiple-value-bind (a node-a) (window-at compositor 0 0)
      (declare (ignore node-a))
      (multiple-value-bind (b node-b) (window-at compositor 10 10)
        (declare (ignore node-b))
        (cf:focus-surface compositor a)
        (cf:focus-surface compositor b)
        (ok (eq a (cf:focus-stack-cycle compositor)))
        (ok (eq b (cf:focus-stack-cycle compositor)))))))

(deftest a-closed-window-hands-the-keys-on
  ;; The stack's whole point: "the window that mapped last" cannot answer who gets
  ;; the keyboard when the focused window goes away.
  (with-compositor (compositor :width 300 :height 300)
    (multiple-value-bind (a node-a) (window-at compositor 0 0)
      (declare (ignore node-a))
      (multiple-value-bind (b node-b) (window-at compositor 10 10)
        (declare (ignore node-b))
        (multiple-value-bind (c node-c) (window-at compositor 20 20)
          (declare (ignore node-c))
          (cf:focus-surface compositor a)
          (cf:focus-surface compositor b)
          (cf:focus-surface compositor c)
          ;; The compositor's surface list is what the render loop prunes; the
          ;; framework's own list is what a real commit would have filled.
          (setf (cf:compositor-surfaces compositor) (list a b c))
          (ok (eq c (srv:seat-keyboard-focus (cf:compositor-seat compositor))))
          ;; C's window closes: it leaves both the scene and the history.
          (setf (srv:surface-mapped-p c) nil)
          (cf.backend.headless::prune-surfaces compositor)
          (ok (eq b (srv:seat-keyboard-focus (cf:compositor-seat compositor)))
              "the keys go to the most recently focused window that is still there")
          (ok (equal (list b a) (cf:compositor-focus-stack compositor))
              "and the closed window is out of the stack")
          ;; Closing the new front passes them on again, to the last one.
          (setf (srv:surface-mapped-p b) nil)
          (cf.backend.headless::prune-surfaces compositor)
          (ok (eq a (srv:seat-keyboard-focus (cf:compositor-seat compositor))))
          ;; The last window leaving clears the focus rather than keeping a ghost.
          (setf (srv:surface-mapped-p a) nil)
          (cf.backend.headless::prune-surfaces compositor)
          (ok (null (srv:seat-keyboard-focus (cf:compositor-seat compositor))))
          (ok (null (cf:compositor-focus-stack compositor))))))))

(deftest alt-tab-with-nothing-to-cycle-is-a-no-op
  (with-compositor (compositor :width 100 :height 100)
    (ok (null (cf:focus-stack-cycle compositor))
        "no windows, no focus, no error")))

;;; ---------------------------------------------------------------------------
;;; Clamping: a resize stops at the output, and a shrinking output re-clamps (D46)
;;; ---------------------------------------------------------------------------

(deftest resize-target-size-is-bounded-by-the-output
  ;; The pure arithmetic: the *edge under the pointer* may travel as far as the
  ;; output's border, with the anchored edge where it is.
  (multiple-value-bind (width height)
      (grab:resize-target-size grab:+edge-right+ 100 100 900 0 :max-width 300)
    (declare (ignore height))
    (ok (= 300 width) "a right drag stops at the output's right edge (300, not 1000)"))
  (multiple-value-bind (width height)
      (grab:resize-target-size grab:+edge-left+ 100 100 -900 0 :max-width 300)
    (declare (ignore height))
    (ok (= 300 width) "a left drag stops at its anchored right edge"))
  (multiple-value-bind (width height)
      (grab:resize-target-size grab:+edge-bottom+ 100 100 0 900 :max-height 200)
    (declare (ignore width))
    (ok (= 200 height) "a bottom drag stops at the output's bottom edge"))
  (multiple-value-bind (width height)
      (grab:resize-target-size grab:+edge-top+ 100 100 0 -900 :max-height 200)
    (declare (ignore width))
    (ok (= 200 height) "a top drag stops at its anchored bottom edge"))
  ;; Without a maximum the drag is what the client asked for, as before.
  (ok (equal '(600 150)
             (multiple-value-list
              (grab:resize-target-size grab:+edge-right+ 200 150 400 300)))
      "an unbounded resize is unchanged (height is not dragged from this edge)")
  ;; A client's minimum size wins over the output: a window smaller than its
  ;; client's minimum is a window the client cannot draw.
  (ok (equal '(300 300)
             (multiple-value-list
              (grab:resize-target-size grab:+edge-right+ 400 400 -500 -500
                                       :min-width 300 :min-height 300
                                       :max-width 100 :max-height 100)))
      "the minimum wins where the two disagree"))

(deftest a-resize-grab-derives-its-bounds-from-the-output
  ;; The integration half: BEGIN-RESIZE-GRAB measures the anchored edges in output
  ;; space, so the maximum is the distance from them to the output's border.
  (let* ((node (scene:make-rect-node 200 150 #xFF000000))
         (grab (progn
                 (scene:set-node-position node 100 100)
                 (grab:begin-resize-grab node 295 245
                                         (logior grab:+edge-right+ grab:+edge-bottom+)
                                         :output-width 400 :output-height 300))))
    (ok (equal '(300 200) (multiple-value-list (grab:resize-grab-max-size grab)))
        "a bottom-right drag is bounded by the output's far edges (400-100, 300-100)")
    (grab:grab-motion grab 900 900)
    (ok (= 300 (grab:resize-grab-requested-width grab))
        "so a drag past the corner asks for exactly that")
    (ok (= 200 (grab:resize-grab-requested-height grab))
        "on both axes"))
  ;; A left drag is bounded by where the right edge is, because the right edge is
  ;; the anchored one -- so the window cannot be widened out of the left of the
  ;; output either.
  (let* ((node (scene:make-rect-node 200 150 #xFF000000))
         (grab (progn
                 (scene:set-node-position node 100 100)
                 (grab:begin-resize-grab node 105 145 grab:+edge-left+
                                         :output-width 400 :output-height 300))))
    (ok (= 300 (grab:resize-grab-max-size grab))
        "a left drag is bounded by the anchored right edge (100 + 200)")
    (grab:grab-motion grab -900 300)
    (ok (= 300 (grab:resize-grab-requested-width grab))
        "so a drag far to the left asks for at most the anchored edge's distance")))

(deftest an-output-that-shrinks-re-clamps-its-windows
  (with-compositor (compositor :width 400 :height 300)
    (multiple-value-bind (surface node) (window-node compositor 250 200)
      (setf (cf:compositor-surfaces compositor) (list surface))
      (ok (equal '(250 200) (multiple-value-list (scene:node-position node))))
      (cf:resize-compositor compositor 200 150)
      (ok (equal '(100 70) (multiple-value-list (scene:node-position node)))
          "a 100x80 window at (250,200) comes back inside a 200x150 output")
      ;; A window wider than the output cannot fit at all: the clamp puts it
      ;; wherever it still covers the output (D43), which is any x in [W-w, 0].
      (cf:resize-compositor compositor 50 40)
      (let* ((node (cf:surface-scene-node surface))
             (width (scene:node-width node))
             (height (scene:node-height node)))
        (multiple-value-bind (x y) (scene:node-position node)
          (ok (<= (- 50 width) x 0)
              (format nil "a window larger than the output covers it on x (~D in [~D, 0])"
                      x (- 50 width)))
          (ok (<= (- 40 height) y 0)
              (format nil "and on y (~D in [~D, 0])" y (- 40 height)))
          (ok (and (<= x 0) (>= (+ x width) 50)
                   (<= y 0) (>= (+ y height) 40))
              "no part of the output is left uncovered"))))))

(deftest re-clamping-speaks-window-geometry
  ;; A decorated client's buffer starts before its window (a shadow).  Clamping the
  ;; node would leave the shadow's width of slack, so the arithmetic is in geometry.
  (with-compositor (compositor :width 1024 :height 768)
    (multiple-value-bind (surface node) (window-node compositor 500 300
                                                     :width 806 :height 563)
      (setf (cf:compositor-surfaces compositor) (list surface))
      (setf (srv:xdg-surface-window-geometry (srv:surface-shell-surface surface))
            (list 32 32 742 499))
      (ok (= 806 (scene:node-width node)) "the buffer is 806 wide, the window 742")
      ;; At 200 the 742-wide window ends at 232 + 742 = 974, inside 1024.
      (scene:set-node-position node 200 300)
      (grab:clamp-node-to-output node 1024 768)
      (ok (= 200 (scene:node-x node)) "a window that fits is not moved")
      (scene:set-node-position node 900 300)
      (grab:clamp-node-to-output node 1024 768)
      (ok (= 250 (scene:node-x node))
          "a window hanging over the edge is placed by its *geometry* (250, not 218)")
      (ok (= 282 (+ (scene:node-x node) 32))
          "which puts the visible left edge at the output's largest allowed x")
      (grab:clamp-node-to-output node 2048 768)
      (ok (= 250 (scene:node-x node))
          "and a bigger output does not move it again on its own"))))

(deftest a-drag-past-one-edge-keeps-tracking-the-other
  ;; D47: the axes are independent, and a pointer outside the output is clamped for
  ;; the grab rather than ending it -- so a corner drag past the bottom keeps growing
  ;; to the right, which is what a person dragging past the screen's corner expects.
  (with-compositor (compositor :width 400 :height 300)
    (multiple-value-bind (surface node) (window-node compositor 50 50 :width 200 :height 150)
      (declare (ignore surface))
      (setf (cf:compositor-surfaces compositor) (list (cf.scene:buffer-node-surface node)))
      (let ((grab (cf:start-grab compositor
                                 (grab:begin-resize-grab
                                  node 240 190
                                  (logior grab:+edge-right+ grab:+edge-bottom+)
                                  :output-width 400 :output-height 300))))
        (cf:inject-pointer-motion compositor 399 299)
        (ok (equal (list 350 250)
                   (list (grab:resize-grab-requested-width grab)
                         (grab:resize-grab-requested-height grab)))
            "both axes reach the output's far edges")
        (cf:inject-pointer-motion compositor 350 299)
        (ok (= 310 (grab:resize-grab-requested-width grab))
            "with y at its bound, x still tracks")
        ;; Now the pointer goes past the bottom edge: the grab stays, y stays clamped,
        ;; and x keeps going.  This is the case the manual test reported.
        (cf:inject-pointer-motion compositor 300 500)
        (ok (eq grab (cf:compositor-grab compositor))
            "a position past one edge does not end the grab")
        (ok (equal (list 260 250)
                   (list (grab:resize-grab-requested-width grab)
                         (grab:resize-grab-requested-height grab)))
            "the far axis is clamped and the near one follows the pointer (260x250)")
        (cf:inject-pointer-motion compositor 380 900)
        (ok (= 340 (grab:resize-grab-requested-width grab))
            "and keeps following: 340 wide while the pointer is 600 below the output")
        (ok (= 250 (grab:resize-grab-requested-height grab))
            "with the height still at its bound")
        (ok (= 380 (cf:compositor-cursor-x compositor))
            "the cursor itself is where the device said, not where the grab clamped")
        (ok (= 900 (cf:compositor-cursor-y compositor))
            "on both axes")
        ;; A *leave* is a different statement: the pointer is gone, so the grab ends.
        (cf:inject-pointer-leave compositor)
        (ok (null (cf:compositor-grab compositor))
            "but a backend saying the pointer left ends the grab")
        (ok (= -1 (cf:compositor-cursor-x compositor))
            "and parks the cursor off the output")))))

(deftest a-move-grab-clamps-the-pointer-too
  (with-compositor (compositor :width 400 :height 300)
    (multiple-value-bind (surface node) (window-node compositor 50 50)
      (declare (ignore surface))
      (let ((grab (cf:start-grab compositor
                                 (grab:begin-move-grab node 100 100
                                                       :output-width 400 :output-height 300))))
        (cf:inject-pointer-motion compositor 500 500)
        (ok (eq grab (cf:compositor-grab compositor))
            "a move past the corner keeps its grab")
        (ok (equal (list (- 400 (scene:node-width node))
                         (- 300 (scene:node-height node)))
                   (multiple-value-list (scene:node-position node)))
            "while the window stays inside the output")
        (cf:inject-pointer-leave compositor)
        (ok (null (cf:compositor-grab compositor)) "and a leave ends it")))))
