;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Surfaces, regions and buffers: the objects a client draws with.
;;;;
;;;; The schema already defines wl-compositor.create-surface and friends as
;;;; generic functions with the XML's arguments (cl-wayland-core/src/schema.lisp);
;;;; this file is the client's method for each, one line of wire per call.
;;;;
;;;; Everything here is deliberately thin.  A surface is an id and a hook list; the
;;;; interesting work -- pools, mappings, pixels -- is src/shm.lisp, and the
;;;; compositor's job (what a commit *means*) is not a client concern at all.
;;;;
;;;; Versions matter in one direction only: a child object speaks the version of
;;;; its parent, clamped to what the interface itself knows (CLAMP-VERSION).  A
;;;; wl_surface created from a v3 compositor is a v3 wl_surface, so the client
;;;; never sends damage_buffer to a compositor that would answer with an error.

(in-package #:wayland.client)

;;; ---------------------------------------------------------------------------
;;; The objects
;;; ---------------------------------------------------------------------------

(defclass compositor (proxy) ()
  (:documentation "wl_compositor: a factory for surfaces and regions."))

(defclass surface (proxy) ()
  (:documentation "wl_surface: a rectangular area a client draws into."))

(defclass region (proxy) ()
  (:documentation "wl_region: a set of rectangles, added and subtracted."))

(defclass buffer (proxy) ()
  (:documentation "wl_buffer: a range of a wl_shm pool, or (later) a dmabuf."))

(defclass callback (proxy) ()
  (:documentation "wl_callback: the one-shot object wl_surface.frame returns."))

(dolist (entry '(("wl_compositor" . compositor)
                 ("wl_surface" . surface)
                 ("wl_region" . region)
                 ("wl_buffer" . buffer)
                 ("wl_callback" . callback)))
  (register-proxy-class (car entry) (cdr entry)))

(defun allocate-child (parent interface &key class)
  "A new proxy for INTERFACE, spoken at PARENT's version."
  (allocate-proxy (proxy-display parent) interface
                  :version (proxy-version parent)
                  :class class))

;;; ---------------------------------------------------------------------------
;;; wl_compositor
;;; ---------------------------------------------------------------------------

(defmethod wl-compositor.create-surface ((compositor compositor))
  "Create a surface; it draws nothing until something is attached and committed."
  (check-live compositor)
  (let ((surface (allocate-child compositor "wl_surface")))
    (send-request compositor (interface-request (proxy-interface compositor) 0)
                  (proxy-id surface))
    surface))

(defmethod wl-compositor.create-region ((compositor compositor))
  "Create an empty region.  An empty region is *not* the same as no region:

no region means \"everything\", an empty region means \"nothing\" -- which is how a
client says \"let the pointer through here\" (D31.5)."
  (check-live compositor)
  (let ((region (allocate-child compositor "wl_region")))
    (send-request compositor (interface-request (proxy-interface compositor) 1)
                  (proxy-id region))
    region))

;;; ---------------------------------------------------------------------------
;;; wl_surface
;;; ---------------------------------------------------------------------------
;;
;; Two requests are worth a comment because their NIL arguments are meaningful
;; rather than missing: attach(nil) means "hide this surface", and both region
;; requests take nil to mean "no region" (whole surface for input, nothing opaque
;; for the renderer).  The schema declares all three :allow-null, so the encoder
;; accepts NIL and puts a zero id on the wire.

(defmethod wl-surface.attach ((surface surface) buffer x y)
  "Attach BUFFER at (X, Y) in surface-local coordinates; NIL hides the surface.

The position is part of the *commit*, not of the buffer: a client that only moves
its pixels re-attaches the same buffer at a different offset."
  (check-live surface)
  (send-request surface (interface-request (proxy-interface surface) 1)
                buffer x y))

(defmethod wl-surface.damage ((surface surface) x y width height)
  "Damage a surface-local rectangle.  The compositor may ignore it (v0 does)."
  (check-live surface)
  (send-request surface (interface-request (proxy-interface surface) 2)
                x y width height))

(defmethod wl-surface.frame ((surface surface))
  "Ask for a callback that fires after the frame containing the next commit.

Returns the wl_callback proxy.  The server destroys it after `done', so the id
comes back through wl_display.delete_id without the client doing anything."
  (check-live surface)
  (let ((callback (allocate-child surface "wl_callback" :class 'callback)))
    (send-request surface (interface-request (proxy-interface surface) 3)
                  (proxy-id callback))
    callback))

(defmethod wl-surface.set-opaque-region ((surface surface) region)
  "Declare the part of the surface that is fully opaque; NIL means none."
  (check-live surface)
  (send-request surface (interface-request (proxy-interface surface) 4)
                region))

(defmethod wl-surface.set-input-region ((surface surface) region)
  "Declare where the surface accepts input; NIL means all of it."
  (check-live surface)
  (send-request surface (interface-request (proxy-interface surface) 5)
                region))

(defmethod wl-surface.commit ((surface surface))
  "Make the pending state current.  The compositor answers with a frame, eventually."
  (check-live surface)
  (send-request surface (interface-request (proxy-interface surface) 6)))

(defmethod wl-surface.set-buffer-transform ((surface surface) transform)
  "Ask for the buffer to be drawn rotated/flipped; stored, not applied (D29)."
  (check-live surface)
  (send-request surface (interface-request (proxy-interface surface) 7)
                transform))

(defmethod wl-surface.set-buffer-scale ((surface surface) scale)
  "Ask for the buffer to be drawn at SCALE; stored, not applied (D29)."
  (check-live surface)
  (send-request surface (interface-request (proxy-interface surface) 8)
                scale))

(defmethod wl-surface.destroy ((surface surface))
  "Destroy the surface.  The proxy stays until wl_display.delete_id arrives."
  (check-live surface)
  (send-request surface (interface-request (proxy-interface surface) 0)))

;;; ---------------------------------------------------------------------------
;;; wl_region
;;; ---------------------------------------------------------------------------

(defmethod wl-region.add ((region region) x y width height)
  "Add a rectangle to REGION."
  (check-live region)
  (send-request region (interface-request (proxy-interface region) 1)
                x y width height))

(defmethod wl-region.subtract ((region region) x y width height)
  "Remove a rectangle from REGION."
  (check-live region)
  (send-request region (interface-request (proxy-interface region) 2)
                x y width height))

(defmethod wl-region.destroy ((region region))
  "Destroy the region.  The compositor must have copied what it needs (D31.5)."
  (check-live region)
  (send-request region (interface-request (proxy-interface region) 0)))

;;; ---------------------------------------------------------------------------
;;; wl_buffer
;;; ---------------------------------------------------------------------------

(defmethod wl-buffer.destroy ((buffer buffer))
  "Destroy the buffer; a compositor still drawing it finishes that frame first."
  (check-live buffer)
  (send-request buffer (interface-request (proxy-interface buffer) 0)))
