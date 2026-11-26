;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; xdg-shell on the client side: enough to be a toplevel in someone's session.
;;;;
;;;; The handshake is the server's rule seen from the other end
;;;; (cl-wayland-server/src/xdg-shell.lisp):
;;;;
;;;;   get_xdg_surface, get_toplevel, commit      -> configure(serial)
;;;;   ack_configure(serial), attach + commit     -> mapped
;;;;   ping(serial)                               -> pong(serial)
;;;;
;;;; The client does not pick its own size: it proposes one with a buffer, and the
;;;; compositor may answer with a configure asking for another.  This file sends what
;;;; the protocol requires; what to *do* about a configure is a policy question and
;;;; belongs to whoever owns the window (here, cf.backend.nested).
;;;;
;;;; ping is answered in this file rather than by every user: a client that ignores
;;;; ping is a client a compositor is entitled to kill as unresponsive, and there is
;;;; no useful policy to vary.

(in-package #:wayland.client)

(defclass xdg-wm-base (proxy) ()
  (:documentation "xdg_wm_base: the shell's entry point and its ping/pong timer."))

(defclass xdg-surface (proxy) ()
  (:documentation "xdg_surface: the role holder; configure serials are acked here."))

(defclass xdg-toplevel (proxy) ()
  (:documentation "xdg_toplevel: a window with a title, states and a close button."))

(register-proxy-class "xdg_wm_base" 'xdg-wm-base)
(register-proxy-class "xdg_surface" 'xdg-surface)
(register-proxy-class "xdg_toplevel" 'xdg-toplevel)

;;; ---------------------------------------------------------------------------
;;; The handshake
;;; ---------------------------------------------------------------------------
;;
;; xdg_wm_base: 0 destroy, 1 create_positioner, 2 get_xdg_surface, 3 pong.
;; xdg_surface: 0 destroy, 1 get_toplevel, 2 get_popup, 3 set_window_geometry,
;;              4 ack_configure.

(defmethod xdg-wm-base.get-xdg-surface ((base xdg-wm-base) surface)
  "Give SURFACE an xdg_surface.  The role (toplevel, popup) is assigned next."
  (check-live base)
  (let ((shell (allocate-child base "xdg_surface" :class 'xdg-surface)))
    (send-request base (interface-request (proxy-interface base) 2)
                  (proxy-id shell) surface)
    shell))

(defmethod xdg-wm-base.pong ((base xdg-wm-base) serial)
  "Answer a ping.  The last event of a compositor that thinks we are hung."
  (check-live base)
  (send-request base (interface-request (proxy-interface base) 3) serial))

(defmethod xdg-wm-base.destroy ((base xdg-wm-base))
  (check-live base)
  (send-request base (interface-request (proxy-interface base) 0)))

(defmethod xdg-surface.get-toplevel ((surface xdg-surface))
  "Assign the toplevel role.  Must happen before the next commit of the surface."
  (check-live surface)
  (let ((toplevel (allocate-child surface "xdg_toplevel" :class 'xdg-toplevel)))
    (send-request surface (interface-request (proxy-interface surface) 1)
                  (proxy-id toplevel))
    toplevel))

(defmethod xdg-surface.set-window-geometry ((surface xdg-surface) x y width height)
  "The visible bounds inside the surface, in surface-local coordinates."
  (check-live surface)
  (send-request surface (interface-request (proxy-interface surface) 3)
                x y width height))

(defmethod xdg-surface.ack-configure ((surface xdg-surface) serial)
  "Consume the configure with SERIAL; the next commit applies it."
  (check-live surface)
  (send-request surface (interface-request (proxy-interface surface) 4) serial))

(defmethod xdg-surface.destroy ((surface xdg-surface))
  (check-live surface)
  (send-request surface (interface-request (proxy-interface surface) 0)))

;;; ---------------------------------------------------------------------------
;;; The toplevel
;;; ---------------------------------------------------------------------------
;;
;; xdg_toplevel: 0 destroy, 1 set_parent, 2 set_title, 3 set_app_id.

(defmethod xdg-toplevel.set-title ((toplevel xdg-toplevel) title)
  (check-live toplevel)
  (send-request toplevel (interface-request (proxy-interface toplevel) 2) title))

(defmethod xdg-toplevel.set-app-id ((toplevel xdg-toplevel) app-id)
  "The desktop file name the shell matches this window against."
  (check-live toplevel)
  (send-request toplevel (interface-request (proxy-interface toplevel) 3) app-id))

(defmethod xdg-toplevel.destroy ((toplevel xdg-toplevel))
  (check-live toplevel)
  (send-request toplevel (interface-request (proxy-interface toplevel) 0)))

;;; ---------------------------------------------------------------------------
;;; Events the protocol says a client must answer
;;; ---------------------------------------------------------------------------

(defmethod xdg-wm-base.ping ((base xdg-wm-base) serial)
  "Answer the compositor's liveness check at once.

This runs from the client's event dispatch (display.lisp), and the pong is flushed
by the next FLUSH or ROUNDTRIP.  The nested backend dispatches and flushes in the
same cycle, so a ping is never left sitting in the out buffer."
  (xdg-wm-base.pong base serial))
