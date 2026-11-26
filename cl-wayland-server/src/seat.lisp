;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; wl_seat version 4, with wl_pointer, wl_keyboard and wl_touch
;;;; (docs/framework.md §5).
;;;;
;;;; Version 4 is a deliberate ceiling (D27): it is the newest version whose
;;;; every request and event this slice can honour.  v5 adds wl_pointer.frame and
;;;; wl_seat.release, v6 adds axis_source/wheel-tilt, v7+ adds high-resolution
;;;; scroll and keyboard v10's "repeated" state -- advertising them would mean
;;;; promising events we never send.  The version gate in SEND-EVENT is what makes
;;;; that promise checkable rather than aspirational.
;;;;
;;;; The shape of the file follows the protocol:
;;;;
;;;;   the seat     capabilities, name, keymap, focus, and the four injectors a
;;;;                backend calls (key, pointer motion/button/axis)
;;;;   wl_seat      get_pointer / get_keyboard / get_touch, and the initial events
;;;;   wl_pointer   set_cursor (recorded, not drawn: no software cursor yet)
;;;;   wl_keyboard  keymap fd + repeat_info, enter/leave/key/modifiers
;;;;   wl_touch     created and released; nothing injects it
;;;;
;;;; Input policy is elsewhere on purpose: which surface is focused, what a key
;;;; means, and whether a click starts a grab are the compositor's business.  The
;;;; seat only guarantees that what the backend says happened reaches exactly the
;;;; client that has focus, in the order the protocol requires.

(in-package #:wayland.server)

(defconstant +seat-version+ 4
  "The newest wl_seat whose every request and event this slice implements (D27).

A wl_pointer, wl_keyboard or wl_touch created from a v4 seat is v4 too: the
client asks for the version its seat has, and version 4 is the last one without
wl_pointer.frame or wl_seat.release.")

;;; ---------------------------------------------------------------------------
;;; Creating a seat
;;; ---------------------------------------------------------------------------

(defun make-seat (display &key (name "seat0") (capabilities 0))
  "A seat for DISPLAY with no keymap yet; ADD-SEAT-GLOBAL publishes it."
  (make-instance 'seat :display display :name name :capabilities capabilities))

(defun add-seat-global (display seat &key (version +seat-version+))
  "Register SEAT as a global; returns the GLOBAL.

The bind function is where a client's wl_seat learns which seat it is: the
initial events (name, then capabilities) go out in BIND-SEAT-RESOURCE."
  (add-global display
              :interface "wl_seat"
              :version version
              :resource-class 'seat-resource
              :data seat
              :bind (lambda (resource) (bind-seat-resource seat resource))))

(defun bind-seat-resource (seat resource)
  "Send the seat's initial events, in the order clients expect (name, caps)."
  (setf (seat-resource-seat resource) seat)
  (push resource (seat-bindings seat))
  (wl-seat.name resource (seat-name seat))
  (wl-seat.capabilities resource (seat-capabilities seat))
  (log-message :debug "client ~D: bound seat ~A (capabilities ~D)"
               (client-id (resource-client resource)) (seat-name seat)
               (seat-capabilities seat))
  resource)

(defun seat-bindings-of (seat client)
  "The client's wl_seat resources, or NIL if it never bound the seat."
  (remove-if-not (lambda (binding) (eq (resource-client binding) client))
                 (seat-bindings seat)))

(defun seat-client-resources (seat client accessor)
  "Every POINTER/KEYBOARD/TOUCH of CLIENT on SEAT, from its bindings."
  (loop for binding in (seat-bindings-of seat client)
        append (funcall accessor binding)))

(defun seat-capabilities-changed (seat)
  "Re-advertise what the seat can do.  Called when a device appears or goes."
  (dolist (binding (seat-bindings seat))
    (unless (resource-destroyed-p binding)
      (wl-seat.capabilities binding (seat-capabilities seat))))
  (seat-capabilities seat))

(defun set-seat-capabilities (seat capabilities)
  (setf (seat-capabilities seat) capabilities)
  (seat-capabilities-changed seat))

;;; ---------------------------------------------------------------------------
;;; The keymap
;;; ---------------------------------------------------------------------------

(defun keymap-memfd (text)
  "TEXT in a sealed-away memfd, NUL-terminated as the XKB format requires.

wl_keyboard.keymap's payload is a null-terminated string, and the size includes
the terminator -- a client that maps only `size` octets and passes them to
xkb_keymap_new_from_string must find its terminator inside the mapping."
  (let* ((octets (sb-ext:string-to-octets text :external-format :utf-8))
         (size (1+ (length octets)))
         (fd (wayland.ffi:memfd-create "cl-wayland-keymap")))
    (wayland.ffi:set-file-size fd size)
    (let ((mapping (wayland.ffi:map-file
                    fd size
                    :protection (logior wayland.ffi:+prot-read+
                                        wayland.ffi:+prot-write+))))
      (unwind-protect
           (progn
             (wayland.ffi:write-mapped-octets mapping 0 octets)
             ;; The terminator: a fresh memfd is zero-filled, but saying so costs
             ;; one octet and removes the doubt.
             (wayland.ffi:write-mapped-octets mapping (length octets)
                                              (make-array 1 :element-type '(unsigned-byte 8)
                                                            :initial-element 0)))
        (wayland.ffi:unmap-file mapping size)))
    (values fd size)))

(defun send-keymap (keyboard)
  "Send wl_keyboard.keymap (with the descriptor) and then repeat_info.

The descriptor is created here, queued on the client's out buffer, and closed by
FLUSH-CLIENT once it has travelled: SCM_RIGHTS duplicates it into the client, and
our copy is ours no more (docs/protocol-layer.md §2)."
  (let* ((seat (keyboard-seat keyboard))
         (text (seat-keymap seat)))
    (when text
      (multiple-value-bind (fd size) (keymap-memfd text)
        (wl-keyboard.keymap keyboard +wl-keyboard-keymap-format-xkb-v1+ fd size)))
    ;; repeat_info is since 4 and the seat advertises exactly 4, so a keyboard
    ;; that heard the keymap hears the repeat settings too -- before any key.
    (when (>= (resource-version keyboard) 4)
      (wl-keyboard.repeat-info keyboard (seat-repeat-rate seat) (seat-repeat-delay seat)))
    keyboard))

(defun set-seat-keymap (seat text &key repeat-rate repeat-delay)
  "Give every keyboard on SEAT keymap TEXT, then the new repeat settings."
  (setf (seat-keymap seat) text)
  (when repeat-rate (setf (seat-repeat-rate seat) repeat-rate))
  (when repeat-delay (setf (seat-repeat-delay seat) repeat-delay))
  (dolist (binding (seat-bindings seat))
    (dolist (keyboard (seat-resource-keyboards binding))
      (send-keymap keyboard)))
  text)

;;; ---------------------------------------------------------------------------
;;; Focus
;;; ---------------------------------------------------------------------------

(defgeneric seat-focus-changed (seat surface has-focus)
  (:documentation
   "SURFACE gained (HAS-FOCUS true) or lost keyboard focus.

The default does nothing: a transport-only server has no policy.  A compositor
specialises this to send `xdg_toplevel.configure` with the activated state, which
is the only way a client learns it is focused (docs/framework.md §5).")
  (:method (seat surface has-focus)
    (declare (ignore seat surface has-focus))
    nil))

(defun seat-keyboard-for-client (seat client)
  "The keyboards CLIENT has on SEAT; each one gets its own enter/leave."
  (seat-client-resources seat client #'seat-resource-keyboards))

(defun seat-pointer-for-client (seat client)
  (seat-client-resources seat client #'seat-resource-pointers))

(defun send-keyboard-enter (keyboard surface serial)
  "(Re)send wl_keyboard.enter, then modifiers, then the keys already down.

The order is the protocol's: enter, then modifiers, then nothing else until a key
arrives.  A client that gains focus while a key is held must see that key in the
array or it will think the key is up."
  (let* ((seat (keyboard-seat keyboard))
         (keys (seat-pressed-keys seat)))
    (wl-keyboard.enter keyboard serial surface
                       (and keys (encode-u32-array keys)))
    (wl-keyboard.modifiers keyboard serial
                           (seat-mods-depressed seat)
                           (seat-mods-latched seat)
                           (seat-mods-locked seat)
                           (seat-group seat))
    (setf (keyboard-surface keyboard) surface)))

(defun valid-serial-p (seat serial)
  "Was SERIAL issued recently by this seat's display?

Selections, popup grabs and interactive move/resize all name a serial, and the
only thing that makes the number meaningful is that *we* produced it in response
to an input event.  A client that invents one, or replays one from a previous
interaction, is refused (D33).  Focus is deliberately not part of this predicate:
whether the asking surface has the pointer is a separate question, and the shell
asks both."
  (display-valid-serial-p (seat-display seat) serial))

(defun set-keyboard-focus (seat surface &optional serial)
  "Give keyboard focus to SURFACE (or NIL) and tell both sides.

The keyboards of the client that owns SURFACE hear `enter`; the keyboards that
had focus hear `leave`; every other client hears nothing.  Doing it here, once,
is what stops enter/leave and the compositor's `set_activated` from drifting
apart -- both hang off this call."
  (let ((serial (or serial (display-next-serial (seat-display seat))))
        (old (seat-keyboard-focus seat)))
    (unless (eq old surface)
      (when old
        (dolist (keyboard (seat-keyboard-for-client seat (resource-client old)))
          (when (eq old (keyboard-surface keyboard))
            (wl-keyboard.leave keyboard serial old)
            (setf (keyboard-surface keyboard) nil))))
      (setf (seat-keyboard-focus seat) surface)
      (when surface
        (dolist (keyboard (seat-keyboard-for-client seat (resource-client surface)))
          (send-keyboard-enter keyboard surface serial)))
      (log-message :info "seat ~A: keyboard focus ~:[cleared~;on surface ~D~] (serial ~D)"
                   (seat-name seat) surface
                   (if surface (resource-id surface) 0) serial)
      (when old
        (seat-focus-changed seat old nil))
      (when surface
        (seat-focus-changed seat surface t)))
    serial))

(defun set-pointer-focus (seat surface x y &optional serial)
  "Give pointer focus to SURFACE at (X, Y), or clear it when SURFACE is NIL."
  (let ((serial (or serial (display-next-serial (seat-display seat))))
        (old (seat-pointer-focus seat)))
    (unless (and (eq old surface) (eql x (seat-pointer-x seat))
                 (eql y (seat-pointer-y seat)))
      (when old
        (dolist (pointer (seat-pointer-for-client seat (resource-client old)))
          (when (eq old (pointer-surface pointer))
            (wl-pointer.leave pointer serial old)
            (setf (pointer-surface pointer) nil))))
      (setf (seat-pointer-focus seat) surface
            (seat-pointer-x seat) x
            (seat-pointer-y seat) y)
      (when surface
        (dolist (pointer (seat-pointer-for-client seat (resource-client surface)))
          (wl-pointer.enter pointer serial surface x y)
          (setf (pointer-surface pointer) surface))))
    serial))

;;; ---------------------------------------------------------------------------
;;; Injecting: what a backend calls when a device reports something
;;; ---------------------------------------------------------------------------

(defun seat-time ()
  "Milliseconds, the unit every input event carries (wl_callback.done's unit)."
  (frame-timestamp))

(defun send-key-event (seat keycode state
                       &key (time (seat-time))
                         (mods-depressed (seat-mods-depressed seat))
                         (mods-latched (seat-mods-latched seat))
                         (mods-locked (seat-mods-locked seat))
                         (group (seat-group seat)))
  "Deliver one key to the focused client, then the modifier state it produced.

KEYCODE is the evdev key code (the keymap's keycodes are evdev + 8; the client
does the addition, which is what the `xkb_v1` format's documentation means).
Returns the serial, or NIL when nothing has keyboard focus."
  (let ((surface (seat-keyboard-focus seat)))
    (unless surface
      (return-from send-key-event nil))
    (let ((keyboards (seat-keyboard-for-client seat (resource-client surface))))
      (unless keyboards
        ;; Focus on a surface whose client has no keyboard object: the *other*
        ;; keyboards on the seat must not hear it either.
        (return-from send-key-event nil))
      (let ((serial (display-next-serial (seat-display seat))))
        ;; Track the logical key state before sending, so the events and the
        ;; array a later enter would carry agree.
        (ecase state
          (:pressed (pushnew keycode (seat-pressed-keys seat)))
          (:released (setf (seat-pressed-keys seat)
                           (remove keycode (seat-pressed-keys seat)))))
        (setf (seat-mods-depressed seat) mods-depressed
              (seat-mods-latched seat) mods-latched
              (seat-mods-locked seat) mods-locked
              (seat-group seat) group)
        (dolist (keyboard keyboards)
          (when (eq surface (keyboard-surface keyboard))
            (wl-keyboard.key keyboard serial time keycode
                             (if (eq state :pressed)
                                 +wl-keyboard-key-state-pressed+
                                 +wl-keyboard-key-state-released+))
            (wl-keyboard.modifiers keyboard serial mods-depressed mods-latched
                                   mods-locked group)))
        serial))))

(defun send-pointer-motion (seat x y &key (time (seat-time)))
  "Move the pointer to (X, Y) in focus-surface coordinates."
  (let ((surface (seat-pointer-focus seat)))
    (unless surface
      (return-from send-pointer-motion nil))
    (setf (seat-pointer-x seat) x
          (seat-pointer-y seat) y)
    (dolist (pointer (seat-pointer-for-client seat (resource-client surface)))
      (when (eq surface (pointer-surface pointer))
        (wl-pointer.motion pointer time x y)))
    t))

(defun send-pointer-button (seat button state &key (time (seat-time)))
  "A pointer button press or release.  Returns the serial (for grabs and clicks).

The seat remembers which buttons are down: a grab started from a middle-button
drag must end on the middle button, and "which button is down" is state the seat
owns, not something a grab can infer from the event that started it."
  (let ((surface (seat-pointer-focus seat)))
    (unless surface
      (return-from send-pointer-button nil))
    (ecase state
      (:pressed (pushnew button (seat-pressed-buttons seat)))
      (:released (setf (seat-pressed-buttons seat)
                       (remove button (seat-pressed-buttons seat)))))
    (let ((serial (display-next-serial (seat-display seat))))
      (dolist (pointer (seat-pointer-for-client seat (resource-client surface)))
        (when (eq surface (pointer-surface pointer))
          (wl-pointer.button pointer serial time button
                             (if (eq state :pressed)
                                 +wl-pointer-button-state-pressed+
                                 +wl-pointer-button-state-released+))))
      serial)))

(defun send-pointer-axis (seat axis value &key (time (seat-time)))
  "One axis event.  AXIS is :vertical or :horizontal; VALUE is in surface units."
  (let ((surface (seat-pointer-focus seat)))
    (unless surface
      (return-from send-pointer-axis nil))
    (dolist (pointer (seat-pointer-for-client seat (resource-client surface)))
      (when (eq surface (pointer-surface pointer))
        (wl-pointer.axis pointer time
                         (if (eq axis :vertical)
                             +wl-pointer-axis-vertical-scroll+
                             +wl-pointer-axis-horizontal-scroll+)
                         value)))
    t))

;;; ---------------------------------------------------------------------------
;;; wl_seat
;;; ---------------------------------------------------------------------------

(defmethod wl-seat.get-pointer ((binding seat-resource))
  "Create a wl_pointer for this client.  Requires the capability, ever."
  (let* ((seat (seat-resource-seat binding))
         (client (resource-client binding)))
    (unless (logtest +wl-seat-capability-pointer+ (seat-capabilities seat))
      (protocol-error client (resource-id binding)
                      +wl-seat-error-missing-capability+
                      "this seat has never had the pointer capability"))
    (let ((pointer (allocate-resource client
                                      (resolve-interface "wl_pointer")
                                      ;; The client asks for the version its
                                      ;; seat has; a v4 seat means v4 children.
                                      :version (resource-version binding)
                                      :class 'pointer
                                      :destroy-function #'destroy-pointer)))
      (setf (pointer-seat pointer) seat)
      (push pointer (seat-resource-pointers binding))
      (log-message :debug "client ~D: wl_pointer ~D created"
                   (client-id client) (resource-id pointer))
      ;; A pointer created while the seat already has focus must not have to wait
      ;; for the next motion to learn where it is.
      (let ((focus (seat-pointer-focus seat)))
        (when focus
          (wl-pointer.enter pointer (display-next-serial (seat-display seat))
                            focus (seat-pointer-x seat) (seat-pointer-y seat))
          (setf (pointer-surface pointer) focus)))
      pointer)))

(defmethod wl-seat.get-keyboard ((binding seat-resource))
  "Create a wl_keyboard and send its keymap, then repeat_info."
  (let* ((seat (seat-resource-seat binding))
         (client (resource-client binding)))
    (unless (logtest +wl-seat-capability-keyboard+ (seat-capabilities seat))
      (protocol-error client (resource-id binding)
                      +wl-seat-error-missing-capability+
                      "this seat has never had the keyboard capability"))
    (let ((keyboard (allocate-resource client
                                       (resolve-interface "wl_keyboard")
                                       :version (resource-version binding)
                                       :class 'keyboard
                                       :destroy-function #'destroy-keyboard)))
      (setf (keyboard-seat keyboard) seat)
      (push keyboard (seat-resource-keyboards binding))
      (log-message :debug "client ~D: wl_keyboard ~D created"
                   (client-id client) (resource-id keyboard))
      (send-keymap keyboard)
      (let ((focus (seat-keyboard-focus seat)))
        (when focus
          (send-keyboard-enter keyboard focus
                               (display-next-serial (seat-display seat)))))
      keyboard)))

(defmethod wl-seat.get-touch ((binding seat-resource))
  "Create a wl_touch.  No capability yet, so no events; see the class docstring."
  (let* ((seat (seat-resource-seat binding))
         (client (resource-client binding)))
    (unless (logtest +wl-seat-capability-touch+ (seat-capabilities seat))
      (protocol-error client (resource-id binding)
                      +wl-seat-error-missing-capability+
                      "this seat has never had the touch capability"))
    (let ((touch (allocate-resource client
                                    (resolve-interface "wl_touch")
                                    :version (resource-version binding)
                                    :class 'touch
                                    :destroy-function #'destroy-touch)))
      (setf (touch-seat touch) seat)
      (push touch (seat-resource-touches binding))
      (log-message :debug "client ~D: wl_touch ~D created"
                   (client-id client) (resource-id touch))
      touch)))

;; wl_seat.release is since 5 and we advertise 4, so the dispatch layer answers
;; it as invalid_method; a v4 client releases its wl_seat by destroying the
;; connection, which is what the protocol says.

(defun destroy-seat-resource (binding)
  "A client's wl_seat is gone: its pointer/keyboard/touch objects die with it."
  (let ((seat (seat-resource-seat binding)))
    (when seat
      (setf (seat-bindings seat) (remove binding (seat-bindings seat))))))

;;; ---------------------------------------------------------------------------
;;; wl_pointer
;;; ---------------------------------------------------------------------------

(defmethod wl-pointer.set-cursor ((pointer pointer) serial surface hotspot-x hotspot-y)
  "Record the cursor image.  Accepted, stored, not drawn: there is no software
cursor yet, and a cursor that silently did not appear would be worse than one
that is documented as absent."
  (when (and surface (surface-shell-surface surface))
    (protocol-error (resource-client pointer) (resource-id pointer)
                    +wl-pointer-error-role+
                    "cursor surface ~D already has the ~(~A~) role"
                    (resource-id surface)
                    (xdg-surface-role-name (surface-shell-surface surface))))
  (setf (pointer-cursor-surface pointer) surface
        (pointer-cursor-hotspot-x pointer) hotspot-x
        (pointer-cursor-hotspot-y pointer) hotspot-y
        (pointer-cursor-serial pointer) serial)
  (log-message :debug "client ~D: cursor ~:[hidden~;surface ~D at ~D,~D~] (serial ~D)"
               (client-id (resource-client pointer))
               surface (if surface (resource-id surface) 0) hotspot-x hotspot-y serial)
  nil)

(defmethod wl-pointer.release ((pointer pointer))
  (destroy-resource pointer))

(defun destroy-pointer (pointer)
  "Drop POINTER from every binding's list; the seat keeps its focus."
  (log-message :debug "client ~D: wl_pointer ~D released"
               (client-id (resource-client pointer)) (resource-id pointer))
  (dolist (binding (seat-bindings (pointer-seat pointer)))
    (setf (seat-resource-pointers binding)
          (remove pointer (seat-resource-pointers binding))))
  (setf (pointer-surface pointer) nil))

;;; ---------------------------------------------------------------------------
;;; wl_keyboard
;;; ---------------------------------------------------------------------------

(defmethod wl-keyboard.release ((keyboard keyboard))
  (destroy-resource keyboard))

(defun destroy-keyboard (keyboard)
  "Drop KEYBOARD from every binding's list.

The seat keeps its focus: another keyboard of the same client, or the client's
next keyboard, still belongs to the focused surface."
  (let ((seat (keyboard-seat keyboard)))
    (when seat
      (dolist (binding (seat-bindings seat))
        (setf (seat-resource-keyboards binding)
              (remove keyboard (seat-resource-keyboards binding))))))
  (setf (keyboard-surface keyboard) nil))

;;; ---------------------------------------------------------------------------
;;; wl_touch
;;; ---------------------------------------------------------------------------

(defmethod wl-touch.release ((touch touch))
  (destroy-resource touch))

(defun destroy-touch (touch)
  (let ((seat (touch-seat touch)))
    (when seat
      (dolist (candidate (seat-bindings seat))
        (setf (seat-resource-touches candidate)
              (remove touch (seat-resource-touches candidate))))))
  nil)
