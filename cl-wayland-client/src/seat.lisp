;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; wl_seat on the client side: the three device objects and their lifetimes.
;;;;
;;;; A seat announces capabilities; a client that wants a pointer calls get_pointer
;;;; and then listens for enter/motion/button on the object it got back.  The
;;;; events themselves need no methods here -- they arrive as hooks or as methods on
;;;; the generated event generic functions (docs/protocol-layer.md §6) -- so this
;;;; file is only the factories and the rule that a device speaks the seat's
;;;; version.
;;;;
;;;; Devices are not destroyed when the capability goes away: wl_pointer.release and
;;;; wl_keyboard.release destroy the object, and the client must then forget it.  A
;;;; compositor that takes a capability away sends the reduced capability mask; the
;;;; client releases the object itself.  That rule lives in its users, not here,
;;;; because "release the pointer" is a decision about state the client owns.

(in-package #:wayland.client)

(defclass seat (proxy) ()
  (:documentation "wl_seat: capabilities, a name, and pointers/keyboards/touches."))

(defclass pointer (proxy) ()
  (:documentation "wl_pointer: enter, leave, motion, button, axis events."))

(defclass keyboard (proxy) ()
  (:documentation "wl_keyboard: a keymap descriptor, then keys and modifiers."))

(defclass touch (proxy) ()
  (:documentation "wl_touch: down, up, motion, frame, cancel."))

(register-proxy-class "wl_seat" 'seat)
(register-proxy-class "wl_pointer" 'pointer)
(register-proxy-class "wl_keyboard" 'keyboard)
(register-proxy-class "wl_touch" 'touch)

;;; ---------------------------------------------------------------------------
;;; Factories
;;; ---------------------------------------------------------------------------
;;
;; The opcode is written as a number on purpose: it is what the XML says, it is
;; stable, and a reader can check it against protocols/wayland.xml without
;; following a chain of constants.  wl_seat: 0 get_pointer, 1 get_keyboard,
;; 2 get_touch, 3 release.

(defmethod wl-seat.get-pointer ((seat seat))
  "Create the seat's wl_pointer."
  (check-live seat)
  (let ((pointer (allocate-child seat "wl_pointer" :class 'pointer)))
    (send-request seat (interface-request (proxy-interface seat) 0)
                  (proxy-id pointer))
    pointer))

(defmethod wl-seat.get-keyboard ((seat seat))
  "Create the seat's wl_keyboard.  The keymap arrives as an event, fd and all."
  (check-live seat)
  (let ((keyboard (allocate-child seat "wl_keyboard" :class 'keyboard)))
    (send-request seat (interface-request (proxy-interface seat) 1)
                  (proxy-id keyboard))
    keyboard))

(defmethod wl-seat.get-touch ((seat seat))
  "Create the seat's wl_touch."
  (check-live seat)
  (let ((touch (allocate-child seat "wl_touch" :class 'touch)))
    (send-request seat (interface-request (proxy-interface seat) 2)
                  (proxy-id touch))
    touch))

(defmethod wl-seat.release ((seat seat))
  "Destroy the seat object (the compositor keeps the input devices alive)."
  (check-live seat)
  (send-request seat (interface-request (proxy-interface seat) 3)))

(defmethod wl-pointer.release ((pointer pointer))
  (check-live pointer)
  (send-request pointer (interface-request (proxy-interface pointer) 1)))

(defmethod wl-keyboard.release ((keyboard keyboard))
  ;; wl_keyboard.release is opcode 0: the interface had no other request.
  (check-live keyboard)
  (send-request keyboard (interface-request (proxy-interface keyboard) 0)))

(defmethod wl-touch.release ((touch touch))
  (check-live touch)
  (send-request touch (interface-request (proxy-interface touch) 0)))

;;; ---------------------------------------------------------------------------
;;; A cursor image is a surface plus a hotspot
;;; ---------------------------------------------------------------------------
;;
;; wl_pointer.set_cursor is (serial, surface, hotspot-x, hotspot-y); the serial
;; must be one from a recent enter event, which is why it is an argument rather
;; than remembered here.

(defmethod wl-pointer.set-cursor ((pointer pointer) serial surface hotspot-x hotspot-y)
  "Set the pointer's image; NIL hides the cursor."
  (check-live pointer)
  (send-request pointer (interface-request (proxy-interface pointer) 0)
                serial surface hotspot-x hotspot-y))
