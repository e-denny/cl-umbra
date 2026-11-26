;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; wl_compositor and wl_surface: the pending/current state machine, as far as a
;;;; shm client needs it (docs/architecture.md §3, docs/memory-and-rendering.md §3).
;;;;
;;;; wl_surface is a double buffer.  A client attaches, damages and asks for frame
;;;; callbacks; nothing becomes visible until commit, and commit is where the
;;;; previous contents stop being the compositor's to use:
;;;;
;;;;   attach(buf) ... commit   -> current-buffer := buf, previous one released
;;;;   damage(x,y,w,h)          -> accumulated, handed to the compositor on commit
;;;;   frame(callback)          -> fires after the frame containing this commit is
;;;;                               presented, never at commit time
;;;;
;;;; Policy is not here.  What a compositor *does* when a surface commits is a
;;;; generic function with a do-nothing default, so `wayland.server` works without
;;;; a renderer and `cf.backend.headless` only has to specialise it.
;;;;
;;;; Regions (opaque, input) are stored and ignored: this server has no input and
;;;; an opaque-by-construction target, so honouring them would change nothing.

(in-package #:wayland.server)

;;; ---------------------------------------------------------------------------
;;; The hooks a compositor specialises
;;; ---------------------------------------------------------------------------

(defgeneric surface-committed (surface damage)
  (:documentation
   "SURFACE's pending state became current.  DAMAGE is a list of (x y width
height) rectangles in surface-local coordinates, possibly empty.

The default does nothing: a transport-only server has no output to damage.  A
compositor specialises this to mark its output dirty and schedule a frame.")
  (:method ((surface surface) damage)
    (declare (ignore surface damage))
    nil))

(defgeneric surface-presented (surface)
  (:documentation
   "The frame containing SURFACE's current contents has been presented, so its
committed frame callbacks can fire.  The default fires them immediately with the
current time, which is right for a compositor that renders synchronously.")
  (:method ((surface surface))
    (fire-frame-callbacks surface (frame-timestamp))))

;;; ---------------------------------------------------------------------------
;;; Shell role hooks
;;; ---------------------------------------------------------------------------
;;
;; A wl_surface draws; what it *is* -- a toplevel, a popup, a layer surface -- is
;; a role, and in this server the role is a separate protocol object linked from
;; SURFACE-SHELL-SURFACE.  Three hooks are all the commit path needs to offer:
;;
;;   CHECK-COMMIT  before the pending state becomes current: the role may refuse
;;                 the commit (xdg_surface: a buffer before the first ack).
;;   COMMITTED     after it: the role may produce events the commit implies
;;                 (xdg_surface: the initial configure).
;;   LOST          the surface died under the role, so the role must stop
;;                 pointing at it.
;;
;; The defaults do nothing, so a bare wl_surface keeps working exactly as it did
;; in phase 2a, and a role only pays for the hooks it defines.

(defgeneric surface-shell-check-commit (shell-surface surface)
  (:documentation
   "SURFACE is committing; SHELL-SURFACE may reject it with a protocol error.")
  (:method (shell-surface surface)
    (declare (ignore shell-surface surface))
    nil))

(defgeneric surface-shell-committed (shell-surface surface damage)
  (:documentation
   "SURFACE's pending state became current; SHELL-SURFACE sees the commit.")
  (:method (shell-surface surface damage)
    (declare (ignore shell-surface surface damage))
    nil))

(defgeneric surface-shell-lost (shell-surface surface)
  (:documentation
   "SURFACE is being destroyed while SHELL-SURFACE still describes it.")
  (:method (shell-surface surface)
    (declare (ignore shell-surface surface))
    nil))

(defun frame-timestamp ()
  "Milliseconds, wrapped at 32 bits: the unit wl_callback.done carries."
  (logand (round (* 1000 (monotonic-now))) #xFFFFFFFF))

;;; ---------------------------------------------------------------------------
;;; Frame callbacks
;;; ---------------------------------------------------------------------------

(defun fire-frame-callbacks (surface &optional (timestamp (frame-timestamp)))
  "Send wl_callback.done to every callback committed and not yet fired.

Each callback is one-shot: the client chose its id, so destroying it sends
wl_display.delete_id and the id becomes reusable."
  (let ((callbacks (prog1 (surface-committed-callbacks surface)
                     (setf (surface-committed-callbacks surface) nil))))
    (log-message :debug "surface ~D: firing ~D frame callback~:P"
                 (resource-id surface) (length callbacks))
    (dolist (callback callbacks)
      (unless (resource-destroyed-p callback)
        (wl-callback.done callback timestamp)
        (destroy-resource callback)))
    (length callbacks)))

;;; ---------------------------------------------------------------------------
;;; Buffer lifetime
;;; ---------------------------------------------------------------------------

(defun release-surface-buffer (surface)
  "The compositor is done with SURFACE's current buffer; let the client reuse it."
  (let ((buffer (surface-current-buffer surface)))
    (when buffer
      (release-shm-buffer buffer))))

(defmethod wl-surface.set-buffer-transform ((surface surface) transform)
  "Accept the transform a v2 client may set; apply none of it yet.

The protocol has no error enum entry for a transform that is merely unimplemented,
so the honest thing is to store it, say so once at :debug, and let 2b's renderer
start honouring it.  Values outside the enum are a real error."
  (when (or (minusp transform) (> transform 7))
    (protocol-error (resource-client surface) (resource-id surface)
                    +wl-surface-error-invalid-transform+
                    "transform ~D is not a wl_output.transform value" transform))
  (setf (surface-buffer-transform surface) transform)
  (when (plusp transform)
    (log-message :debug "client ~D: surface ~D transform ~D stored, not applied yet"
                 (client-id (resource-client surface)) (resource-id surface)
                 transform))
  surface)

(defmethod wl-surface.set-buffer-scale ((surface surface) scale)
  "Accept a positive buffer scale; draw at 1:1 until the renderer scales.

The headless output advertises scale 1, so a client that respects the output sets
1 and nothing is lost.  A client that sets 2 anyway gets a correctly cropped
window at half the size it expected, which is a documented 2b gap -- not a silent
protocol error, and not a promise the version bump made."
  (unless (plusp scale)
    (protocol-error (resource-client surface) (resource-id surface)
                    +wl-surface-error-invalid-scale+
                    "buffer scale ~D is not positive" scale))
  (setf (surface-buffer-scale surface) scale)
  (unless (= scale 1)
    (log-message :debug "client ~D: surface ~D buffer scale ~D stored, drawn 1:1"
                 (client-id (resource-client surface)) (resource-id surface) scale))
  surface)

(defun destroy-surface (surface)
  "Finish the surface's buffers and callbacks, then let the pool go.

A callback that will never fire is destroyed rather than leaked: the client's id
comes back, and the client's event loop stops waiting for it.  A shell role that
describes this surface is told it has lost it, so that no later request can write
to an id that no longer exists."
  (let ((shell (surface-shell-surface surface)))
    (when shell
      (setf (surface-shell-surface surface) nil)
      (surface-shell-lost shell surface)))
  (release-surface-buffer surface)
  (dolist (callback (append (surface-committed-callbacks surface)
                            (surface-pending-frame-callbacks surface)))
    (unless (resource-destroyed-p callback)
      (destroy-resource callback)))
  (setf (surface-committed-callbacks surface) nil
        (surface-pending-frame-callbacks surface) nil
        (surface-current-buffer surface) nil
        (surface-pending-buffer surface) nil
        (surface-mapped-p surface) nil))

;;; ---------------------------------------------------------------------------
;;; wl_compositor
;;; ---------------------------------------------------------------------------

(defmethod wl-compositor.create-surface ((compositor compositor))
  (let ((surface (allocate-resource (resource-client compositor)
                                    (resolve-interface "wl_surface")
                                    :version (resource-version compositor)
                                    :class (compositor-surface-class compositor)
                                    :destroy-function #'destroy-surface)))
    (setf (surface-owner surface) compositor)
    (log-message :debug "client ~D: surface ~D created as ~A"
                 (client-id (resource-client compositor))
                 (resource-id surface)
                 (class-name (class-of surface)))
    surface))

;; wl_compositor.create_region has no method on purpose.  Regions matter for input
;; and for opaque optimisation, neither of which exists yet, and a *missing*
;; method is exactly how the dispatch layer reports `implementation' on the right
;; object.  Defining one that errors would move the error to wl_display and call
;; it an internal failure, which is a different and less honest thing to say.

;;; ---------------------------------------------------------------------------
;;; wl_surface
;;; ---------------------------------------------------------------------------

(defmethod wl-surface.attach ((surface surface) buffer x y)
  ;; Attaching transfers the pixels to us until we present (and release) them;
  ;; an attach of NIL is an unmap and claims nothing.
  (when buffer
    (claim-shm-buffer buffer))
  (setf (surface-pending-attach-p surface) t
        (surface-pending-buffer surface) buffer
        (surface-pending-x surface) (or x 0)
        (surface-pending-y surface) (or y 0))
  surface)

(defmethod wl-surface.damage ((surface surface) x y width height)
  "Accumulate a damage rectangle.  Nothing is clipped here: the renderer clips."
  (push (list (or x 0) (or y 0) (or width 0) (or height 0))
        (surface-pending-damage surface))
  surface)

(defmethod wl-surface.frame ((surface surface))
  "Create the wl_callback the client asked for; it fires after presentation."
  (let ((callback (allocate-resource (resource-client surface)
                                     (resolve-interface "wl_callback")
                                     :version 1
                                     :class 'callback)))
    (setf (surface-pending-frame-callbacks surface)
          (append (surface-pending-frame-callbacks surface)
                  (list callback)))
    callback))

(defmethod wl-surface.set-opaque-region ((surface surface) region)
  "Pending until commit, like every other piece of surface state."
  (setf (surface-pending-opaque-region surface) region
        (surface-pending-opaque-region-p surface) t)
  surface)

(defmethod wl-surface.set-input-region ((surface surface) region)
  (setf (surface-pending-input-region surface) region
        (surface-pending-input-region-p surface) t)
  surface)

(defmethod wl-surface.commit ((surface surface))
  "Make the pending state current; release what it replaced; hand damage on.

The order matters: the new buffer becomes current first, so the release of the
old one cannot be mistaken for the new one's; then the frame callbacks move to
the committed set, because a callback committed *with* a buffer must not fire
before that buffer was presented."
  (let ((attached-p (surface-pending-attach-p surface))
        (damage (nreverse (surface-pending-damage surface)))
        (shell (surface-shell-surface surface)))
    ;; The role gets its veto before anything becomes visible: an xdg_surface
    ;; refuses a buffer attached before its first configure was acked.
    (when shell
      (surface-shell-check-commit shell surface))
    (when attached-p
      (let ((old (surface-current-buffer surface))
            (new (surface-pending-buffer surface)))
        (setf (surface-current-buffer surface) new
              (surface-current-x surface) (surface-pending-x surface)
              (surface-current-y surface) (surface-pending-y surface)
              (surface-mapped-p surface) (and new t)
              (surface-pending-attach-p surface) nil
              (surface-pending-buffer surface) nil)
        ;; A buffer replaced without ever being presented (two commits in one
        ;; batch) is released here, or the client would wait for it forever.  A
        ;; buffer that *was* presented has been released already and this is a
        ;; no-op.
        (when (and old (not (eq old new)))
          (release-shm-buffer old))))
    (setf (surface-pending-damage surface) nil)
    ;; Regions are snapshotted, not referenced: the client may destroy the
    ;; wl_region object as soon as the commit is sent (docs/memory-and-rendering.md
    ;; §3 -- foreign state copied at the moment it becomes current).
    (when (surface-pending-opaque-region-p surface)
      (setf (surface-opaque-region surface)
            (let ((region (surface-pending-opaque-region surface)))
              (and region (region-rectangles region)))
            (surface-pending-opaque-region-p surface) nil
            (surface-pending-opaque-region surface) nil))
    (when (surface-pending-input-region-p surface)
      (setf (surface-input-region surface)
            (let ((region (surface-pending-input-region surface)))
              (and region (region-rectangles region)))
            (surface-pending-input-region-p surface) nil
            (surface-pending-input-region surface) nil))
    (setf (surface-committed-callbacks surface)
          (append (surface-committed-callbacks surface)
                  (surface-pending-frame-callbacks surface)))
    (setf (surface-pending-frame-callbacks surface) nil)
    (setf (surface-committed-p surface) t)
    (log-message :debug "client ~D: surface ~D committed (mapped ~S, damage ~D)"
                 (client-id (resource-client surface))
                 (resource-id surface)
                 (surface-mapped-p surface)
                 (length damage))
    ;; The role's turn, before the compositor's: a configure has to be queued
    ;; before the render that might satisfy it.
    (when shell
      (surface-shell-committed shell surface damage))
    (surface-committed surface damage)
    surface))

(defmethod wl-surface.destroy ((surface surface))
  (destroy-resource surface))
