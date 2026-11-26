;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Renderer tests: regions, transforms, scale, damage and opaque culling.
;;;;
;;;; Three levels, because three different things can be wrong:
;;;;
;;;;   * pixman arithmetic -- a region that does not subtract, a matrix whose
;;;;     rotation is the wrong way round -- checked against hand-written
;;;;     expectations rather than against the implementation;
;;;;   * the scene's geometry -- layout coordinates turned into device pixels,
;;;;     with a surface's buffer scale divided out -- checked on draw items,
;;;;     where the numbers are visible;
;;;;   * whole frames -- a partial repaint (with opaque culling on the way) must
;;;;     produce exactly the pixels a full repaint produces, which is the one
;;;;     invariant that makes incremental drawing safe at all (D48).
;;;;
;;;; The scaled *client* path (a real buffer at buffer scale 2 on a scale-2
;;;; output) needs a real client and lives in scripts/render-gate.lisp.

(in-package #:cl-user)

(defpackage #:wayland.test.render
  (:use #:cl #:rove)
  (:local-nicknames (#:scene #:cf.scene)
                    (#:srv #:wayland.server)
                    (#:render #:cf.render.pixman))
  (:documentation "Tests for the renderer's regions, transforms, scale and damage."))

(in-package #:wayland.test.render)

(defparameter +background+ #xFF000000 "The headless compositor's default background.")

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defvar *directory-counter* 0)

(defun make-test-directory ()
  (let ((path (format nil "/tmp/cl-wayland-render-test-~D-~D/"
                      (get-universal-time) (incf *directory-counter*))))
    (ensure-directories-exist path)
    (wayland.ffi:chmod-path (string-right-trim "/" path) #o700)
    path))

(defmacro with-compositor ((compositor &key (width 64) (height 64) (scale 1)) &body body)
  "A headless compositor on a private socket, and a quiet server."
  (let ((directory (gensym "DIRECTORY")))
    `(let ((,directory (make-test-directory))
           (srv:*log-level* :warn))
       (unwind-protect
            (let ((,compositor (cf:make-headless-compositor
                                :width ,width :height ,height :scale ,scale
                                :display-name "render-0"
                                :runtime-dir ,directory)))
              (unwind-protect (locally ,@body)
                (srv:close-display (cf:compositor-display ,compositor))))
         (uiop:delete-empty-directory ,directory)
         (ignore-errors (uiop:delete-directory-tree (pathname ,directory)
                                                    :validate t))))))

(defun fake-surface (&key (width 10) (height 10) (buffer-scale 1) (transform 0) mapped-p)
  "A wl_surface with a buffer of a known size and the scale/transform it asked for."
  (let ((surface (make-instance 'srv:surface
                                :client nil :id 9 :interface nil :version 1))
        (buffer (make-instance 'srv:shm-buffer
                               :pool nil :offset 0
                               :width width :height height
                               :stride (* 4 width) :format 0)))
    (when mapped-p
      (setf (srv:surface-current-buffer surface) buffer
            (srv:surface-mapped-p surface) t))
    (setf (srv:surface-buffer-scale surface) buffer-scale
          (srv:surface-buffer-transform surface) transform)
    surface))

;;; ---------------------------------------------------------------------------
;;; Regions
;;; ---------------------------------------------------------------------------

(deftest a-region-is-a-set-of-rectangles
  (let ((region (render:make-region)))
    (unwind-protect
         (progn
           (ok (render:region-empty-p region) "a new region covers nothing")
           (ok (null (render:region-bounds region)) "and has no bounds")
           (render:region-add region 10 20 30 40)
           (ok (equal '(10 20 30 40) (render:region-bounds region))
               "one rectangle has its own bounds")
           (render:region-add region 100 100 10 10)
           (ok (equal '(10 20 100 90) (render:region-bounds region))
               "the bounds are the smallest rectangle containing both")
           (ok (= 2 (length (render:region-rectangles region)))
               "two disjoint rectangles stay two")
           (render:region-clear region)
           (ok (render:region-empty-p region) "clearing empties it")
           (ok (null (render:region-rectangles region)) "and lists nothing"))
      (render:destroy-region region))))

(deftest a-region-unions-intersects-and-subtracts
  (let ((a (render:make-region))
        (b (render:make-region))
        (into (render:make-region)))
    (unwind-protect
         (progn
           (render:region-add a 0 0 10 10)
           (render:region-add b 5 5 10 10)
           (render:region-union into a b)
           (ok (equal '(0 0 15 15) (render:region-bounds into))
               "the union's bounds cover both")
           (render:region-intersect into a b)
           (ok (equal '(5 5 5 5) (render:region-bounds into))
               "the intersection is the overlap")
           (render:region-subtract into a b)
           (ok (equal 2 (length (render:region-rectangles into)))
               (format nil "a 10x10 square minus an overlapping 10x10 is two rectangles: ~S"
                       (render:region-rectangles into)))
           (ok (not (member '(0 0 10 10) (render:region-rectangles into) :test #'equal))
               "and not the rectangle it came from")
           (render:region-intersect-rect into a 20 20 5 5)
           (ok (render:region-empty-p into)
               "intersecting with a rectangle far away empties it")
           (render:region-set-rect into 3 4 5 6)
           (ok (equal '(3 4 5 6) (render:region-bounds into))
               "set-rect replaces the whole region")
           (render:region-translate into 10 -10)
           (ok (equal '(13 -6 5 6) (render:region-bounds into))
               "translate moves it"))
      (render:destroy-region a)
      (render:destroy-region b)
      (render:destroy-region into))))

(deftest an-empty-rectangle-adds-nothing
  (let ((region (render:make-region)))
    (unwind-protect
         (progn
           (render:region-add region 0 0 0 10)
           (render:region-add region 0 0 10 -5)
           (ok (render:region-empty-p region)
               "a client may damage zero pixels, and pixman need not hear about it"))
      (render:destroy-region region))))

;;; ---------------------------------------------------------------------------
;;; Transforms: the eight wl_output.transform values
;;; ---------------------------------------------------------------------------

(deftest a-quarter-turn-swaps-the-axes
  (dolist (transform '(0 2 4 6))
    (multiple-value-bind (width height)
        (render:buffer-display-size 64 32 transform)
      (ok (and (= 64 width) (= 32 height))
          (format nil "transform ~D keeps 64x32 as 64x32" transform))))
  (dolist (transform '(1 3 5 7))
    (multiple-value-bind (width height)
        (render:buffer-display-size 64 32 transform)
      (ok (and (= 32 width) (= 64 height))
          (format nil "transform ~D turns 64x32 into 32x64" transform)))))

(deftest a-transform-matrix-maps-destination-to-source
  "The matrices are checked against what the protocol says they mean.

sx = a*dx + b*dy + tx and sy = c*dx + d*dy + ty, mapping a point in the drawn
rectangle back to a pixel in the buffer.  The expectations below were derived from
the transform enum's own words -- \"90 degrees counter-clockwise\", and the flipped
family as \"an initial flip around a vertical axis followed by rotation\" -- and the
gate checks them again against rendered pixels, on a real client's buffer."
  (flet ((matrix (transform &key (buffer-width 64) (buffer-height 32)
                               (display-width 64) (display-height 32))
           (render:transform-matrix buffer-width buffer-height
                                    display-width display-height transform)))
    (ok (equal '(1 0 0 0 1 0 0 0 1) (matrix 0)) "normal is the identity")
    (ok (equal '(-1 0 64 0 1 0 0 0 1) (matrix 4))
        "flipped mirrors the vertical axis: sx = 64 - dx")
    (ok (equal '(1 0 0 0 -1 32 0 0 1) (matrix 6))
        "flipped-180 mirrors the horizontal axis: sy = 32 - dy")
    (ok (equal '(-1 0 64 0 -1 32 0 0 1) (matrix 2))
        "180 turns both axes around")
    ;; A quarter turn shows on both axes, so the swapped display size is passed.
    (ok (equal '(0 -1 64 1 0 0 0 0 1) (matrix 1 :display-width 32 :display-height 64))
        "90 is counter-clockwise: sx = 64 - dy, sy = dx")
    (ok (equal '(0 1 0 -1 0 32 0 0 1) (matrix 3 :display-width 32 :display-height 64))
        "270 is the other way: sx = dy, sy = 32 - dx")
    (ok (equal '(0 1 0 1 0 0 0 0 1) (matrix 5 :display-width 32 :display-height 64))
        "flipped-90 is the transpose: sx = dy, sy = dx")
    (ok (equal '(0 -1 64 -1 0 32 0 0 1) (matrix 7 :display-width 32 :display-height 64))
        "flipped-270: sx = 64 - dy, sy = 32 - dx")))

(deftest a-scaled-bitmap-is-drawn-at-its-destination-size
  "A 2x2 bitmap drawn into 4x4 becomes four 2x2 blocks, in order.

This is the renderer's own scale path (the one a client's buffer scale uses), with
no buffer, no surface and no protocol: just the transform and the pixels."
  (let* ((target (render:make-target 4 4))
         (octets (let ((octets (make-array 64 :element-type '(unsigned-byte 8)
                                              :initial-element 0)))
                   (loop for (index . argb) in '((0 . #xFFFF0000) (1 . #xFF00FF00)
                                                 (2 . #xFF0000FF) (3 . #xFFFFFFFF))
                         do (setf (aref octets (* 4 index)) (ldb (byte 8 0) argb)
                                  (aref octets (+ 1 (* 4 index))) (ldb (byte 8 8) argb)
                                  (aref octets (+ 2 (* 4 index))) (ldb (byte 8 16) argb)
                                  (aref octets (+ 3 (* 4 index))) (ldb (byte 8 24) argb)))
                   octets)))
    (unwind-protect
         (progn
           (render:composite-bitmap target octets 2 2
                                    :x 0 :y 0 :dest-width 4 :dest-height 4)
           (let ((pixels (loop for y below 4
                               collect (loop for x below 4
                                             collect (render::target-pixel target x y)))))
             (ok (equal '((#xFFFF0000 #xFFFF0000 #xFF00FF00 #xFF00FF00)
                          (#xFFFF0000 #xFFFF0000 #xFF00FF00 #xFF00FF00)
                          (#xFF0000FF #xFF0000FF #xFFFFFFFF #xFFFFFFFF)
                          (#xFF0000FF #xFF0000FF #xFFFFFFFF #xFFFFFFFF))
                        pixels)
                 "each source pixel became a 2x2 block, nearest-neighbour")))
      (render:destroy-target target))))

;;; ---------------------------------------------------------------------------
;;; Scale: layout coordinates, device pixels
;;; ---------------------------------------------------------------------------

(deftest a-surfaces-layout-size-divides-out-its-buffer-scale
  (multiple-value-bind (width height)
      (scene:surface-layout-size (fake-surface :width 64 :height 32 :buffer-scale 2
                                               :mapped-p t))
    (ok (and (= 32 width) (= 16 height))
        "a scale-2 buffer of 64x32 is a 32x16 surface"))
  (multiple-value-bind (width height)
      (scene:surface-layout-size (fake-surface :width 64 :height 32 :transform 1
                                               :mapped-p t))
    (ok (and (= 32 width) (= 64 height))
        "a rotated buffer is the swapped size"))
  (multiple-value-bind (width height)
      (scene:surface-layout-size (fake-surface :width 64 :height 32 :buffer-scale 2
                                               :transform 1 :mapped-p t))
    (ok (and (= 16 width) (= 32 height))
        "and both at once: 64x32 at scale 2, turned, is 16x32")))

(deftest a-buffer-node-is-hit-in-layout-coordinates
  (let* ((scene (scene:make-scene 100 100))
         (surface (fake-surface :width 64 :height 32 :buffer-scale 2 :mapped-p t))
         (node (scene:scene-add-node scene (scene:make-buffer-node surface)
                                     :x 10 :y 10)))
    (ok (= 32 (scene:node-width node)) "the node is as wide as the layout says")
    (ok (= 16 (scene:node-height node)))
    (ok (eq node (scene:scene-hit-test scene 11 11))
        "a click at the window's top-left hits it")
    (ok (eq node (scene:scene-hit-test scene 41 25))
        "and so does a click at its far corner")
    (ok (null (scene:scene-hit-test scene 43 11))
        "but not past its layout width, even though its buffer is 64 wide")))

(deftest the-draw-list-turns-layout-into-device-pixels
  (let* ((scene (scene:make-scene 100 100 :scale 2))
         (surface (fake-surface :width 64 :height 32 :mapped-p t)))
    (scene:scene-add-node scene (scene:make-buffer-node surface) :x 10 :y 10)
    (setf (scene:scene-cursor-visible-p scene) nil)
    (let ((item (first (scene:scene-draw-list scene))))
      (ok (equal (list 20 20 128 64)
                 (list (scene:draw-item-x item) (scene:draw-item-y item)
                       (scene:draw-item-width item) (scene:draw-item-height item)))
          "placed at (10,10) and 64x32 in layout, it is (20,20) and 128x64 in device")))
  (let* ((scene (scene:make-scene 100 100 :scale 2))
         (surface (fake-surface :width 64 :height 32 :buffer-scale 2 :mapped-p t)))
    (scene:scene-add-node scene (scene:make-buffer-node surface) :x 10 :y 10)
    (setf (scene:scene-cursor-visible-p scene) nil)
    (let ((item (first (scene:scene-draw-list scene))))
      (ok (equal (list 20 20 64 32)
                 (list (scene:draw-item-x item) (scene:draw-item-y item)
                       (scene:draw-item-width item) (scene:draw-item-height item)))
          "a scale-2 buffer on a scale-2 output is drawn 1:1, twice as big as layout"))))

(deftest a-scale-two-output-draws-at-twice-the-size
  (with-compositor (compositor :width 32 :height 32 :scale 2)
    (ok (= 64 (cf:compositor-device-width compositor))
        "the target is 64 device pixels wide")
    (let ((scene (cf:compositor-scene compositor)))
      (scene:scene-add-node scene (scene:make-rect-node 8 8 #xFF00FF00) :x 10 :y 10)
      (setf (cf:compositor-cursor-visible-p compositor) nil))
    (cf:render-frame compositor)
    (ok (= #xFF00FF00 (cf:frame-pixel compositor 11 11))
        "the rectangle covers layout (10,10), read as a layout coordinate")
    (ok (= #xFF00FF00 (cf:frame-pixel-device compositor 20 20))
        "and starts at device (20,20)")
    (ok (= +background+ (cf:frame-pixel-device compositor 19 19))
        "one device pixel earlier is background")))

;;; ---------------------------------------------------------------------------
;;; Damage
;;; ---------------------------------------------------------------------------

(deftest a-frame-with-nothing-to-draw-repaints-nothing
  (with-compositor (compositor :width 32 :height 32)
    (setf (cf:compositor-cursor-visible-p compositor) nil)
    (cf:render-frame compositor)
    (ok (eq :full (cf:output-damage-bounds compositor))
        "the first frame repaints the whole output")
    (cf:render-frame compositor)
    (ok (null (cf:output-damage-bounds compositor))
        "a second frame with nothing changed repaints nothing")
    (ok (= 1 (cf:compositor-partial-frame-count compositor))
        "and it counted as a partial frame")))

(deftest a-moved-node-damages-both-where-it-was-and-where-it-is
  (with-compositor (compositor :width 64 :height 64)
    (setf (cf:compositor-cursor-visible-p compositor) nil)
    (let* ((scene (cf:compositor-scene compositor))
           (node (scene:scene-add-node scene (scene:make-rect-node 10 10 #xFF00FF00)
                                       :x 5 :y 5)))
      (cf:render-frame compositor)
      (scene:set-node-position node 20 20)
      (cf:render-frame compositor)
      (let ((bounds (cf:output-damage-bounds compositor)))
        (ok (equal '(5 5 25 25) bounds)
            (format nil "the damage covers the old place and the new one: ~S" bounds)))
      (ok (= #xFF00FF00 (cf:frame-pixel compositor 22 22)) "drawn in the new place")
      (ok (= +background+ (cf:frame-pixel compositor 7 7))
          "and the old place is background again"))))

(deftest invalidate-output-repaints-everything-once
  (with-compositor (compositor :width 32 :height 32)
    (setf (cf:compositor-cursor-visible-p compositor) nil)
    (cf:render-frame compositor)
    (cf:invalidate-output compositor)
    (cf:render-frame compositor)
    (ok (eq :full (cf:output-damage-bounds compositor))
        "the frame after INVALIDATE-OUTPUT is whole")
    (cf:render-frame compositor)
    (ok (null (cf:output-damage-bounds compositor))
        "and the frame after that goes back to damage")))

(deftest an-opaque-window-uncovers-what-it-hid
  "Opaque culling must never be visible: what a window hid comes back when it goes.

The bottom rectangle is green, the top one blue and opaque.  Removing the top one
must repaint the green underneath -- which happens because the diff damages the
rectangle that disappeared, not because anything remembered the green."
  (with-compositor (compositor :width 40 :height 40)
    (setf (cf:compositor-cursor-visible-p compositor) nil)
    (let* ((scene (cf:compositor-scene compositor))
           (top (progn
                  (scene:scene-add-node scene (scene:make-rect-node 30 30 #xFF00FF00)
                                        :x 5 :y 5)
                  (scene:scene-add-node scene (scene:make-rect-node 10 10 #xFF0000FF)
                                        :x 10 :y 10))))
      (cf:render-frame compositor)
      (ok (= #xFF0000FF (cf:frame-pixel compositor 12 12)) "the top window covers the bottom")
      (scene:scene-remove-node top)
      (cf:render-frame compositor)
      (ok (= #xFF00FF00 (cf:frame-pixel compositor 12 12))
          "and the bottom window is visible again once it is gone")
      (ok (= +background+ (cf:frame-pixel compositor 2 2))
          "the area that never held anything stayed background"))))

(deftest a-translucent-rectangle-does-not-hide-what-is-under-it
  (with-compositor (compositor :width 32 :height 32)
    (setf (cf:compositor-cursor-visible-p compositor) nil)
    (let ((scene (cf:compositor-scene compositor)))
      (scene:scene-add-node scene (scene:make-rect-node 10 10 #xFF00FF00) :x 5 :y 5)
      ;; 50% white over the middle of the green.
      (scene:scene-add-node scene (scene:make-rect-node 4 4 #x80808080) :x 8 :y 8)
      (let ((items (scene:scene-draw-list scene)))
        ;; Back to front: the green rectangle first, the veil last.
        (ok (slot-value (first items) 'cf.scene::opaque)
            "the opaque rectangle below hides what is under it")
        (ok (null (slot-value (car (last items)) 'cf.scene::opaque))
            "the translucent rectangle claims no opacity, so nothing is culled for it")))
    (cf:render-frame compositor)
    (let ((pixel (cf:frame-pixel compositor 9 9)))
      ;; 50% white over opaque green, premultiplied: green stays saturated and the
      ;; red and blue channels come up to half.
      (ok (= #xFF80FF80 pixel)
          (format nil "the veil blended over the green: #x~8,'0X, expected #xFF80FF80" pixel)))))

(deftest a-partial-repaint-is-a-full-repaint
  "The invariant damage tracking rests on: incremental drawing is the same picture.

Two opaque rectangles and a translucent one over them, moved a little at a time so
that each frame's damage is a small part of the output; then the whole output is
repainted and compared pixel for pixel.  Opaque culling is exercised on the way --
the bottom rectangle's covered corner is not painted in the partial frames -- so a
culling bug shows up here as a difference, not as a story about performance."
  (with-compositor (compositor :width 40 :height 40)
    (setf (cf:compositor-cursor-visible-p compositor) nil)
    (let* ((scene (cf:compositor-scene compositor))
           (top (progn
                  (scene:scene-add-node scene (scene:make-rect-node 30 30 #xFF00FF00)
                                        :x 4 :y 4)
                  (scene:scene-add-node scene (scene:make-rect-node 16 16 #xFF0000FF)
                                        :x 8 :y 8)))
           (veil (scene:scene-add-node scene (scene:make-rect-node 10 10 #x80808080)
                                       :x 20 :y 4)))
      (cf:render-frame compositor)
      (dolist (step '((3 0) (0 5) (-2 3) (6 -4)))
        (incf (scene:node-x top) (first step))
        (incf (scene:node-y top) (second step))
        (incf (scene:node-x veil) (- (second step)))
        (cf:render-frame compositor))
      (let ((partial (cf:frame-octets compositor))
            (bounds (cf:output-damage-bounds compositor)))
        (ok (and bounds (< (third bounds) 40))
            (format nil "the last partial frame repainted less than the whole width: ~S"
                    bounds))
        (cf:invalidate-output compositor)
        (cf:render-frame compositor)
        (ok (equalp partial (cf:frame-octets compositor))
            "a partial repaint equals a full repaint, pixel for pixel")))))

;;; ---------------------------------------------------------------------------
;;; Buffer age: the nested backend's two slots
;;; ---------------------------------------------------------------------------

(defun make-test-backend (&key (width 100) (height 80))
  "A nested backend with no display, for the damage arithmetic alone.

SLOT-REPAINT-REGION and RECORD-FRAME-DAMAGE read only the slots and the history, so
the arithmetic can be checked without a parent, a socket or a frame."
  (make-instance 'cf.backend.nested::nested-backend
                 :display nil :compositor nil :width width :height height))

(deftest a-buffer-nobody-has-seen-is-painted-whole
  (let ((backend (make-test-backend))
        (slot (cf.backend.nested::make-buffer-slot)))
    (ok (eq :full (cf.backend.nested::slot-repaint-region backend slot 1))
        "a buffer the parent has never seen has nothing to trust")))

(deftest a-buffer-repaints-the-frames-it-missed
  ;; Two slots alternate: a slot drawn at frame 1 is used again at frame 3, so it
  ;; missed frame 2 -- and only frame 2's damage has to be painted into it.
  (let* ((backend (make-test-backend))
         (a (cf.backend.nested::make-buffer-slot :repaint (render:make-region)))
         (b (cf.backend.nested::make-buffer-slot :repaint (render:make-region)))
         (damage (render:make-region)))
    (setf (cf.backend.nested::buffer-slot-frame a) 1)
    (setf (cf.backend.nested::buffer-slot-frame b) 2)
    (render:region-add damage 10 10 5 5)
    (cf.backend.nested::record-frame-damage backend 2 damage)
    (let ((region (cf.backend.nested::slot-repaint-region backend a 3)))
      (ok (not (eq :full region)) "an age-2 buffer is repainted, not painted whole")
      (ok (equal '(10 10 5 5) (render:region-bounds region))
          (format nil "and the region is the damage of the frame it missed: ~S"
                  (render:region-bounds region))))
    (ok (eq :full (cf.backend.nested::slot-repaint-region backend a 4))
        "a buffer three frames old is painted whole")))

(deftest a-frame-that-painted-everything-makes-the-next-slot-whole
  ;; A resize paints everything; the slot that missed it cannot be told that only
  ;; part of its contents is stale, so it is repainted whole.
  (let* ((backend (make-test-backend))
         (a (cf.backend.nested::make-buffer-slot :repaint (render:make-region))))
    (setf (cf.backend.nested::buffer-slot-frame a) 1)
    (cf.backend.nested::record-frame-damage backend 2 nil)   ; :full, recorded as NIL
    (ok (eq :full (cf.backend.nested::slot-repaint-region backend a 3))
        "a missed full frame makes the buffer whole")))

(deftest a-frame-nobody-recorded-makes-the-next-slot-whole
  (let* ((backend (make-test-backend))
         (a (cf.backend.nested::make-buffer-slot :repaint (render:make-region))))
    (setf (cf.backend.nested::buffer-slot-frame a) 1)
    (ok (eq :full (cf.backend.nested::slot-repaint-region backend a 3))
        "an age-2 buffer whose missing frame has no entry is painted whole")))

(deftest the-history-keeps-two-frames-and-no-more
  (let ((backend (make-test-backend))
        (damage (render:make-region)))
    (render:region-add damage 0 0 100 80)
    (dotimes (frame 5)
      (cf.backend.nested::record-frame-damage backend (1+ frame) damage))
    (ok (= 2 (length (cf.backend.nested::nested-damage-history backend)))
        "five frames in, the history holds the last two")
    (ok (equal '(5 4) (mapcar #'car (cf.backend.nested::nested-damage-history backend)))
        "newest first")
    (ok (= 2 (length (cf.backend.nested::nested-history-regions backend)))
        "and it reuses two regions rather than allocating one per frame")))

(deftest scene-render-draws-the-whole-target
  "The convenience entry point: no damage argument means \"draw what is there\".

The compositor's own frame loop passes a damage region; this is the call a REPL or a
test makes, and it has to mean the same thing as a frame that damaged everything."
  (let ((target (render:make-target 20 20))
        (scene (scene:make-scene 20 20)))
    (unwind-protect
         (progn
           (scene:scene-add-node scene (scene:make-rect-node 4 4 #xFF00FF00) :x 2 :y 2)
           (setf (scene:scene-cursor-visible-p scene) nil)
           (multiple-value-bind (drawn items) (scene:scene-render scene target)
             (declare (ignore drawn))
             (ok (= 1 (length items)) "the scene has one item to draw")
             (ok (= #xFF00FF00 (render::target-pixel target 3 3))
                 "and it was drawn into the target")
             (ok (= 0 (render::target-pixel target 10 10))
                 "while the rest of the target was left alone")))
      (render:destroy-target target))))
