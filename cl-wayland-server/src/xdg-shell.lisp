;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; xdg-shell, version 1: xdg_wm_base, xdg_surface and xdg_toplevel.
;;;;
;;;; This is the state machine a real client needs to put a window on screen, and
;;;; no more (docs/framework.md §6).  The handshake it implements:
;;;;
;;;;   get_xdg_surface -> get_toplevel -> set_title -> commit (no buffer)
;;;;     -> xdg_toplevel.configure(0x0, []) + xdg_surface.configure(serial)
;;;;     -> ack_configure(serial)
;;;;     -> attach(buffer) + commit   ... mapped, rendered, frame callbacks fire
;;;;
;;;; The rules that make it a state machine rather than a set of no-ops:
;;;;
;;;;   * a buffer attached before the first configure is acked is
;;;;     UNCONFIGURED_BUFFER, not a guess about what the client meant;
;;;;   * an ack for a serial we never sent, or for one already consumed, is
;;;;     INVALID_SERIAL -- PENDING-SERIALS is the memory that makes it detectable;
;;;;   * a second role on one wl_surface is ALREADY_CONSTRUCTED, a role on a
;;;;     committed surface is ROLE (xdg_wm_base's error, which is why that code
;;;;     lives on the wm_base object and not on the surface);
;;;;   * destroying an xdg_surface while its role lives is DEFUNCT_ROLE_OBJECT,
;;;;     and destroying the wm_base while surfaces live is DEFUNCT_SURFACES;
;;;;   * the initial configure carries 0x0 and an empty state array: "you choose,
;;;;     nothing special about you" (docs/protocol-layer.md §8).
;;;;
;;;; Deliberately absent, and a missing method is how the dispatch layer says so
;;;; (it becomes wl_display.error implementation, "not built yet"): popups
;;;; (xdg_surface.get_popup), positioners (xdg_wm_base.create_positioner) and
;;;; decoration negotiation.  A compositor that advertises xdg_wm_base v1 and
;;;; refuses the v1 requests it cannot honour is honest; advertising v4 and
;;;; staying silent about configure_bounds would not be.

(in-package #:wayland.server)

;;; ---------------------------------------------------------------------------
;;; Small shared pieces
;;; ---------------------------------------------------------------------------

(defun resource-display (resource)
  "The DISPLAY a resource belongs to (resources are per client, the display is not)."
  (client-display (resource-client resource)))

(defun shell-alive-p (shell)
  "SHELL can still be spoken to: it exists, and its wl_surface does."
  (and (not (resource-destroyed-p shell))
       (xdg-surface-live-p shell)))

(defun encode-u32-array (values)
  "VALUES as the octet vector an :array argument carries: little-endian u32s.

A zero-length array is NIL, which is how the wire spells it and what
xdg_toplevel.configure's empty state list must look like."
  (when values
    (let ((octets (make-array (* 4 (length values))
                              :element-type '(unsigned-byte 8))))
      (loop for value in values
            for index from 0
            do (setf (aref octets (* 4 index)) (ldb (byte 8 0) value)
                     (aref octets (+ (* 4 index) 1)) (ldb (byte 8 8) value)
                     (aref octets (+ (* 4 index) 2)) (ldb (byte 8 16) value)
                     (aref octets (+ (* 4 index) 3)) (ldb (byte 8 24) value)))
      octets)))

;;; ---------------------------------------------------------------------------
;;; Destroying
;;;
;;; Each object unlinks itself from the two objects that point at it, so a
;;; resource can never be reachable after its id is gone.
;;; ---------------------------------------------------------------------------

(defun destroy-xdg-surface (shell)
  "SHELL's id is gone: unlink it from its surface and from the wm_base."
  (let ((surface (xdg-surface-surface shell)))
    (when (and surface
               (not (resource-destroyed-p surface))
               (eq (surface-shell-surface surface) shell))
      (setf (surface-shell-surface surface) nil)))
  (let ((wm-base (xdg-surface-wm-base shell)))
    (when wm-base
      (setf (xdg-wm-base-shell-surfaces wm-base)
            (remove shell (xdg-wm-base-shell-surfaces wm-base)))))
  (setf (xdg-surface-live-p shell) nil
        (xdg-surface-role shell) nil
        (xdg-surface-surface shell) nil
        (xdg-surface-pending-serials shell) nil))

(defun destroy-xdg-toplevel (toplevel)
  "The role object is gone; the surface is unmapped and waits for a new role."
  (let ((shell (xdg-toplevel-shell-surface toplevel)))
    (when (and shell (not (resource-destroyed-p shell)))
      (let ((surface (xdg-surface-surface shell)))
        (when (and surface (not (resource-destroyed-p surface)))
          ;; Unmapping is a state change, not a request: per the spec the
          ;; toplevel returns to the state right after get_toplevel, so the next
          ;; buffer needs a fresh initial commit and configure.
          (setf (surface-mapped-p surface) nil))
        (setf (xdg-surface-role shell) nil
              (xdg-surface-role-name shell) nil
              (xdg-surface-configured-p shell) nil
              (xdg-surface-acknowledged-p shell) nil
              (xdg-surface-configure-serial shell) nil
              (xdg-surface-pending-serials shell) nil
              (xdg-surface-mapped-p shell) nil)))))

;;; ---------------------------------------------------------------------------
;;; Configuring
;;; ---------------------------------------------------------------------------

(defun send-configure (shell &key (width 0) (height 0) (states nil))
  "Send the role's configure (if any) and then xdg_surface.configure.

The serial is consumed by the client's ACK-CONFIGURE and is what makes a stale
ack detectable, so it comes from the display and is recorded before the events
leave this function.  Returns the serial, or NIL when the shell is gone."
  (unless (shell-alive-p shell)
    (return-from send-configure nil))
  (let* ((client (resource-client shell))
         (serial (display-next-serial (resource-display shell)))
         (toplevel (xdg-surface-role shell)))
    (when (and toplevel (not (resource-destroyed-p toplevel)))
      (xdg-toplevel.configure toplevel width height (encode-u32-array states))
      (setf (xdg-toplevel-configure-count toplevel)
            (1+ (xdg-toplevel-configure-count toplevel))
            (xdg-toplevel-configure-width toplevel) width
            (xdg-toplevel-configure-height toplevel) height
            (xdg-toplevel-configure-states toplevel) (copy-list states)))
    (xdg-surface.configure shell serial)
    (setf (xdg-surface-configure-serial shell) serial
          (xdg-surface-configured-p shell) t
          (xdg-surface-pending-serials shell)
          (cons serial (xdg-surface-pending-serials shell)))
    (log-message :debug "client ~D: configured ~A ~D as ~Dx~D states ~S (serial ~D)"
                 (client-id client)
                 (or (xdg-surface-role-name shell) "surface")
                 (resource-id shell) width height states serial)
    serial))

;;; ---------------------------------------------------------------------------
;;; wl_surface role hooks
;;; ---------------------------------------------------------------------------

(defmethod surface-shell-check-commit ((shell xdg-surface) surface)
  "Refuse a buffer attached before the initial configure was acked.

This is the rule that makes the handshake mean something: without it a client can
attach and commit at any time, and the configure/ack exchange is decoration.  An
attach of NIL (unmap) is always legal."
  (when (and (xdg-surface-live-p shell)
             (not (xdg-surface-acknowledged-p shell))
             (surface-pending-attach-p surface)
             (surface-pending-buffer surface))
    (protocol-error (resource-client shell) (resource-id shell)
                    +xdg-surface-error-unconfigured-buffer+
                    "a buffer was attached before the initial configure was acked")))

(defmethod surface-shell-committed ((shell xdg-surface) surface damage)
  "The client committed.  On the first commit: answer with the initial configure.

On a later commit: notice the toplevel appearing and disappearing, which is what a
compositor's map/unmap policy will hang off in phase 3 (cf.types.xdg-shell)."
  (declare (ignore damage))
  (unless (xdg-surface-live-p shell)
    (return-from surface-shell-committed nil))
  (cond
    ((not (xdg-surface-configured-p shell))
     ;; The initial commit is the client saying "I am ready to be told a size".
     ;; Nothing may be attached yet (CHECK-COMMIT has already refused it), so
     ;; there is nothing to draw and no state to compute.
     (send-configure shell))
    (t
     (let ((mapped (and (surface-mapped-p surface) t))
           (toplevel (xdg-surface-role shell)))
       (unless (eq mapped (xdg-surface-mapped-p shell))
         (setf (xdg-surface-mapped-p shell) mapped)
         (when toplevel
           (setf (xdg-toplevel-mapped-p toplevel) mapped))
         (log-message :info "client ~D: toplevel ~D ~:[unmapped~;mapped~]~@[ (title ~S)~]"
                      (client-id (resource-client shell))
                      (if toplevel (resource-id toplevel) (resource-id shell))
                      mapped
                      (and toplevel (xdg-toplevel-title toplevel)))))))
  nil)

(defmethod surface-shell-lost ((shell xdg-surface) surface)
  "The wl_surface died under this role.  Stop pointing at it, keep the id honest."
  (declare (ignore surface))
  (setf (xdg-surface-live-p shell) nil
        (xdg-surface-surface shell) nil
        (xdg-surface-role shell) nil
        (xdg-surface-pending-serials shell) nil)
  nil)

;;; ---------------------------------------------------------------------------
;;; xdg_wm_base
;;; ---------------------------------------------------------------------------

(defmethod xdg-wm-base.destroy ((wm-base xdg-wm-base))
  "Destroying the global with live surfaces is defunct_surfaces, per the spec."
  (let ((live (remove-if #'resource-destroyed-p
                         (xdg-wm-base-shell-surfaces wm-base))))
    (when live
      (protocol-error (resource-client wm-base) (resource-id wm-base)
                      +xdg-wm-base-error-defunct-surfaces+
                      "~D xdg_surface~:P still alive: ~{~D~^, ~}"
                      (length live) (mapcar #'resource-id live))))
  (destroy-resource wm-base))

(defmethod xdg-wm-base.get-xdg-surface ((wm-base xdg-wm-base) surface)
  "Create the xdg_surface for SURFACE; the role comes next."
  (let ((client (resource-client wm-base)))
    (cond
      ((surface-shell-surface surface)
       (protocol-error client (resource-id wm-base) +xdg-wm-base-error-role+
                       "wl_surface ~D already has the ~(~A~) role (xdg_surface ~D)"
                       (resource-id surface)
                       (xdg-surface-role-name (surface-shell-surface surface))
                       (resource-id (surface-shell-surface surface))))
      ((or (surface-committed-p surface) (surface-current-buffer surface))
       (protocol-error client (resource-id wm-base) +xdg-wm-base-error-role+
                       "wl_surface ~D was already committed; an xdg_surface must be \
created before the surface is used"
                       (resource-id surface))))
    (let ((shell (allocate-resource client
                                    (resolve-interface "xdg_surface")
                                    :version (resource-version wm-base)
                                    :class 'xdg-surface
                                    :destroy-function #'destroy-xdg-surface)))
      (setf (xdg-surface-surface shell) surface
            (xdg-surface-wm-base shell) wm-base
            (surface-shell-surface surface) shell)
      (push shell (xdg-wm-base-shell-surfaces wm-base))
      (log-message :debug "client ~D: xdg_surface ~D for wl_surface ~D"
                   (client-id client) (resource-id shell) (resource-id surface))
      shell)))

(defmethod xdg-wm-base.pong ((wm-base xdg-wm-base) serial)
  "A client answered a ping.  Unknown serials are ignored, as the spec says."
  (let ((known (member serial (xdg-wm-base-pending-pings wm-base))))
    (if known
        (progn
          (setf (xdg-wm-base-pending-pings wm-base)
                (remove serial (xdg-wm-base-pending-pings wm-base)))
          (incf (xdg-wm-base-pong-count wm-base))
          (log-message :debug "client ~D: pong ~D" (client-id (resource-client wm-base))
                       serial))
        (log-message :debug "client ~D: pong ~D does not answer a pending ping"
                     (client-id (resource-client wm-base)) serial)))
  nil)

(defun ping-xdg-wm-base (wm-base)
  "Send xdg_wm_base.ping and remember the serial; returns it.

Nothing pings on its own yet -- a compositor pings a client it suspects has
stopped reading, and that policy arrives with the watchdog.  Making the round
trip real now means the gate can prove the client hears us and we hear it back."
  (let ((serial (display-next-serial (resource-display wm-base))))
    (xdg-wm-base.ping wm-base serial)
    (setf (xdg-wm-base-pending-pings wm-base)
          (cons serial (xdg-wm-base-pending-pings wm-base)))
    (incf (xdg-wm-base-ping-count wm-base))
    (log-message :debug "client ~D: ping ~D"
                 (client-id (resource-client wm-base)) serial)
    serial))

;;; xdg_wm_base.create_positioner is not implemented on purpose: popups are a
;;; later slice, and a positioner that positions nothing would be a lie.  The
;;; dispatch layer turns the missing method into an implementation error.

;;; ---------------------------------------------------------------------------
;;; xdg_surface
;;; ---------------------------------------------------------------------------

(defmethod xdg-surface.destroy ((shell xdg-surface))
  "An xdg_surface outlives its role object only by accident: refuse it."
  (let ((role (xdg-surface-role shell)))
    (when (and role (not (resource-destroyed-p role)))
      (protocol-error (resource-client shell) (resource-id shell)
                      +xdg-surface-error-defunct-role-object+
                      "the ~(~A~) role object ~D outlives its xdg_surface"
                      (xdg-surface-role-name shell) (resource-id role))))
  (destroy-resource shell))

(defmethod xdg-surface.get-toplevel ((shell xdg-surface))
  "Give SURFACE the toplevel role; the surface is still unmapped."
  (let ((client (resource-client shell)))
    (unless (xdg-surface-live-p shell)
      (protocol-error client (resource-id shell) +xdg-surface-error-not-constructed+
                      "this xdg_surface lost its wl_surface"))
    (when (xdg-surface-role shell)
      (protocol-error client (resource-id shell)
                      +xdg-surface-error-already-constructed+
                      "this xdg_surface already has the ~(~A~) role"
                      (xdg-surface-role-name shell)))
    (let ((toplevel (allocate-resource client
                                       (resolve-interface "xdg_toplevel")
                                       :version (resource-version shell)
                                       :class 'xdg-toplevel
                                       :destroy-function #'destroy-xdg-toplevel)))
      (setf (xdg-toplevel-shell-surface toplevel) shell
            (xdg-surface-role shell) toplevel
            (xdg-surface-role-name shell) :toplevel)
      (log-message :debug "client ~D: xdg_toplevel ~D for xdg_surface ~D"
                   (client-id client) (resource-id toplevel) (resource-id shell))
      toplevel)))

;; xdg_surface.get_popup has no method: no popups in this slice (see the header).

(defmethod xdg-surface.set-window-geometry ((shell xdg-surface) x y width height)
  "Remember the visible bounds.  Zero or negative is invalid_size, per the spec."
  (unless (xdg-surface-role shell)
    (protocol-error (resource-client shell) (resource-id shell)
                    +xdg-surface-error-not-constructed+
                    "set_window_geometry before assigning a role"))
  (when (or (<= width 0) (<= height 0))
    (protocol-error (resource-client shell) (resource-id shell)
                    +xdg-surface-error-invalid-size+
                    "window geometry ~Dx~D is not positive" width height))
  ;; Double-buffered in the protocol; stored at once here because nothing reads
  ;; it yet: the scene graph and a window manager will, and then this moves into
  ;; the surface's pending state like every other commit-time attribute.
  (setf (xdg-surface-window-geometry shell) (list x y width height))
  nil)

(defmethod xdg-surface.ack-configure ((shell xdg-surface) serial)
  "Consume SERIAL and every configure sent before it.

A serial we never sent, or one already consumed, is INVALID_SERIAL.  Consuming
the older serials too is what the spec asks for and what stops a client from
acking the oldest configure in a burst and pretending it applied the newest."
  (let ((client (resource-client shell)))
    (unless (xdg-surface-role shell)
      (protocol-error client (resource-id shell)
                      +xdg-surface-error-not-constructed+
                      "ack_configure before assigning a role"))
    (let* ((pending (xdg-surface-pending-serials shell))
           (tail (member serial pending)))
      (unless tail
        (protocol-error client (resource-id shell)
                        +xdg-surface-error-invalid-serial+
                        "serial ~D was never sent by this xdg_surface, or was \
already acknowledged (pending: ~S)"
                        serial pending))
      (setf (xdg-surface-pending-serials shell) (ldiff pending tail)
            (xdg-surface-last-acked-serial shell) serial
            (xdg-surface-acknowledged-p shell) t)
      (incf (xdg-surface-ack-count shell))
      (log-message :debug "client ~D: ack_configure ~D on xdg_surface ~D"
                   (client-id client) serial (resource-id shell))
      nil)))

;;; ---------------------------------------------------------------------------
;;; xdg_toplevel
;;; ---------------------------------------------------------------------------

(defmethod xdg-toplevel.destroy ((toplevel xdg-toplevel))
  (destroy-resource toplevel))

(defmethod xdg-toplevel.set-parent ((toplevel xdg-toplevel) parent)
  (when (eq parent toplevel)
    (protocol-error (resource-client toplevel) (resource-id toplevel)
                    +xdg-toplevel-error-invalid-parent+
                    "a toplevel cannot be its own parent"))
  (setf (xdg-toplevel-parent toplevel) parent)
  nil)

(defmethod xdg-toplevel.set-title ((toplevel xdg-toplevel) title)
  (setf (xdg-toplevel-title toplevel) title)
  nil)

(defmethod xdg-toplevel.set-app-id ((toplevel xdg-toplevel) app-id)
  (setf (xdg-toplevel-app-id toplevel) app-id)
  nil)

;; Interactive move/resize and the window menu need a seat, a pointer and a
;; serial vocabulary that only exists while a grab is active.  They are accepted
;; and logged; nothing acts on them until this compositor has a seat, which is the
;; next slice of this phase.

(defmethod xdg-toplevel.show-window-menu ((toplevel xdg-toplevel) seat serial x y)
  (declare (ignore seat x y))
  (log-message :debug "toplevel ~D: show_window_menu (serial ~D) ignored: no seat"
               (resource-id toplevel) serial)
  nil)

(defmethod xdg-toplevel.move ((toplevel xdg-toplevel) seat serial)
  (declare (ignore seat))
  (log-message :debug "toplevel ~D: move (serial ~D) ignored: no seat"
               (resource-id toplevel) serial)
  nil)

(defmethod xdg-toplevel.resize ((toplevel xdg-toplevel) seat serial edges)
  (declare (ignore seat))
  (unless (member edges '(0 1 2 4 5 6 8 9 10))
    (protocol-error (resource-client toplevel) (resource-id toplevel)
                    +xdg-toplevel-error-invalid-resize-edge+
                    "resize edge ~D is not a variant of the enum" edges))
  (log-message :debug "toplevel ~D: resize (serial ~D, edges ~D) ignored: no seat"
               (resource-id toplevel) serial edges)
  nil)

(defun check-size-hint (toplevel width height what)
  (when (or (minusp width) (minusp height))
    (protocol-error (resource-client toplevel) (resource-id toplevel)
                    +xdg-toplevel-error-invalid-size+
                    "~A size ~Dx~D is negative" what width height)))

(defmethod xdg-toplevel.set-max-size ((toplevel xdg-toplevel) width height)
  (check-size-hint toplevel width height "maximum")
  (setf (xdg-toplevel-max-width toplevel) width
        (xdg-toplevel-max-height toplevel) height)
  nil)

(defmethod xdg-toplevel.set-min-size ((toplevel xdg-toplevel) width height)
  (check-size-hint toplevel width height "minimum")
  (setf (xdg-toplevel-min-width toplevel) width
        (xdg-toplevel-min-height toplevel) height)
  nil)

;; Maximised/fullscreen/minimised are requests, not commands: the compositor
;; decides, and it has no output layout or activation policy yet.  Recording the
;; request without acting on it is the honest phase-3 answer; the configures the
;; compositor *does* send still carry a complete, empty state array.

(defmethod xdg-toplevel.set-maximized ((toplevel xdg-toplevel))
  (log-message :debug "toplevel ~D: set_maximized ignored: no layout yet"
               (resource-id toplevel))
  nil)

(defmethod xdg-toplevel.unset-maximized ((toplevel xdg-toplevel))
  (log-message :debug "toplevel ~D: unset_maximized ignored: no layout yet"
               (resource-id toplevel))
  nil)

(defmethod xdg-toplevel.set-fullscreen ((toplevel xdg-toplevel) output)
  (declare (ignore output))
  (log-message :debug "toplevel ~D: set_fullscreen ignored: no layout yet"
               (resource-id toplevel))
  nil)

(defmethod xdg-toplevel.unset-fullscreen ((toplevel xdg-toplevel))
  (log-message :debug "toplevel ~D: unset_fullscreen ignored: no layout yet"
               (resource-id toplevel))
  nil)

(defmethod xdg-toplevel.set-minimized ((toplevel xdg-toplevel))
  (log-message :debug "toplevel ~D: set_minimized ignored: no activation policy"
               (resource-id toplevel))
  nil)

;;; ---------------------------------------------------------------------------
;;; Compositor policy hooks (what a scene graph and a window manager call)
;;; ---------------------------------------------------------------------------

(defun close-toplevel (toplevel)
  "Ask the client to close the window (xdg_toplevel.close).  The client may refuse."
  (unless (xdg-toplevel-closed-p toplevel)
    (setf (xdg-toplevel-closed-p toplevel) t)
    (xdg-toplevel.close toplevel)
    t))

(defun set-toplevel-activated (toplevel activated)
  "Send a new configure whose state array says whether the window is focused.

ACTIVATED is the only state this compositor can justify today: it has no layout,
so it cannot claim tiled, maximised or fullscreen.  The array is complete on every
send, never patched (docs/framework.md §6)."
  (let ((shell (xdg-toplevel-shell-surface toplevel)))
    (when (and shell (shell-alive-p shell))
      (send-configure shell
                      :width (xdg-toplevel-configure-width toplevel)
                      :height (xdg-toplevel-configure-height toplevel)
                      :states (if activated (list +xdg-toplevel-state-activated+) nil)))))
