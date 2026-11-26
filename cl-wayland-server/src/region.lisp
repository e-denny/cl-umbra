;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; wl_region: a set of rectangles with real union and difference.
;;;;
;;;; Regions describe the opaque and input parts of a surface.  Until the renderer
;;;; and the seat act on them (2b), the only thing that can be wrong is the set
;;;; arithmetic itself, so that is what this file is careful about:
;;;;
;;;;   add      union: keep the new rectangle, and keep the old ones too
;;;;   subtract difference: each existing rectangle is clipped against the removed
;;;;            one, which can produce up to four pieces
;;;;   commit   the surface snapshots the rectangle list, because the client is
;;;;            free to destroy the wl_region immediately after setting it
;;;;
;;;; A degenerate rectangle (width or height <= 0) contributes no area.  The
;;;; protocol has no error for one, so it is ignored rather than refused.

(in-package #:wayland.server)

;;; ---------------------------------------------------------------------------
;;; Rectangle arithmetic
;;; ---------------------------------------------------------------------------

(defun rectangle-area-positive-p (rectangle)
  (destructuring-bind (x y width height) rectangle
    (declare (ignore x y))
    (and (plusp width) (plusp height))))

(defun rectangle-difference (rectangle cut)
  "RECTANGLE minus CUT, as a list of 0..4 rectangles that together are the rest."
  (destructuring-bind (x y width height) rectangle
    (destructuring-bind (cx cy cwidth cheight) cut
      (let ((x-end (+ x width))
            (y-end (+ y height))
            (cx-end (+ cx cwidth))
            (cy-end (+ cy cheight)))
        (let ((left (max x cx))
              (top (max y cy))
              (right (min x-end cx-end))
              (bottom (min y-end cy-end)))
          (if (or (>= left right) (>= top bottom))
              (list rectangle)                  ; no overlap at all
              (let ((pieces '()))
                ;; The four slabs around the overlap; empty ones vanish.
                (when (> left x)
                  (push (list x y (- left x) height) pieces))
                (when (> x-end right)
                  (push (list right y (- x-end right) height) pieces))
                (when (> top y)
                  (push (list left y (- right left) (- top y)) pieces))
                (when (> y-end bottom)
                  (push (list left bottom (- right left) (- y-end bottom)) pieces))
                (nreverse pieces))))))))

;;; ---------------------------------------------------------------------------
;;; The operations
;;; ---------------------------------------------------------------------------

(defun region-add-rectangle (region rectangle)
  "Union: RECTANGLE becomes part of REGION's area."
  (when (rectangle-area-positive-p rectangle)
    (push rectangle (region-rects region)))
  region)

(defun region-subtract-rectangle (region rectangle)
  "Difference: every part of REGION that overlaps RECTANGLE stops being in it."
  (when (rectangle-area-positive-p rectangle)
    (setf (region-rects region)
          (loop for existing in (region-rects region)
                append (rectangle-difference existing rectangle))))
  region)

(defun region-empty-p (region)
  (null (region-rects region)))

(defun region-contains-p (region x y)
  "Is (X, Y) inside the region?  A real question for input regions in 2b.

Half-open, as every rectangle in the protocol is: a 10-wide rectangle starting
at 0 contains x = 0 .. 9, not 10."
  (loop for (rx ry width height) in (region-rects region)
        thereis (and (<= rx x) (< x (+ rx width))
                     (<= ry y) (< y (+ ry height)))))

(defun region-rectangles (region)
  "A snapshot of the region's rectangles, safe to keep after the region dies."
  (copy-list (region-rects region)))

;;; ---------------------------------------------------------------------------
;;; wl_compositor.create_region
;;; ---------------------------------------------------------------------------

(defmethod wl-compositor.create-region ((compositor compositor))
  (let ((region (allocate-resource (resource-client compositor)
                                   (resolve-interface "wl_region")
                                   :version (resource-version compositor)
                                   :class 'region
                                   :destroy-function #'destroy-region)))
    (log-message :debug "client ~D: region ~D created"
                 (client-id (resource-client compositor)) (resource-id region))
    region))

(defun destroy-region (region)
  (setf (region-rects region) nil)
  nil)

;;; ---------------------------------------------------------------------------
;;; wl_region
;;; ---------------------------------------------------------------------------

(defmethod wl-region.add ((region region) x y width height)
  (region-add-rectangle region (list x y width height)))

(defmethod wl-region.subtract ((region region) x y width height)
  (region-subtract-rectangle region (list x y width height)))

(defmethod wl-region.destroy ((region region))
  (destroy-resource region))
