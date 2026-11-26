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
    (setf (scene:scene-cursor-visible-p (cf:compositor-scene compositor)) nil)
    (cf:render-frame compositor)
    (ok (= #xFF000000 (cf:frame-pixel compositor 6 8))
        "the arrow's white pixel is background when the cursor is hidden")))

(deftest the-scene-draws-over-the-background-in-stacking-order
  (with-compositor (compositor :width 32 :height 32)
    (let* ((scene (cf:compositor-scene compositor))
           (low (scene:scene-add-node scene (scene:make-rect-node 10 10 #xFF00FF00)
                                      :x 2 :y 2))
           (high (scene:scene-add-node scene (scene:make-rect-node 10 10 #xFF0000FF)
                                       :x 6 :y 6)))
      (declare (ignore low high))
      (setf (scene:scene-cursor-visible-p scene) nil)
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
  "A cf-surface with a mapped buffer, a node at (X, Y); returns (values surface node)."
  (let* ((surface (make-instance 'cf:cf-surface
                                 :client nil :id 9 :interface nil :version 1))
         (node (scene:scene-add-node (cf:compositor-scene compositor)
                                     (scene:make-buffer-node surface)
                                     :x x :y y)))
    (setf (srv:surface-current-buffer surface)
          (make-instance 'srv:shm-buffer
                         :pool nil :offset 0 :width width :height height
                         :stride (* 4 width) :format 0)
          (srv:surface-mapped-p surface) t
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
