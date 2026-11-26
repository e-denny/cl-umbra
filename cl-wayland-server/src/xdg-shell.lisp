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
;;;; Popups (xdg_surface.get_popup) and positioners (xdg_wm_base.create_positioner)
;;;; are implemented here too, at version 1: a popup gets one configure, at the
;;;; position the positioner's rules ask for, constrained to the area the
;;;; compositor names (POPUP-CONSTRAINT-BOX) -- and `grab' is honoured by a hook the
;;;; compositor answers (POPUP-GRAB-REQUESTED), because a grab is policy.
;;;;
;;;; Deliberately absent, and a missing method is how the dispatch layer says so (it
;;;; becomes wl_display.error implementation, "not built yet"): decoration
;;;; negotiation, and the v3 additions to popups (reposition, reactive
;;;; positioning), which the v1 global does not advertise.  A compositor that
;;;; advertises xdg_wm_base v1 and refuses the requests it cannot honour is honest;
;;;; advertising v4 and staying silent about configure_bounds would not be.

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

On a later commit: notice the role's surface appearing and disappearing, which is
what a compositor's map/unmap policy hangs off (cf.types.xdg-shell).  A popup's
first commit is answered with PLACE-POPUP's geometry instead of a toplevel
configure: that is the one place where the two roles differ in the handshake."
  (declare (ignore damage))
  (unless (xdg-surface-live-p shell)
    (return-from surface-shell-committed nil))
  (cond
    ((not (xdg-surface-configured-p shell))
     ;; The initial commit is the client saying "I am ready to be told a size".
     ;; Nothing may be attached yet (CHECK-COMMIT has already refused it), so
     ;; there is nothing to draw and no state to compute.
     (if (eq (xdg-surface-role-name shell) :popup)
         (configure-popup (xdg-surface-role shell) surface)
         (send-configure shell)))
    (t
     (shell-surface-mapped shell surface)))
  nil)

(defun shell-surface-mapped (shell surface)
  "Notice SHELL's surface mapping or unmapping, and tell the role.

One function for both roles, because the *question* is the same: did the surface go
from unmapped to mapped, or the other way?  What differs is only what the record is
called (a toplevel and a popup both keep MAPPED-P) and who hears about it."
  (let ((mapped (and (surface-mapped-p surface) t))
        (role (xdg-surface-role shell)))
    (unless (eq mapped (xdg-surface-mapped-p shell))
      (setf (xdg-surface-mapped-p shell) mapped)
      (typecase role
        (xdg-toplevel
         (setf (xdg-toplevel-mapped-p role) mapped)
         (log-message :info "client ~D: toplevel ~D ~:[unmapped~;mapped~]~@[ (title ~S)~]"
                      (client-id (resource-client shell))
                      (resource-id role)
                      mapped
                      (xdg-toplevel-title role)))
        (xdg-popup
         (setf (xdg-popup-mapped-p role) mapped)
         (log-message :debug "client ~D: popup ~D ~:[unmapped~;mapped~] at ~S"
                      (client-id (resource-client shell))
                      (resource-id role)
                      mapped
                      (xdg-popup-geometry role))))))
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

;;; xdg_wm_base.create-positioner and xdg_positioner: a rule for a child surface
;;;
;;; A positioner is the odd object of the shell: it is a *rule*, not a surface, it
;;; draws nothing, and it exists for one call.  The spec is explicit that the
;;; compositor copies the rules at get_popup, so everything here is "store it" and
;;; the interesting part -- the arithmetic -- is POSITIONER-PLACE below.

(defmethod xdg-wm-base.create-positioner ((wm-base xdg-wm-base))
  "Create the positioner a client will fill in and hand to get_popup."
  (let ((client (resource-client wm-base)))
    (let ((positioner (allocate-resource client
                                         (resolve-interface "xdg_positioner")
                                         :version (resource-version wm-base)
                                         :class 'xdg-positioner)))
      (log-message :debug "client ~D: xdg_positioner ~D"
                   (client-id client) (resource-id positioner))
      positioner)))

(defmethod xdg-positioner.destroy ((positioner xdg-positioner))
  (destroy-resource positioner))

(defmethod xdg-positioner.set-size ((positioner xdg-positioner) width height)
  (when (or (<= width 0) (<= height 0))
    (protocol-error (resource-client positioner) (resource-id positioner)
                    +xdg-positioner-error-invalid-input+
                    "positioner size ~Dx~D is not positive" width height))
  (setf (xdg-positioner-size positioner) (list width height)))

(defmethod xdg-positioner.set-anchor-rect ((positioner xdg-positioner) x y width height)
  (when (or (minusp width) (minusp height))
    (protocol-error (resource-client positioner) (resource-id positioner)
                    +xdg-positioner-error-invalid-input+
                    "anchor rectangle ~Dx~D has a negative side" width height))
  (setf (xdg-positioner-anchor-rect positioner) (list x y width height)))

(defmethod xdg-positioner.set-anchor ((positioner xdg-positioner) anchor)
  (unless (<= +xdg-positioner-anchor-none+ anchor +xdg-positioner-anchor-bottom-right+)
    (protocol-error (resource-client positioner) (resource-id positioner)
                    +xdg-positioner-error-invalid-input+
                    "anchor ~D is not an xdg_positioner.anchor value" anchor))
  (setf (xdg-positioner-anchor positioner) anchor))

(defmethod xdg-positioner.set-gravity ((positioner xdg-positioner) gravity)
  ;; The XML says this one raises invalid_input, and it is the only value here that
  ;; does; set_anchor is checked the same way because a value outside its enum is
  ;; not a positioner rule either (D44).
  (unless (<= +xdg-positioner-gravity-none+ gravity +xdg-positioner-gravity-bottom-right+)
    (protocol-error (resource-client positioner) (resource-id positioner)
                    +xdg-positioner-error-invalid-input+
                    "gravity ~D is not an xdg_positioner.gravity value" gravity))
  (setf (xdg-positioner-gravity positioner) gravity))

(defmethod xdg-positioner.set-constraint-adjustment ((positioner xdg-positioner)
                                                     adjustment)
  "Store the adjustment bits; unknown bits are dropped, not an error.

The positioner's error enum has one value (`invalid_input'), and the XML names no
error for an unknown adjustment bit.  Dropping a bit nobody defines is the honest
reading of 'adjust as you can'; disconnecting is not."
  (let ((known (logand adjustment
                       (logior +xdg-positioner-constraint-adjustment-slide-x+
                               +xdg-positioner-constraint-adjustment-slide-y+
                               +xdg-positioner-constraint-adjustment-flip-x+
                               +xdg-positioner-constraint-adjustment-flip-y+
                               +xdg-positioner-constraint-adjustment-resize-x+
                               +xdg-positioner-constraint-adjustment-resize-y+))))
    (unless (= known adjustment)
      (log-message :debug "positioner ~D: constraint adjustment ~D has unknown bits; ~D used"
                   (resource-id positioner) adjustment known))
    (setf (xdg-positioner-constraint-adjustment positioner) known)))

(defmethod xdg-positioner.set-offset ((positioner xdg-positioner) x y)
  (setf (xdg-positioner-offset positioner) (list x y)))

(defun positioner-complete-p (positioner)
  "Is POSITIONER usable: a non-zero size *and* a non-zero anchor rectangle?

That is the spec's definition, and the two NILs are separate from zero: set_size
with 0 is an error at the request, so a stored size is already positive, while
set_anchor_rect accepts a zero side (a client may place a popup relative to a
one-pixel-wide caret, then widen it) -- so the rectangle is checked here."
  (let ((size (xdg-positioner-size positioner))
        (rect (xdg-positioner-anchor-rect positioner)))
    (and size (plusp (first size)) (plusp (second size))
         rect (plusp (third rect)) (plusp (fourth rect)))))

(defun positioner-rule (positioner)
  "A snapshot of POSITIONER's rules, as the plist a popup keeps for its lifetime.

Keys: :width :height (the surface size), :anchor-rect (:x :y :width :height),
:anchor, :gravity, :constraint (adjustment bits) and :offset (:x :y).  Copying is
the point: the xdg_positioner description says the compositor makes a copy at the
request, so the client may reuse or destroy the positioner the moment get_popup has
been answered."
  (list :width (first (xdg-positioner-size positioner))
        :height (second (xdg-positioner-size positioner))
        :anchor-rect (copy-list (xdg-positioner-anchor-rect positioner))
        :anchor (xdg-positioner-anchor positioner)
        :gravity (xdg-positioner-gravity positioner)
        :constraint (xdg-positioner-constraint-adjustment positioner)
        :offset (copy-list (xdg-positioner-offset positioner))))

;;; ---------------------------------------------------------------------------
;;; The positioner's arithmetic
;;;
;;; Pure functions on a rule plist and a box, so the part that can be wrong in a way
;;; a screenshot will not show is testable on its own (the same split as
;;; cf.grab:resize-target-size, D42).  Everything is in the parent's *window
;;; geometry* space, because that is the space xdg_popup.configure's x and y are
;;; relative to; a compositor converts its output bounds into that space and hands
;;; them to POPUP-CONSTRAINT-BOX.
;;; ---------------------------------------------------------------------------

(defun corner-directions (value)
  "The sides a corner-enum value names: (values horizontal vertical).

ANCHOR and GRAVITY share this layout (none=0, top=1, bottom=2, left=3, right=4 and
the four corners), so one reader serves both.  0 -- and anything out of range, which
the setters refuse -- means 'no direction': centred on that axis."
  (case value
    (1 (values nil :top))
    (2 (values nil :bottom))
    (3 (values :left nil))
    (4 (values :right nil))
    (5 (values :left :top))
    (6 (values :left :bottom))
    (7 (values :right :top))
    (8 (values :right :bottom))
    (t (values nil nil))))

(defparameter +flip-horizontal+
  '((0 . 0) (1 . 1) (2 . 2) (3 . 4) (4 . 3) (5 . 7) (6 . 8) (7 . 5) (8 . 6))
  "ANCHOR/GRAVITY values with left and right exchanged, top and bottom kept.")

(defparameter +flip-vertical+
  '((0 . 0) (1 . 2) (2 . 1) (3 . 3) (4 . 4) (5 . 6) (6 . 5) (7 . 8) (8 . 7))
  "ANCHOR/GRAVITY values with top and bottom exchanged, left and right kept.")

(defun flip-horizontal (value) (cdr (assoc value +flip-horizontal+)))
(defun flip-vertical (value) (cdr (assoc value +flip-vertical+)))

(defun anchor-point (rect anchor)
  "The point inside RECT ((x y width height)) that ANCHOR names, as two values.

A corner anchors the corner itself, an edge the middle of that edge, and `none' the
centre of the rectangle."
  (multiple-value-bind (horizontal vertical) (corner-directions anchor)
    (destructuring-bind (x y width height) rect
      (values (case horizontal
                (:left x)
                (:right (+ x width))
                (t (+ x (floor width 2))))
              (case vertical
                (:top y)
                (:bottom (+ y height))
                (t (+ y (floor height 2))))))))

(defun gravity-origin (gravity width height)
  "Where a WIDTH x HEIGHT popup's top-left corner sits relative to its anchor point.

Gravity `top_left' means the popup is placed *towards* the top left, so its own
bottom-right corner is on the anchor point: both offsets are negative.  A gravity
with no direction on an axis centres the popup on it."
  (multiple-value-bind (horizontal vertical) (corner-directions gravity)
    (values (case horizontal
              (:right 0)
              (:left (- width))
              (t (- (floor width 2))))
            (case vertical
              (:bottom 0)
              (:top (- height))
              (t (- (floor height 2)))))))

(defun popup-position (rule anchor gravity)
  "The popup's top-left corner for RULE with ANCHOR and GRAVITY, and its offset.

Relative to the upper-left corner of the parent's window geometry, which is exactly
what xdg_popup.configure carries.  Two values."
  (multiple-value-bind (anchor-x anchor-y)
      (anchor-point (getf rule :anchor-rect) anchor)
    (multiple-value-bind (dx dy) (gravity-origin gravity (getf rule :width) (getf rule :height))
      (values (+ anchor-x dx (first (getf rule :offset)))
              (+ anchor-y dy (second (getf rule :offset)))))))

(defun span-inside-p (position size box-position box-size)
  "Does a SIZE-long span at POSITION lie inside a BOX-SIZE-long box at BOX-POSITION?"
  (and (<= box-position position)
       (<= (+ position size) (+ box-position box-size))))

(defun slide-position (position size box-position box-size)
  "SLIDE one axis until the span is inside, or as close as it can get.

A span shorter than the box moves the shortest distance that puts it inside.  A span
*longer* than the box cannot be unconstrained at all, so it is placed so that it
covers the box -- the same rule as cf.grab:clamp-to-output, and for the same reason:
what is left outside must not be the part you need."
  (if (<= size box-size)
      (max box-position (min position (- (+ box-position box-size) size)))
      (max (- (+ box-position box-size) size) (min position box-position))))

(defun shrink-to-fit (position size box-position box-size)
  "RESIZE one axis so a SIZE-long span at POSITION is inside the box; two values."
  (when (< position box-position)
    (decf size (- box-position position))
    (setf position box-position))
  (when (> (+ position size) (+ box-position box-size))
    (setf size (- (+ box-position box-size) position)))
  (values position (max 1 size)))

(defun constrain-popup (rule x y width height box)
  "Apply RULE's constraint adjustment to a popup at (X, Y, WIDTH, HEIGHT) in BOX.

Box is (x y width height) in the parent's window-geometry space.  The adjustments
are applied in the order the spec fixes and only to a constrained axis:

  1. flip   -- swap the anchor and gravity on that axis, and keep the result only if
               it is actually unconstrained (otherwise the unflipped position is
               kept, as the XML requires);
  2. slide  -- move the popup along the axis until it is inside, or as close as a
               popup larger than the box can be;
  3. resize -- shrink the popup so that it fits, when the client allowed it.

Returns (values x y width height)."
  (let ((adjustment (getf rule :constraint))
        (anchor (getf rule :anchor))
        (gravity (getf rule :gravity))
        (box-x (first box))
        (box-y (second box))
        (box-width (third box))
        (box-height (fourth box)))
    (unless (span-inside-p x width box-x box-width)
      (when (logtest +xdg-positioner-constraint-adjustment-flip-x+ adjustment)
        (multiple-value-bind (flipped-x flipped-y)
            (popup-position rule (flip-horizontal anchor) (flip-horizontal gravity))
          (declare (ignore flipped-y))
          (when (span-inside-p flipped-x width box-x box-width)
            (setf x flipped-x
                  anchor (flip-horizontal anchor)
                  gravity (flip-horizontal gravity)))))
      (when (and (logtest +xdg-positioner-constraint-adjustment-slide-x+ adjustment)
                 (not (span-inside-p x width box-x box-width)))
        (setf x (slide-position x width box-x box-width)))
      (when (and (logtest +xdg-positioner-constraint-adjustment-resize-x+ adjustment)
                 (not (span-inside-p x width box-x box-width)))
        (multiple-value-setq (x width) (shrink-to-fit x width box-x box-width))))
    (unless (span-inside-p y height box-y box-height)
      (when (logtest +xdg-positioner-constraint-adjustment-flip-y+ adjustment)
        (multiple-value-bind (flipped-x flipped-y)
            (popup-position rule (flip-vertical anchor) (flip-vertical gravity))
          (declare (ignore flipped-x))
          (when (span-inside-p flipped-y height box-y box-height)
            (setf y flipped-y))))
      (when (and (logtest +xdg-positioner-constraint-adjustment-slide-y+ adjustment)
                 (not (span-inside-p y height box-y box-height)))
        (setf y (slide-position y height box-y box-height)))
      (when (and (logtest +xdg-positioner-constraint-adjustment-resize-y+ adjustment)
                 (not (span-inside-p y height box-y box-height)))
        (multiple-value-setq (y height) (shrink-to-fit y height box-y box-height))))
    (values x y (max 1 width) (max 1 height))))

(defun place-popup (rule &optional constraint-box)
  "Where RULE puts a popup: (values x y width height), parent-geometry relative.

Without a constraint box the position is exactly what the positioner asked for -- a
server with no output has no work area to constrain against, and a guess would be
worse than the client's own numbers."
  (multiple-value-bind (x y)
      (popup-position rule (getf rule :anchor) (getf rule :gravity))
    (if constraint-box
        (constrain-popup rule x y (getf rule :width) (getf rule :height) constraint-box)
        (values x y (getf rule :width) (getf rule :height)))))


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

;;; ---------------------------------------------------------------------------
;;; Interactive move/resize: the policy hook
;;; ---------------------------------------------------------------------------
;;
;; xdg_toplevel.move and .resize are a client *asking* to be dragged.  The
;; compositor decides whether to: the serial must be one we issued recently
;; (D33), and the asking surface must be the one the pointer or the keyboard is
;; on.  A refused request is not an error -- the protocol defines none for this --
;; it is a no-op, because a client asking to move a window it does not have is a
;; client whose click we already ignored.
;;
;; The grab itself is policy, not protocol, so the shell only *reports* it.  The
;; hook is dispatched on the wl_surface, which is the object a framework has
;; already subclassed (CF-SURFACE in the headless compositor); the default does
;; nothing, so a transport-only server still answers xdg-shell correctly.

(defgeneric toplevel-move-requested (surface toplevel serial seat)
  (:documentation
   "SURFACE (a toplevel's wl_surface) asked to be moved, with a validated SERIAL.

SEAT is the seat the client named, resolved, or NIL if it named something else.
The default does nothing: grabbing is compositor policy.  Send the matching
`move' event to the client when the grab ends (xdg-shell v5; the global here is
v1, so there is nothing to send).")
  (:method (surface toplevel serial seat)
    (declare (ignore surface toplevel serial seat))
    nil))

(defgeneric toplevel-resize-requested (surface toplevel serial seat edges)
  (:documentation
   "SURFACE asked to be resized from EDGES, with a validated SERIAL.

EDGES is the xdg_toplevel.resize_edge bitmask, from one edge to two adjacent
ones (a corner).  The default does nothing.")
  (:method (surface toplevel serial seat edges)
    (declare (ignore surface toplevel serial seat edges))
    nil))

(defun toplevel-surface (toplevel)
  "The wl_surface a toplevel draws through, or NIL."
  (let ((shell (xdg-toplevel-shell-surface toplevel)))
    (and shell (xdg-surface-surface shell))))

(defun grab-request-acceptable-p (seat surface serial)
  "Is a move/resize request from SURFACE, naming SERIAL on SEAT, to be honoured?"
  (and seat
       surface
       serial
       (valid-serial-p seat serial)
       (or (eq surface (seat-keyboard-focus seat))
           (eq surface (seat-pointer-focus seat)))))

(defun request-toplevel-size (toplevel width height)
  "Ask the client for WIDTH x HEIGHT, keeping the states it already has.

This is what an interactive resize *is* for a shm client: the compositor cannot
resize a buffer it does not own, so it configures a size and the client comes
back with a buffer that size.  The size is remembered on the toplevel, so a later
configure for a focus change (SET-TOPLEVEL-ACTIVATED) keeps it instead of
resetting the window to 0x0, 'you choose'."
  (let* ((shell (xdg-toplevel-shell-surface toplevel))
         (states (xdg-toplevel-configure-states toplevel)))
    (when (and shell (shell-alive-p shell))
      (send-configure shell
                      :width (max 0 width)
                      :height (max 0 height)
                      :states states))))

(defmethod xdg-toplevel.show-window-menu ((toplevel xdg-toplevel) seat serial x y)
  (declare (ignore seat x y))
  (log-message :debug "toplevel ~D: show_window_menu (serial ~D) ignored"
               (resource-id toplevel) serial)
  nil)

(defmethod xdg-toplevel.move ((toplevel xdg-toplevel) seat-object serial)
  (let* ((surface (toplevel-surface toplevel))
         (seat (and (typep seat-object 'seat-resource)
                    (seat-resource-seat seat-object))))
    (if (grab-request-acceptable-p seat surface serial)
        (toplevel-move-requested surface toplevel serial seat)
        (log-message :debug "toplevel ~D: move refused (serial ~D, seat ~S, focused ~S)"
                     (resource-id toplevel) serial
                     (not (null seat)) (not (null surface))))))

(defmethod xdg-toplevel.resize ((toplevel xdg-toplevel) seat-object serial edges)
  (unless (member edges '(0 1 2 4 5 6 8 9 10))
    (protocol-error (resource-client toplevel) (resource-id toplevel)
                    +xdg-toplevel-error-invalid-resize-edge+
                    "resize edge ~D is not a variant of the enum" edges))
  (let* ((surface (toplevel-surface toplevel))
         (seat (and (typep seat-object 'seat-resource)
                    (seat-resource-seat seat-object))))
    (if (grab-request-acceptable-p seat surface serial)
        (toplevel-resize-requested surface toplevel serial seat edges)
        (log-message :debug "toplevel ~D: resize refused (serial ~D, edges ~D)"
                     (resource-id toplevel) serial edges))))

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

;;; ---------------------------------------------------------------------------
;;; xdg_surface.get_popup and xdg_popup
;;;
;;; A popup is a toplevel's child: it is positioned once (from a copy of a
;;; positioner's rules), it may take an explicit grab (which is an owner-events
;;; grab: the popup's client hears the pointer, and a press outside the stack
;;; dismisses it), and when it goes away the compositor says so with popup_done
;;; rather than unmapping in silence.
;;;
;;; What the protocol layer owns is the *state*: the parent chain, the copied rule,
;;; the configure that carries the placement, the ordering rules ("a client may only
;;; destroy the topmost popup"), and the two errors the XML names.  What it does not
;;; own is policy, so three hooks go to the compositor, dispatched on the popup's
;;; wl_surface -- the object a framework subclasses (D7):
;;;
;;;   POPUP-CONSTRAINT-BOX    where the popup may not leave (the output, in the
;;;                           parent's window-geometry space)
;;;   POPUP-GRAB-REQUESTED    a validated explicit grab: take the pointer
;;;   POPUP-DISMISSED         it is off the screen: drop the node, hand focus back
;;; ---------------------------------------------------------------------------

(defgeneric popup-constraint-box (surface popup)
  (:documentation
   "The box POPUP must stay inside, in its parent's window-geometry space, or NIL.

The popup's configure position is relative to the upper-left corner of the parent's
*window geometry*, so a compositor converts its output: an output at (0,0) 1280x800
with the parent's geometry at (32,32) in output space is the box (-32 -32 1280 800).
The default is NIL -- no constraint -- because a transport-only server has no output,
and an unconstrained position is honest where a guess would not be.")
  (:method (surface popup)
    (declare (ignore surface popup))
    nil))

(defgeneric popup-grab-requested (surface popup seat serial)
  (:documentation
   "POPUP asked for an explicit grab, with a SEAT and a SERIAL this display issued.

The default does nothing, so a compositor without a seat still answers the protocol
(and lets the popup be dismissed by its own client).  A compositor that honours it
owns the pointer until the popup is dismissed and must send popup_done when the user
clicks outside it.  The serial has already been validated against the display's
recent serials; the surface is the popup's own wl_surface.")
  (:method (surface popup seat serial)
    (declare (ignore surface popup seat serial))
    nil))

(defgeneric popup-dismissed (surface popup reason)
  (:documentation
   "POPUP is off the screen: dismissed by the compositor (:DISMISSED, :CLICK-OUTSIDE,
:KEYBOARD, :GRAB-REFUSED, :PARENT-DISMISSED) or destroyed by its client (:DESTROYED).

SURFACE is the popup's wl_surface.  The default does nothing; a compositor drops the
scene node and hands keyboard focus back to the window the popup belonged to.")
  (:method (surface popup reason)
    (declare (ignore surface popup reason))
    nil))

(defun xdg-popup-toplevel (popup)
  "The xdg_toplevel POPUP ultimately belongs to, or NIL for an unparented popup.

A popup's parent is an xdg_surface whose role is a toplevel or another popup; the
walk up that chain is what the stacking and \"topmost popup\" rules are about."
  (loop with shell = (xdg-popup-parent popup)
        with limit = 16
        while (and shell (plusp limit))
        do (let ((role (xdg-surface-role shell)))
             (cond ((typep role 'xdg-toplevel)
                    (return role))
                   ((typep role 'xdg-popup)
                    (setf shell (xdg-popup-parent role)))
                   (t (return nil))))
           (decf limit)))

(defun popup-topmost-p (popup)
  "Is POPUP the popup its client may destroy: the newest live one of its toplevel?

Dismissed popups do not count: they are off the screen but still the client's to
destroy, and refusing that would leave a client unable to clean up."
  (let ((toplevel (xdg-popup-toplevel popup)))
    (if toplevel
        (let ((live (remove-if (lambda (other)
                                 (or (resource-destroyed-p other)
                                     (xdg-popup-dismissed-p other)))
                               (xdg-toplevel-popups toplevel))))
          (or (null live) (eq popup (car (last live)))))
        t)))

(defun unlink-popup (popup)
  "Take POPUP out of its toplevel's popup list."
  (let ((toplevel (xdg-popup-toplevel popup)))
    (when toplevel
      (setf (xdg-toplevel-popups toplevel)
            (remove popup (xdg-toplevel-popups toplevel) :test #'eq)))
    popup))

(defmethod xdg-surface.get-popup ((shell xdg-surface) parent positioner)
  "Give this surface the popup role, placed by a copy of POSITIONER's rules."
  (let ((client (resource-client shell)))
    (unless (xdg-surface-live-p shell)
      (protocol-error client (resource-id shell) +xdg-surface-error-not-constructed+
                      "this xdg_surface lost its wl_surface"))
    (when (xdg-surface-role shell)
      (protocol-error client (resource-id shell)
                      +xdg-surface-error-already-constructed+
                      "this xdg_surface already has the ~(~A~) role"
                      (xdg-surface-role-name shell)))
    (unless (positioner-complete-p positioner)
      (protocol-error client (resource-id shell)
                      +xdg-wm-base-error-invalid-positioner+
                      "the positioner has no size, or no anchor rectangle"))
    (when parent
      (cond
        ((eq parent shell)
         (protocol-error client (resource-id shell)
                         +xdg-wm-base-error-invalid-popup-parent+
                         "an xdg_surface cannot be its own popup parent"))
        ((or (resource-destroyed-p parent)
             (not (xdg-surface-live-p parent))
             (null (xdg-surface-role parent)))
         (protocol-error client (resource-id shell)
                         +xdg-wm-base-error-invalid-popup-parent+
                         "the parent xdg_surface ~D has no role (or no surface)"
                         (resource-id parent)))))
    (let ((popup (allocate-resource client
                                    (resolve-interface "xdg_popup")
                                    :version (resource-version shell)
                                    :class 'xdg-popup
                                    :destroy-function #'destroy-xdg-popup)))
      (setf (xdg-popup-shell-surface popup) shell
            (xdg-popup-parent popup) parent
            (xdg-popup-rule popup) (positioner-rule positioner)
            (xdg-surface-role shell) popup
            (xdg-surface-role-name shell) :popup)
      ;; Creation order is stacking order, so a new popup goes last.
      (let ((toplevel (xdg-popup-toplevel popup)))
        (when toplevel
          (setf (xdg-toplevel-popups toplevel)
                (append (xdg-toplevel-popups toplevel) (list popup)))))
      (log-message :debug "client ~D: xdg_popup ~D for xdg_surface ~D (parent ~S)"
                   (client-id client) (resource-id popup) (resource-id shell)
                   (and parent (resource-id parent)))
      popup)))

(defun send-popup-configure (popup x y width height)
  "Send xdg_popup.configure then xdg_surface.configure; returns the serial.

The order is what makes the pair atomic: the role's geometry comes first, the
xdg_surface.configure serial that the client acks comes last, exactly as for a
toplevel (docs/framework.md §6)."
  (let ((shell (xdg-popup-shell-surface popup)))
    (unless (and shell (shell-alive-p shell))
      (return-from send-popup-configure nil))
    (let ((serial (display-next-serial (resource-display popup))))
      (xdg-popup.configure popup x y width height)
      (setf (xdg-popup-geometry popup) (list x y width height)
            (xdg-popup-configure-count popup)
            (1+ (xdg-popup-configure-count popup)))
      (xdg-surface.configure shell serial)
      (setf (xdg-surface-configure-serial shell) serial
            (xdg-surface-configured-p shell) t
            (xdg-surface-pending-serials shell)
            (cons serial (xdg-surface-pending-serials shell)))
      (log-message :debug "client ~D: popup ~D configured at (~D, ~D) ~Dx~D (serial ~D)"
                   (client-id (resource-client popup)) (resource-id popup)
                   x y width height serial)
      serial)))

(defun configure-popup (popup surface)
  "Answer a popup's initial commit with its placement, and only its placement.

Unlike a toplevel there is nothing for the client to choose: the size is the
positioner's and the position is the compositor's, so the configure is a decision,
not a suggestion.  A popup with no parent is not configured at all -- in v1 a null
parent means \"some other protocol will say\", and no other protocol here can."
  (let ((parent (xdg-popup-parent popup)))
    (cond
      ((null parent)
       (log-message :debug "popup ~D has no parent and no other protocol gives it one; not mapping"
                    (resource-id popup))
       nil)
      (t
       (multiple-value-bind (x y width height)
           (place-popup (xdg-popup-rule popup) (popup-constraint-box surface popup))
         (send-popup-configure popup x y width height))))))

(defmethod xdg-popup.grab ((popup xdg-popup) seat-object serial)
  "Take an explicit grab, or refuse it and dismiss the popup, as the spec says."
  (let* ((shell (xdg-popup-shell-surface popup))
         (surface (and shell (xdg-surface-surface shell)))
         (seat (and (typep seat-object 'seat-resource)
                    (seat-resource-seat seat-object)))
         (parent (xdg-popup-parent popup))
         (parent-role (and parent (xdg-surface-role parent))))
    (when (xdg-popup-mapped-p popup)
      (protocol-error (resource-client popup) (resource-id popup)
                      +xdg-popup-error-invalid-grab+
                      "grab after the popup was mapped"))
    ;; A popup may only parent a *grabbing* popup, and a dismissed parent dismisses
    ;; its child before the child could ever be shown.
    (when (typep parent-role 'xdg-popup)
      (cond
        ((xdg-popup-dismissed-p parent-role)
         (dismiss-popup popup :reason :parent-dismissed)
         (return-from xdg-popup.grab nil))
        ((not (xdg-popup-grabbed-p parent-role))
         (let ((wm-base (xdg-surface-wm-base shell)))
           (protocol-error (resource-client popup)
                           (if wm-base (resource-id wm-base) (resource-id popup))
                           +xdg-wm-base-error-invalid-popup-parent+
                           "the parent popup ~D has no explicit grab"
                           (resource-id parent-role))))))
    (cond
      ((and surface serial seat (valid-serial-p seat serial))
       (setf (xdg-popup-grabbed-p popup) t)
       (log-message :debug "client ~D: popup ~D took an explicit grab (serial ~D)"
                    (client-id (resource-client popup)) (resource-id popup) serial)
       (popup-grab-requested surface popup seat serial)
       t)
      (t
       ;; "If the compositor denies the grab, the popup will be immediately
       ;; dismissed."  A serial we never issued is a grab we cannot honour.
       (log-message :debug "popup ~D: grab refused (serial ~S, seat ~S); dismissing"
                    (resource-id popup) serial (not (null seat)))
       (dismiss-popup popup :reason :grab-refused)
       nil))))

(defun dismiss-popup (popup &key (reason :dismissed))
  "Take POPUP off the screen and tell its client (xdg_popup.popup_done).

Idempotent: a popup dismissed twice (a click and a key in the same batch) sends one
popup_done, because the second one would name a surface the client has already
forgotten.  The object stays alive: destroying it is the client's decision."
  (unless (or (xdg-popup-dismissed-p popup) (resource-destroyed-p popup))
    (let* ((shell (xdg-popup-shell-surface popup))
           (surface (and shell (xdg-surface-surface shell))))
      (setf (xdg-popup-dismissed-p popup) t
            (xdg-popup-mapped-p popup) nil
            (xdg-popup-grabbed-p popup) nil)
      (when (and shell (shell-alive-p shell))
        (xdg-popup.popup-done popup)
        (setf (xdg-surface-mapped-p shell) nil))
      (when (and surface (not (resource-destroyed-p surface)))
        ;; Unmapping here, not only in the client: "at the same time the surface
        ;; will be unmapped" is the compositor's half of popup_done.
        (setf (surface-mapped-p surface) nil)
        (popup-dismissed surface popup reason))
      (log-message :debug "client ~D: popup ~D dismissed (~A)"
                   (client-id (resource-client popup)) (resource-id popup) reason)
      t)))

(defun dismiss-popup-chain (popup &key (reason :dismissed))
  "Dismiss POPUP and every popup created after it under the same toplevel.

Topmost first, which is the only order a client can answer: a submenu goes before
the menu it belongs to, and each gets its own popup_done.  A compositor is allowed
to dismiss a whole nested stack (the xdg_popup.grab description says so), and a
click outside a menu is exactly that."
  (let* ((toplevel (xdg-popup-toplevel popup))
         (stack (if toplevel (xdg-toplevel-popups toplevel) (list popup)))
         (tail (member popup stack :test #'eq)))
    (dolist (other (reverse (copy-list tail)))
      (dismiss-popup other :reason reason))))

(defun destroy-xdg-popup (popup)
  "POPUP's id is gone: unmap the surface, unlink it, and free the role."
  (let* ((shell (xdg-popup-shell-surface popup))
         (surface (and shell (not (resource-destroyed-p shell))
                       (xdg-surface-surface shell))))
    ;; The compositor hears first, while both objects still point at each other.
    (when (and surface (not (resource-destroyed-p surface)))
      (popup-dismissed surface popup :destroyed)
      (setf (surface-mapped-p surface) nil))
    (unlink-popup popup)
    (when (and shell (not (resource-destroyed-p shell)))
      ;; The surface is "newly unmapped": per the spec it needs a fresh initial
      ;; commit and a new role, exactly as after an xdg_toplevel is destroyed.
      (setf (xdg-surface-role shell) nil
            (xdg-surface-role-name shell) nil
            (xdg-surface-configured-p shell) nil
            (xdg-surface-acknowledged-p shell) nil
            (xdg-surface-configure-serial shell) nil
            (xdg-surface-pending-serials shell) nil
            (xdg-surface-mapped-p shell) nil))
    (setf (xdg-popup-shell-surface popup) nil
          (xdg-popup-parent popup) nil
          (xdg-popup-dismissed-p popup) t)))

(defmethod xdg-popup.destroy ((popup xdg-popup))
  "The client destroys its popup -- only the topmost one, per the XML."
  (unless (popup-topmost-p popup)
    (let* ((shell (xdg-popup-shell-surface popup))
           (wm-base (and shell (xdg-surface-wm-base shell))))
      (protocol-error (resource-client popup)
                      (if wm-base (resource-id wm-base) (resource-id popup))
                      +xdg-wm-base-error-not-the-topmost-popup+
                      "popup ~D is not the topmost popup of its toplevel"
                      (resource-id popup))))
  (destroy-resource popup))
