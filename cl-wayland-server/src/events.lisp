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

(defmethod xdg-popup.configure ((popup xdg-popup) x y width height)
  (send-event popup +xdg-popup-configure+ x y width height))

(defmethod xdg-popup.popup-done ((popup xdg-popup))
  (send-event popup +xdg-popup-popup-done+))

(defmethod xdg-wm-base.ping ((wm-base xdg-wm-base) serial)
  (send-event wm-base +xdg-wm-base-ping+ serial))

;;; ---------------------------------------------------------------------------
;;; wl_seat, wl_pointer, wl_keyboard, wl_touch (version 4, D27)
;;;
;;; Everything here is an event a *backend* causes by injecting input; the seat
;;; state machine (SEAT.LISP) decides who hears it.  Events newer than the
;;; resource's version are dropped by SEND-EVENT, so a v4 client never sees a
;;; v5 `frame` or a v10 `repeated` key even if a future injector asks for one.
;;; ---------------------------------------------------------------------------

(defmethod wl-seat.capabilities ((binding seat-resource) capabilities)
  (send-event binding +wl-seat-capabilities+ capabilities))

(defmethod wl-seat.name ((binding seat-resource) name)
  (send-event binding +wl-seat-name+ name))

(defmethod wl-pointer.enter ((pointer pointer) serial surface surface-x surface-y)
  (send-event pointer +wl-pointer-enter+ serial surface surface-x surface-y))

(defmethod wl-pointer.leave ((pointer pointer) serial surface)
  (send-event pointer +wl-pointer-leave+ serial surface))

(defmethod wl-pointer.motion ((pointer pointer) time surface-x surface-y)
  (send-event pointer +wl-pointer-motion+ time surface-x surface-y))

(defmethod wl-pointer.button ((pointer pointer) serial time button state)
  (send-event pointer +wl-pointer-button+ serial time button state))

(defmethod wl-pointer.axis ((pointer pointer) time axis value)
  (send-event pointer +wl-pointer-axis+ time axis value))

(defmethod wl-keyboard.keymap ((keyboard keyboard) format fd size)
  (send-event keyboard +wl-keyboard-keymap+ format fd size))

(defmethod wl-keyboard.enter ((keyboard keyboard) serial surface keys)
  (send-event keyboard +wl-keyboard-enter+ serial surface keys))

(defmethod wl-keyboard.leave ((keyboard keyboard) serial surface)
  (send-event keyboard +wl-keyboard-leave+ serial surface))

(defmethod wl-keyboard.key ((keyboard keyboard) serial time key state)
  (send-event keyboard +wl-keyboard-key+ serial time key state))

(defmethod wl-keyboard.modifiers ((keyboard keyboard) serial
                                  mods-depressed mods-latched mods-locked group)
  (send-event keyboard +wl-keyboard-modifiers+
              serial mods-depressed mods-latched mods-locked group))

(defmethod wl-keyboard.repeat-info ((keyboard keyboard) rate delay)
  (send-event keyboard +wl-keyboard-repeat-info+ rate delay))

(defmethod wl-touch.down ((touch touch) serial time surface id x y)
  (send-event touch +wl-touch-down+ serial time surface id x y))

(defmethod wl-touch.up ((touch touch) serial time id)
  (send-event touch +wl-touch-up+ serial time id))

(defmethod wl-touch.motion ((touch touch) time id x y)
  (send-event touch +wl-touch-motion+ time id x y))

(defmethod wl-touch.cancel ((touch touch))
  (send-event touch +wl-touch-cancel+))

;;; ---------------------------------------------------------------------------
;;; The data device (D64)
;;;
;;; Two of these events carry an object the *server* created -- data_offer and
;;; selection name a wl_data_offer the target never asked for by id -- which is
;;; why they are the first events here whose argument is a resource from the
;;; server's own id range (docs/protocol-layer.md §3).
;;; ---------------------------------------------------------------------------

(defmethod wl-data-source.target ((source data-source) mime-type)
  (send-event source +wl-data-source-target+ mime-type))

(defmethod wl-data-source.send ((source data-source) mime-type fd)
  (send-event source +wl-data-source-send+ mime-type fd))

(defmethod wl-data-source.cancelled ((source data-source))
  (send-event source +wl-data-source-cancelled+))

(defmethod wl-data-source.dnd-drop-performed ((source data-source))
  (send-event source +wl-data-source-dnd-drop-performed+))

(defmethod wl-data-source.dnd-finished ((source data-source))
  (send-event source +wl-data-source-dnd-finished+))

(defmethod wl-data-source.action ((source data-source) action)
  (send-event source +wl-data-source-action+ action))

(defmethod wl-data-device.data-offer ((device data-device) id)
  (send-event device +wl-data-device-data-offer+ id))

(defmethod wl-data-device.enter ((device data-device) serial surface x y id)
  (send-event device +wl-data-device-enter+ serial surface x y id))

(defmethod wl-data-device.leave ((device data-device))
  (send-event device +wl-data-device-leave+))

(defmethod wl-data-device.motion ((device data-device) time x y)
  (send-event device +wl-data-device-motion+ time x y))

(defmethod wl-data-device.drop ((device data-device))
  (send-event device +wl-data-device-drop+))

(defmethod wl-data-device.selection ((device data-device) id)
  (send-event device +wl-data-device-selection+ id))

(defmethod wl-data-offer.offer ((offer data-offer) mime-type)
  (send-event offer +wl-data-offer-offer+ mime-type))

(defmethod wl-data-offer.source-actions ((offer data-offer) actions)
  (send-event offer +wl-data-offer-source-actions+ actions))

(defmethod wl-data-offer.action ((offer data-offer) action)
  (send-event offer +wl-data-offer-action+ action))
