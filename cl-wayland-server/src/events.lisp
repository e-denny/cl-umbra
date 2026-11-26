;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Events: the server half of the generated event generic functions.
;;;;
;;;; On the client, an event generic function means "handle this message".  Here
;;;; it means "send it": the same generated function, the opposite direction
;;;; (docs/protocol-layer.md §4.3).  A compositor writes
;;;;
;;;;   (wl-output.mode output 1 1024 768 60000)
;;;;
;;;; and the schema decides the opcode, the argument encoding and whether the
;;;; bound resource's version is new enough to be told at all.

(in-package #:wayland.server)

;;; ---------------------------------------------------------------------------
;;; The one encoder
;;; ---------------------------------------------------------------------------

(defun send-event (resource opcode &rest arguments)
  "Queue event OPCODE on RESOURCE with ARGUMENTS.

Returns true if the event was queued, NIL if it was skipped because the bound
resource is older than the event's :since -- a v1 wl_output must never receive
wl_output.name, and the version check belongs here rather than in every
compositor call site.  Sending to a destroyed resource is also a no-op: the
object can be destroyed while an event about it is still being produced."
  (when (resource-destroyed-p resource)
    (return-from send-event nil))
  (let* ((interface (resource-interface resource))
         (event (event-at-opcode interface opcode)))
    (when (> (message-since event) (resource-version resource))
      (return-from send-event nil))
    (let* ((client (resource-client resource))
           (buffer (client-output client))
           (start (begin-message buffer (resource-id resource) (message-opcode event))))
      (loop for spec in (message-args event)
            for value in arguments
            do (encode-event-argument buffer spec value))
      (end-message buffer start))
    t))

(defun encode-event-argument (buffer spec value)
  "Write VALUE for SPEC.  The values come from us, so the checks are the ones
that catch *our* bugs: a wrong type is an error in this image, not in the wire."
  (ecase (arg-type spec)
    (:int (put-int buffer value))
    (:uint (put-uint buffer value))
    (:fixed (put-fixed buffer value))
    (:string (put-string buffer value))
    (:object (put-object buffer (resource-id-of value)))
    (:new-id (put-new-id buffer (resource-id-of value)))
    (:array (put-array buffer value))
    (:fd (put-fd buffer value))))

;;; ---------------------------------------------------------------------------
;;; wl_display
;;; ---------------------------------------------------------------------------

(defmethod wl-display.error ((display display-resource) object-id code message)
  (send-event display +wl-display-error+ object-id code message))

(defmethod wl-display.delete-id ((display display-resource) id)
  (send-event display +wl-display-delete-id+ id))

;;; ---------------------------------------------------------------------------
;;; wl_registry
;;; ---------------------------------------------------------------------------

(defmethod wl-registry.global ((registry registry) name interface version)
  (send-event registry +wl-registry-global+ name interface version))

(defmethod wl-registry.global-remove ((registry registry) name)
  (send-event registry +wl-registry-global-remove+ name))

;;; ---------------------------------------------------------------------------
;;; wl_callback
;;; ---------------------------------------------------------------------------

(defmethod wl-callback.done ((callback callback) callback-data)
  (send-event callback +wl-callback-done+ callback-data))

;;; ---------------------------------------------------------------------------
;;; wl_shm, wl_shm_pool, wl_buffer
;;; ---------------------------------------------------------------------------

(defmethod wl-shm.format ((shm shm) format)
  (send-event shm +wl-shm-format+ format))

;; wl_shm and wl_shm_pool have error *enums*, not events: their failures travel in
;; wl_display.error, with the interface's own code (see SHM.LISP's rejections).

(defmethod wl-buffer.release ((buffer shm-buffer))
  (send-event buffer +wl-buffer-release+))

;;; ---------------------------------------------------------------------------
;;; wl_surface
;;; ---------------------------------------------------------------------------

(defmethod wl-surface.enter ((surface surface) output)
  (send-event surface +wl-surface-enter+ output))

(defmethod wl-surface.leave ((surface surface) output)
  (send-event surface +wl-surface-leave+ output))

;;; ---------------------------------------------------------------------------
;;; wl_output
;;;;
;;;; Order is libwayland's and clients rely on it (docs/protocol-layer.md §8):
;;;; geometry, mode, scale, then name and description, with done strictly last.
;;; ---------------------------------------------------------------------------

(defmethod wl-output.geometry ((output output)
                               x y physical-width physical-height
                               subpixel make model transform)
  (send-event output +wl-output-geometry+
              x y physical-width physical-height subpixel make model transform))

(defmethod wl-output.mode ((output output) flags width height refresh)
  (send-event output +wl-output-mode+ flags width height refresh))

(defmethod wl-output.done ((output output))
  (send-event output +wl-output-done+))

(defmethod wl-output.scale ((output output) factor)
  (send-event output +wl-output-scale+ factor))

(defmethod wl-output.name ((output output) name)
  (send-event output +wl-output-name+ name))

(defmethod wl-output.description ((output output) description)
  (send-event output +wl-output-description+ description))

;;; ---------------------------------------------------------------------------
;;; xdg-shell
;;;
;;; Two events and a ping.  xdg_toplevel.configure's state list travels as an
;;; :array of little-endian u32s; SEND-CONFIGURE (XDG-SHELL.LISP) builds it, and
;;; an empty list is encoded as a zero-length array, which is not the same thing
;;; as "no configure" and must not be omitted.
;;; ---------------------------------------------------------------------------

(defmethod xdg-surface.configure ((shell xdg-surface) serial)
  (send-event shell +xdg-surface-configure+ serial))

(defmethod xdg-toplevel.configure ((toplevel xdg-toplevel) width height states)
  (send-event toplevel +xdg-toplevel-configure+ width height states))

(defmethod xdg-toplevel.close ((toplevel xdg-toplevel))
  (send-event toplevel +xdg-toplevel-close+))

(defmethod xdg-wm-base.ping ((wm-base xdg-wm-base) serial)
  (send-event wm-base +xdg-wm-base-ping+ serial))
