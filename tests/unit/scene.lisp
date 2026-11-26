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
