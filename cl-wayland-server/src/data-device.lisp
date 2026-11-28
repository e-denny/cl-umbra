;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The data device: the clipboard, and drag-and-drop (D64).
;;;;
;;;; This module exists because a compositor without wl_data_device_manager is a
;;;; compositor no GTK application can type into: GDK postpones its wl_seat bind
;;;; until it has seen both wl_compositor and wl_data_device_manager
;;;; (gdk/wayland/gdkdisplay-wayland.c, gdk_registry_handle_global: the seat is
;;;; bound by a postponed closure whose required globals are those two), so a
;;;; missing data device manager costs every GTK client its keyboard and pointer,
;;;; not just its clipboard.  That is the defect this file answers.
;;;;
;;;; The shape is four objects and one state that is not an object:
;;;;
;;;;   wl_data_device_manager  the global; stateless.
;;;;   wl_data_source          what a client offers -- mime types, and the events
;;;;                           that ask it to write one (send) or tell it the offer
;;;;                           died (cancelled).
;;;;   wl_data_offer           what another client sees.  The bridge: two clients
;;;;                           must never name each other, so the offer holds the
;;;;                           source and forwards receive as send.
;;;;   wl_data_device          a client's handle on one seat: selection for copies,
;;;;                           enter/motion/drop/leave for drags.
;;;;
;;;; The state is the seat's, for the same reason focus is: "what the user copied"
;;;; is one answer per seat, and every client's device hears it change.
;;;;
;;;; What a *compositor* supplies, and what is therefore a hook here:
;;;;
;;;;   * which surface is under the pointer during a drag (UPDATE-DATA-DRAG),
;;;;   * when the button comes up or the drag is abandoned (FINISH-DATA-DRAG,
;;;;     CANCEL-DATA-DRAG).
;;;;
;;;; The icon surface is recorded and not drawn: a surface with no shell role is
;;;; not composited (D40), and dragging draws the pointer, not a second surface.
;;;; That is the one visible difference from wlroots, and it changes nothing about
;;;; whether a drop is delivered.

(in-package #:wayland.server)

(defconstant +data-device-manager-version+ 3
  "The newest wl_data_device_manager whose every request this implements.

v3 is where drag-and-drop actions arrive (set_actions, source_actions, action,
dnd_drop_performed, dnd_finished, finish); v4 adds one request, `release' on the
manager, which creates nothing and frees nothing a v3 client cannot free by
disconnecting.  A v3 advertisement is also what GDK binds (MIN (version, 3)).")

;;; ---------------------------------------------------------------------------
;;; The global
;;; ---------------------------------------------------------------------------

(defun add-data-device-manager-global
    (display &key (version +data-device-manager-version+))
  "Register wl_data_device_manager on DISPLAY at VERSION; returns the GLOBAL.

Every compositor needs this global before a GTK client can use its seat (see this
file's header), so it is published by MAKE-HEADLESS-COMPOSITOR beside wl_seat."
  (add-global display
              :interface "wl_data_device_manager"
              :version version
              :resource-class 'data-device-manager
              :bind (lambda (resource) resource)))

;;; ---------------------------------------------------------------------------
;;; wl_data_device_manager: the three requests
;;; ---------------------------------------------------------------------------

(defmethod wl-data-device-manager.create-data-source
    ((manager data-device-manager))
  "A wl_data_source this client will fill with mime types and then offer."
  (allocate-resource (resource-client manager)
                     (resolve-interface "wl_data_source")
                     :version (resource-version manager)
                     :class 'data-source
                     :destroy-function #'destroy-data-source))

(defmethod wl-data-device-manager.get-data-device
    ((manager data-device-manager) seat)
  "A wl_data_device for SEAT, which must be a wl_seat this client bound.

A device created after a selection exists is told about it at once: the protocol
says the selection is state the client missed, not an event it will be sent."
  (let ((client (resource-client manager)))
    (unless (typep seat 'seat-resource)
      (protocol-error client (resource-id manager) +error-invalid-object+
                      "get_data_device needs a wl_seat object, not ~S"
                      (and seat (resource-interface seat))))
    (unless (eq client (resource-client seat))
      (protocol-error client (resource-id manager) +error-invalid-object+
                      "that wl_seat belongs to another connection"))
    (let* ((the-seat (seat-resource-seat seat))
           (device (allocate-resource client
                                      (resolve-interface "wl_data_device")
                                      :version (resource-version manager)
                                      :class 'data-device
                                      :destroy-function #'destroy-data-device)))
      (setf (data-device-seat device) the-seat)
      (push device (seat-data-devices the-seat))
      (log-message :debug "client ~D: wl_data_device ~D for seat ~A"
                   (client-id client) (resource-id device) (seat-name the-seat))
      (when (seat-selection the-seat)
        (send-selection-to device (seat-selection the-seat)))
      device)))

(defun check-data-source (client object-id source what)
  "SOURCE must be a wl_data_source this client made, or NIL when allowed.

The dispatcher resolves an object argument to *a* resource but does not check its
interface (dispatch.lisp), so a client that names its wl_shm where a source is
expected would otherwise reach a method specialised on a class it is not -- an
internal error escaping into the loop instead of a protocol error."
  (cond
    ((null source) nil)
    ((not (typep source 'data-source))
     (protocol-error client object-id +error-invalid-object+
                     "~A needs a wl_data_source, not a ~A"
                     what (interface-name (resource-interface source))))
    ((not (eq client (resource-client source)))
     (protocol-error client object-id +error-invalid-object+
                     "~A names a wl_data_source from another connection" what))
    (t source)))

;;; ---------------------------------------------------------------------------
;;; wl_data_source: what one client offers
;;; ---------------------------------------------------------------------------

(defmethod wl-data-source.offer ((source data-source) mime-type)
  "Add MIME-TYPE to what SOURCE offers.  Newest first, as the protocol orders it."
  (when (and (data-source-used-p source) (data-source-purpose source))
    (protocol-error (resource-client source) (resource-id source)
                    +wl-data-source-error-invalid-source+
                    "offer after the source was used for a ~(~A~)"
                    (data-source-purpose source)))
  (pushnew mime-type (data-source-mime-types source) :test #'string=)
  mime-type)

(defmethod wl-data-source.set-actions ((source data-source) actions)
  "Record the drag-and-drop actions SOURCE accepts (v3).

An unknown bit is `invalid_action_mask', because a compositor that guessed would
be promising an action the source never agreed to."
  (let ((known (logior +wl-data-device-manager-dnd-action-copy+
                       +wl-data-device-manager-dnd-action-move+
                       +wl-data-device-manager-dnd-action-ask+)))
    (unless (zerop (logandc2 actions known))
      (protocol-error (resource-client source) (resource-id source)
                      +wl-data-source-error-invalid-action-mask+
                      "actions #x~X name a flag this protocol does not have"
                      actions)))
  (setf (data-source-actions source) actions)
  actions)

(defmethod wl-data-source.destroy ((source data-source))
  (destroy-resource source))

(defun destroy-data-source (source)
  "Undo exactly what SOURCE was used for: a selection, or a drag.

A source cannot be both, because it is used once (D64).  Clearing a selection is
told to every device that had it -- `selection' with a null id is the protocol's
way of saying the clipboard is empty."
  (let ((seat (data-source-seat source)))
    (when seat
      (ecase (data-source-purpose source)
        (:selection
         (when (eq (seat-selection seat) source)
           (setf (seat-selection seat) nil)
           (dolist (device (seat-data-devices seat))
             (wl-data-device.selection device nil))))
        (:drag
         (let ((drag (seat-drag seat)))
           (when (and drag (eq (data-drag-source drag) source))
             (cancel-data-drag seat)))))))
  (log-message :debug "client ~D: wl_data_source ~D destroyed"
               (client-id (resource-client source)) (resource-id source)))

;;; ---------------------------------------------------------------------------
;;; wl_data_device: the selection
;;; ---------------------------------------------------------------------------

(defmethod wl-data-device.set-selection ((device data-device) source serial)
  "Make SOURCE this seat's selection, or clear it when SOURCE is null.

A serial that this display did not issue is ignored rather than fatal: the
protocol defines no error for it, GTK sends the serial of the key or button event
that asked for the copy, and killing a client because a number expired is a worse
answer than a clipboard that did not change (D33 validates serials where the
protocol makes them meaningful -- grabs, popups -- and this is not one of those).
A selection set during a drag is ignored: the drag owns the clipboard until it
ends."
  (let ((seat (data-device-seat device)))
    (check-data-source (resource-client device) (resource-id device) source
                       "wl_data_device.set_selection")
    (cond
      ((seat-drag seat)
       (log-message :info "client ~D: set_selection during a drag, ignored"
                    (client-id (resource-client device))))
      ((and source (data-source-used-p source))
       (protocol-error (resource-client device) (resource-id device)
                       +wl-data-device-error-used-source+
                       "that wl_data_source was already used"))
      ;; Clearing is always allowed, whatever the serial says: a clipboard that
      ;; cannot be emptied because a number expired is worse than a stale one.
      ((and (null source) (not (valid-serial-p seat serial)))
       (log-message :info "client ~D: clearing the selection with serial ~D, not ours"
                    (client-id (resource-client device)) serial)
       (set-seat-selection seat nil))
      ((not (valid-serial-p seat serial))
       (log-message :info "client ~D: set_selection with serial ~D was not ours, ignored"
                    (client-id (resource-client device)) serial))
      (t
       (when source
         (setf (data-source-used-p source) t
               (data-source-purpose source) :selection
               (data-source-seat source) seat))
       (set-seat-selection seat source)))))

(defun set-seat-selection (seat source)
  "Make SOURCE the seat's selection and tell every device that has not got it.

The device whose client owns SOURCE is not told: a client already knows what it
put on the clipboard, and GTK reads a `selection' naming its own source as `the
selection went away'."
  (setf (seat-selection seat) source)
  (dolist (device (seat-data-devices seat))
    (send-selection-to device source))
  source)

(defun send-selection-to (device source)
  "Tell DEVICE what the selection is now: an offer, then `selection'.

SOURCE nil means the clipboard is empty, which is one event with a null id and no
offer at all."
  (cond
    ((null source)
     (wl-data-device.selection device nil))
    ((eq (resource-client device) (resource-client source))
     ;; Its own source: the protocol says nothing is sent, and sending it would
     ;; make GTK believe somebody else took the selection.
     nil)
    (t
     (let ((offer (make-data-offer device source :drag-p nil)))
       (announce-data-offer device offer)
       (wl-data-device.selection device offer)
       offer))))

;;; ---------------------------------------------------------------------------
;;; Offers: the bridge between two clients
;;; ---------------------------------------------------------------------------

(defun make-data-offer (device source &key drag-p)
  "A wl_data_offer for DEVICE over SOURCE: the object, before anyone hears of it.

The id is from the *server's* range: the target never asked for this object, so it
learns it from data_offer and must not recycle the id until delete_id (which the
server's range makes impossible by construction)."
  (let* ((client (resource-client device))
         (offer (make-resource client
                               (allocate-server-id (client-objects client))
                               (resolve-interface "wl_data_offer")
                               :version (min +data-device-manager-version+
                                             (resource-version device))
                               :class 'data-offer
                               :destroy-function #'destroy-data-offer)))
    (setf (data-offer-source offer) source
          (data-offer-device offer) device
          (data-offer-drag-p offer) drag-p
          (data-offer-mime-types offer) (reverse (data-source-mime-types source))
          (data-offer-source-actions offer) (or (data-source-actions source) 0))
    offer))

(defun announce-data-offer (device offer)
  "Name OFFER to its client, and only then send the mime types.

The order is the protocol's and it is not cosmetic: an event about an object the
client has never been told about is an event on an id it cannot resolve, so
data_offer comes first and every offer/source_actions after it."
  (wl-data-device.data-offer device offer)
  (dolist (mime-type (data-offer-mime-types offer))
    (wl-data-offer.offer offer mime-type))
  (when (>= (resource-version offer) 3)
    (wl-data-offer.source-actions offer (data-offer-source-actions offer)))
  offer)

(defmethod wl-data-offer.accept ((offer data-offer) serial mime-type)
  "The target wants MIME-TYPE; tell the source, which is what `target' means.

The serial is deliberately unused: the protocol asks for one so that a stale
accept cannot be replayed, but neither GTK nor weston's clients ever pass a serial
they did not just receive, and there is no error code to refuse it with."
  (declare (ignore serial))
  (when (member mime-type (data-offer-mime-types offer) :test #'string=)
    (setf (data-offer-accepted-p offer) t
          (data-offer-accepted-mime offer) mime-type)
    (let ((source (data-offer-source offer)))
      (when (and source (not (resource-destroyed-p source)))
        (wl-data-source.target source mime-type))))
  mime-type)

(defmethod wl-data-offer.receive ((offer data-offer) mime-type fd)
  "Forward the descriptor to the source client as wl_data_source.send.

This is the one place a descriptor crosses between two clients' connections: the
descriptor arrives on the target's connection, is queued on the source's output
buffer, and is closed once SCM_RIGHTS has carried it (the same ownership rule
wl_keyboard.keymap follows).  A source that is already gone gets the descriptor
closed here instead, so a dead client cannot leak one per receive."
  (let ((source (data-offer-source offer)))
    (if (and source (not (resource-destroyed-p source))
             (member mime-type (data-offer-mime-types offer) :test #'string=))
        (wl-data-source.send source mime-type fd)
        (when (and fd (not (minusp fd)))
          (close-fd fd))))
  t)

(defmethod wl-data-offer.destroy ((offer data-offer))
  (destroy-resource offer))

(defmethod wl-data-offer.finish ((offer data-offer))
  "The target is done reading a dropped drag: finish the source's side.

`finish' on a selection's offer is `invalid_finish': only a drag ends this way."
  (unless (data-offer-drag-p offer)
    (protocol-error (resource-client offer) (resource-id offer)
                    +wl-data-offer-error-invalid-finish+
                    "finish is only for a drag-and-drop offer"))
  (setf (data-offer-finished-p offer) t)
  (finish-drag-offer offer)
  t)

(defmethod wl-data-offer.set-actions ((offer data-offer) actions preferred-action)
  "Record which action the target would accept, and check the mask.

The negotiated action is reported at the drop (wl_data_offer.action): copy unless
the target asked for move and the source allows it, because a wrong `move' tells a
file manager to delete the original."
  (let ((known (logior +wl-data-device-manager-dnd-action-copy+
                       +wl-data-device-manager-dnd-action-move+
                       +wl-data-device-manager-dnd-action-ask+)))
    (unless (zerop (logandc2 actions known))
      (protocol-error (resource-client offer) (resource-id offer)
                      +wl-data-offer-error-invalid-action-mask+
                      "actions #x~X name a flag this protocol does not have"
                      actions))
    (unless (zerop (logandc2 preferred-action
                            (logior +wl-data-device-manager-dnd-action-copy+
                                    +wl-data-device-manager-dnd-action-move+
                                    +wl-data-device-manager-dnd-action-ask+)))
      (protocol-error (resource-client offer) (resource-id offer)
                      +wl-data-offer-error-invalid-action+
                      "#x~X is not one action" preferred-action)))
  (setf (data-offer-actions offer) actions
        (data-offer-preferred-action offer) preferred-action)
  t)

(defun destroy-data-offer (offer)
  "Drop OFFER, and finish the source's side if this was a drag's offer.

A target that reads nothing destroys the offer without calling finish; the source
must still hear `dnd_finished', or a move would leave it waiting for a licence to
delete that never comes."
  (when (and (data-offer-drag-p offer)
             (not (data-offer-finished-p offer)))
    (setf (data-offer-finished-p offer) t)
    (finish-drag-offer offer))
  (let ((drag (and (data-offer-drag-p offer)
                   (data-drag-for-offer offer))))
    (when (and drag (eq (data-drag-offer drag) offer))
      (setf (data-drag-offer drag) nil)))
  (log-message :debug "client ~D: wl_data_offer ~D destroyed"
               (client-id (resource-client offer)) (resource-id offer)))

;;; ---------------------------------------------------------------------------
;;; Drag and drop
;;; ---------------------------------------------------------------------------

(defgeneric data-device-drag-started (seat drag)
  (:documentation
   "A drag began on SEAT.  A compositor uses this to take the pointer: from here
until FINISH-DATA-DRAG or CANCEL-DATA-DRAG, wl_pointer events belong to the drag
and the icon follows the pointer.")
  (:method (seat drag)
    (declare (ignore seat drag))
    nil))

(defgeneric data-device-drag-ended (seat drag)
  (:documentation
   "The drag on SEAT ended, by a drop or a cancel.  The default does nothing.")
  (:method (seat drag)
    (declare (ignore seat drag))
    nil))

(defun data-drag-active-p (seat)
  "Is a drag in flight on SEAT?"
  (and (seat-drag seat) t))

(defun data-device-for-client (seat client)
  "The client's wl_data_device on SEAT, or NIL when it never asked for one."
  (find client (seat-data-devices seat) :key #'resource-client))

(defmethod wl-data-device.start-drag ((device data-device) source origin icon serial)
  "Begin a drag from DEVICE, offering SOURCE's mime types to whatever it crosses.

A serial this display did not issue cancels the drag before it starts: the source
is told `cancelled' and nothing else happens.  A source already used for something
is `used_source' -- the protocol's own error, because a source that was a
selection and then a drag would tell the client two different stories about one
object."
  (let ((seat (data-device-seat device)))
    (check-data-source (resource-client device) (resource-id device) source
                       "wl_data_device.start_drag")
    (cond
      ((and source (data-source-used-p source))
       (protocol-error (resource-client device) (resource-id device)
                       +wl-data-device-error-used-source+
                       "that wl_data_source was already used"))
      ((not (valid-serial-p seat serial))
       (log-message :info "client ~D: start_drag with serial ~D was not ours, cancelled"
                    (client-id (resource-client device)) serial)
       (when source (wl-data-source.cancelled source))
       nil)
      (t
       (begin-data-drag device source origin icon serial)))))

(defun begin-data-drag (device source origin icon serial)
  "Create the drag, replacing any drag already in flight on the seat."
  (let ((seat (data-device-seat device)))
    (when (seat-drag seat)
      (cancel-data-drag seat))
    (when source
      (setf (data-source-used-p source) t
            (data-source-purpose source) :drag
            (data-source-seat source) seat))
    (let ((drag (make-instance 'data-drag
                               :seat seat :device device :source source
                               :origin origin :icon icon :serial serial)))
      (setf (seat-drag seat) drag)
      (log-message :info "seat ~A: drag started by client ~D with ~D mime type~:P"
                   (seat-name seat) (client-id (resource-client device))
                   (if source (length (data-source-mime-types source)) 0))
      (data-device-drag-started seat drag)
      drag)))

(defun update-data-drag (seat surface x y &key (time (seat-time)))
  "The pointer is over SURFACE at (X, Y) during a drag.

Called by the compositor's pointer path instead of set-pointer-focus: while a drag
is in flight no client hears wl_pointer, and the surface under the pointer hears
wl_data_device instead.  SURFACE NIL is the bare output: the drag has no target
there and the last one hears `leave'."
  (let ((drag (seat-drag seat)))
    (when drag
      (setf (data-drag-x drag) x
            (data-drag-y drag) y)
      (cond
        ((null surface)
         (leave-drag-target drag)
         :left)
        ((eq surface (data-drag-target drag))
         (let ((device (data-drag-target-device drag)))
           (when device
             (wl-data-device.motion device time x y)))
         :motion)
        (t
         (leave-drag-target drag)
         (if (enter-drag-target drag surface x y)
             :entered
             :no-target))))))

(defun enter-drag-target (drag surface x y)
  "Offer the drag to SURFACE's client: an offer, then `enter'."
  (let* ((seat (data-drag-seat drag))
         (device (data-device-for-client seat (resource-client surface)))
         (source (data-drag-source drag))
         (offer (and source device
                     (make-data-offer device source :drag-p t))))
    (unless device
      (return-from enter-drag-target nil))
    (when offer
      (announce-data-offer device offer))
    (wl-data-device.enter device (display-next-serial (seat-display seat))
                          surface x y offer)
    (setf (data-drag-target drag) surface
          (data-drag-target-device drag) device
          (data-drag-offer drag) offer)
    (log-message :debug "seat ~A: drag over surface ~D"
                 (seat-name seat) (resource-id surface))
    t))

(defun leave-drag-target (drag)
  "The pointer left the drag's target: `leave', and the offer stays for the drop."
  (let ((device (data-drag-target-device drag)))
    (when device
      (wl-data-device.leave device)))
  (setf (data-drag-target drag) nil
        (data-drag-target-device drag) nil
        (data-drag-offer drag) nil)
  nil)

(defun finish-data-drag (seat)
  "The button came up: drop on the target, or cancel if there is none.

Order is the protocol's: the target hears `drop' first (it may call accept/receive
while handling it), the source hears `dnd_drop_performed' and then -- when the
target finishes reading -- `action' and `dnd_finished'.  `drop' carries no time of
its own; the motion before it did."
  (let* ((drag (seat-drag seat))
         (device (and drag (data-drag-target-device drag)))
         (offer (and drag (data-drag-offer drag)))
         (source (and drag (data-drag-source drag))))
    (when drag
      (let ((outcome
              (cond
                ((and device offer)
         (wl-data-device.drop device)
         (when source
           (wl-data-source.dnd-drop-performed source))
                 ;; The source is *not* finished here: the target has been told
                 ;; to drop and has not read a byte yet, and `dnd_finished' is
                 ;; what licenses a move's delete.  It follows from
                 ;; wl_data_offer.finish -- or from the offer being destroyed,
                 ;; which is what a target that wanted nothing does.
                 :dropped)
                (t
                 (when device
                   (wl-data-device.leave device))
                 (when source
                   (wl-data-source.cancelled source))
                 :cancelled))))
        (clear-data-drag seat)
        outcome))))

(defun cancel-data-drag (seat)
  "Abandon the drag: the source hears `cancelled', the target `leave'."
  (let ((drag (seat-drag seat)))
    (when drag
      (leave-drag-target drag)
      (let ((source (data-drag-source drag)))
        (when source
          (wl-data-source.cancelled source)))
      (clear-data-drag seat)
      (log-message :info "seat ~A: drag cancelled" (seat-name seat)))))

(defun clear-data-drag (seat)
  "Forget the drag on SEAT and tell a compositor it ended.

The offer outlives the drag by one round trip: the client destroys it after
`finish', and destroying it here would make that request an invalid_object.  A
source used for a drag is spent either way."
  (let ((drag (seat-drag seat)))
    (when drag
      (let ((source (data-drag-source drag)))
        (when source
          (setf (data-source-seat source) nil
                (data-source-purpose source) nil)))
      (setf (seat-drag seat) nil)
      (data-device-drag-ended seat drag))))

(defun data-drag-for-offer (offer)
  "The drag OFFER belongs to, if it is still in flight."
  (let ((device (data-offer-device offer)))
    (and device
         (let* ((seat (data-device-seat device))
                (drag (seat-drag seat)))
           (and drag (eq (data-drag-offer drag) offer) drag)))))

(defun finish-drag-offer (offer)
  "Report the negotiated action to both sides, once.

wl_data_offer.action goes to the target, wl_data_source.action to the source, and
`dnd_finished' tells the source the drag is over and it may forget the data."
  (let ((source (data-offer-source offer))
        (action (negotiated-action offer)))
    (setf (data-offer-finished-p offer) t)
    (when (>= (resource-version offer) 3)
      (wl-data-offer.action offer action))
    (when (and source (not (resource-destroyed-p source)))
      (when (>= (resource-version source) 3)
        (wl-data-source.action source action)
        (wl-data-source.dnd-finished source)))))

(defun negotiated-action (offer)
  "What the drop did: the target's preference if the source allows it, else copy.

A client that never called set_actions is offered the copy and move the protocol
describes as the default, so a v1 or v2 target still gets a sensible answer."
  (let ((allowed (logand (or (data-offer-actions offer)
                             (logior +wl-data-device-manager-dnd-action-copy+
                                     +wl-data-device-manager-dnd-action-move+))
                         (data-offer-source-actions offer)))
        (preferred (or (data-offer-preferred-action offer) 0)))
    (cond
      ((and (plusp preferred) (plusp (logand preferred allowed))) preferred)
      ((plusp (logand +wl-data-device-manager-dnd-action-copy+ allowed))
       +wl-data-device-manager-dnd-action-copy+)
      ((plusp (logand +wl-data-device-manager-dnd-action-move+ allowed))
       +wl-data-device-manager-dnd-action-move+)
      (t +wl-data-device-manager-dnd-action-none+))))

;;; ---------------------------------------------------------------------------
;;; wl_data_device: release, and the device leaving
;;; ---------------------------------------------------------------------------

(defmethod wl-data-device.release ((device data-device))
  (destroy-resource device))

(defun destroy-data-device (device)
  "Forget DEVICE; a drag it started or was the target of is cancelled."
  (let ((seat (data-device-seat device)))
    (when seat
      (setf (seat-data-devices seat) (remove device (seat-data-devices seat)))
      (let ((drag (seat-drag seat)))
        (when (and drag
                   (or (eq (data-drag-device drag) device)
                       (eq (data-drag-target-device drag) device)))
          (cancel-data-drag seat))))
    (log-message :debug "client ~D: wl_data_device ~D destroyed"
                 (client-id (resource-client device)) (resource-id device))))
