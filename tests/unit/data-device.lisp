;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The data device (D64): the global that decides whether a GTK client has a
;;;; keyboard, and the clipboard and drag protocol behind it.
;;;;
;;;; Why a GTK client needs it at all: GDK postpones its wl_seat bind until it has
;;;; seen both wl_compositor and wl_data_device_manager (gdk/wayland/
;;;; gdkdisplay-wayland.c, gdk_registry_handle_global: the seat is bound from a
;;;; postponed closure whose required globals are those two).  Measured before this
;;;; slice: Emacs bound wl_compositor, wl_shm, wl_output and xdg_wm_base against
;;;; cl-tinywl and issued zero wl_seat requests, so every keystroke went nowhere.
;;;;
;;;; The tests are wire-level, in the style of tests/unit/server.lisp, whose
;;;; fixtures they borrow: two raw connections, real messages, and the server's own
;;;; objects read through the object table where the wire alone cannot say what
;;;; happened.

(in-package #:cl-user)

(defpackage #:wayland.test.data-device
  (:use #:cl #:rove)
  (:local-nicknames (#:srv #:wayland.server)
                    (#:wire #:wayland.wire)
                    (#:io #:wayland.io)
                    (#:ffi #:wayland.ffi))
  (:import-from #:wayland.test.server
                #:with-display
                #:with-seat-display
                #:run-server
                #:raw-connect
                #:send-message
                #:read-events
                #:read-events-and-fds
                #:error-reply
                #:send-bind
                #:send-get-registry
                #:make-client-pool
                #:seat-of)
  (:documentation
   "Tests for wl_data_device_manager: sources, offers, the selection, and drags."))

(in-package #:wayland.test.data-device)

;;; ---------------------------------------------------------------------------
;;; Fixtures
;;; ---------------------------------------------------------------------------

(defmacro with-data-device-display ((display &key (capabilities 3)) &body body)
  "A display offering wl_shm (1), wl_compositor (2), wl_seat (3) and
wl_data_device_manager (4) -- the globals a GTK client asks for."
  `(with-seat-display (,display :capabilities ,capabilities)
     (srv:add-data-device-manager-global ,display)
     (locally ,@body)))

(defun bind-data-globals (display socket &key (seat-id 4) (manager-id 5))
  "get_registry (2), then wl_seat and wl_data_device_manager."
  (send-get-registry socket 2)
  (run-server display)
  (read-events socket)                          ; the five global announcements
  (send-bind socket 2 3 "wl_seat" 4 seat-id)
  (send-bind socket 2 4 "wl_data_device_manager" 3 manager-id)
  (run-server display)
  (read-events socket))                         ; name, capabilities

(defun get-data-device (display socket &key (manager-id 5) (seat-id 4) (device-id 6)
                                      (timeout 0.05))
  "wl_data_device_manager.get_data_device (opcode 1); returns the events it caused."
  (send-message socket manager-id 1
                (lambda (buffer)
                  (wire:put-new-id buffer device-id)
                  (wire:put-object buffer seat-id)))
  (run-server display)
  (read-events socket :timeout timeout))

(defun create-data-source (display socket &key (manager-id 5) (source-id 7)
                                        (mime-types '("text/plain")))
  "create_data_source (opcode 0), then one offer request per mime type."
  (send-message socket manager-id 0
                (lambda (buffer) (wire:put-new-id buffer source-id)))
  (dolist (mime-type mime-types)
    (send-message socket source-id 0
                  (lambda (buffer) (wire:put-string buffer mime-type))))
  (run-server display))

(defun set-device-selection (display socket &key (device-id 6) (source-id 7) serial)
  "wl_data_device.set_selection (opcode 1) with SOURCE-ID (NIL for none)."
  (send-message socket device-id 1
                (lambda (buffer)
                  (wire:put-object buffer source-id)
                  (wire:put-uint buffer serial)))
  (run-server display))

(defun start-device-drag (display socket &key (device-id 6) (source-id 7) serial
                                        (origin nil) (icon nil))
  "wl_data_device.start_drag (opcode 0)."
  (send-message socket device-id 0
                (lambda (buffer)
                  (wire:put-object buffer source-id)
                  (wire:put-object buffer origin)
                  (wire:put-object buffer icon)
                  (wire:put-uint buffer serial)))
  (run-server display))

(defun surface-object (display id)
  "The wl_surface resource with client-chosen id ID, whichever client owns it."
  (loop for client in (srv:display-clients display)
        for object = (wayland.object:object-table-ref
                      (srv:client-objects client) id)
        when (typep object 'srv:surface) return object))

(defun offer-of (events)
  "The offer id the first wl_data_device.data_offer in EVENTS names."
  (dolist (event events)
    (destructuring-bind (id opcode reader) event
      (declare (ignore id))
      (when (= 0 opcode)
        (return-from offer-of (wire:read-uint reader))))))

;;; ---------------------------------------------------------------------------
;;; The global
;;; ---------------------------------------------------------------------------

(deftest a-gtk-client-can-bind-the-seat-through-the-data-device-manager
  ;; The defect this slice answers: five globals and no data device manager meant
  ;; Emacs bound four of them and never wl_seat.
  (with-data-device-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display socket)
             (get-data-device display socket)
             (let* ((global (find "wl_data_device_manager" (srv:display-globals display)
                                  :key #'srv:global-interface :test #'string=))
                    (seat (seat-of display)))
               (ok global "the data device manager is a global")
               (ok (= 3 (srv:global-version global)) "advertised at version 3")
               (ok (equal (list 6)
                          (mapcar #'srv:resource-id (srv:seat-data-devices seat)))
                   "one wl_data_device, on the seat")
               (ok (null (srv:seat-selection seat)) "and no selection yet")))
        (ffi:close-fd socket)))))

(deftest a-data-device-needs-a-wl-seat-and-not-just-an-object
  (with-data-device-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display socket)
             ;; The manager is a perfectly valid object id, and not a seat.
             (send-message socket 5 1
                           (lambda (buffer)
                             (wire:put-new-id buffer 6)
                             (wire:put-object buffer 5)))
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 5 object-id) "the error names the manager")
               (ok (= code srv:+error-invalid-object+)
                   "wl_display.error.invalid_object")
               (ok (search "wl_seat" message)))
             (ok (null (srv:display-clients display)) "the client is disconnected"))
        (ffi:close-fd socket)))))

;;; ---------------------------------------------------------------------------
;;; The selection: one per seat, an offer per client
;;; ---------------------------------------------------------------------------

(deftest a-selection-reaches-the-other-client-as-an-offer
  (with-data-device-display (display)
    (let ((source-socket (raw-connect display))
          (target-socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display source-socket)
             (get-data-device display source-socket)
             (create-data-source display source-socket
                                 :mime-types '("text/plain" "text/uri-list"))
             (set-device-selection display source-socket
                                   :serial (srv:display-next-serial display))
             (let ((seat (seat-of display)))
               (ok (typep (srv:seat-selection seat) 'srv:data-source)
                   "the seat owns the selection")
               (ok (eq :selection (srv:data-source-purpose (srv:seat-selection seat)))
                   "and knows what it is being used for")
               (ok (srv:data-source-used-p (srv:seat-selection seat))))
             (ok (null (read-events source-socket :timeout 0.05))
                 "the client that set the selection is not told about it")
             (bind-data-globals display target-socket :seat-id 34 :manager-id 35)
             (let ((events (get-data-device display target-socket
                                            :manager-id 35 :seat-id 34
                                            :device-id 36)))
               (ok (= 5 (length events))
                   (format nil "data_offer, two offers, source_actions, selection, got ~D"
                           (length events)))
               (let ((offer (offer-of events)))
                 (ok (>= offer wayland.object:+first-server-id+)
                     "the offer's id is from the server's range")
                 (destructuring-bind ((id0 op0 r0) (id1 op1 r1) (id2 op2 r2)
                                      (id3 op3 r3) (id4 op4 r4))
                     events
                   (declare (ignore r0))
                   (ok (= 36 id0) "data_offer arrives on the new device")
                   (ok (= offer id1) "the object is named before any event about it")
                   (ok (= offer id2))
                   (ok (= offer id3))
                   (ok (= 0 op1) "wl_data_offer.offer is opcode 0")
                   (ok (string= "text/plain" (wire:read-string r1))
                       "the source's first mime type comes first")
                   (ok (string= "text/uri-list" (wire:read-string r2)))
                   (ok (= 1 op3) "wl_data_offer.source_actions is opcode 1")
                   (ok (= 3 (wire:read-uint r3)) "copy | move, the protocol's default")
                   (ok (= 36 id4) "selection arrives on the device")
                   (ok (= 5 op4) "wl_data_device.selection is opcode 5")
                   (ok (= offer (wire:read-uint r4)) "and names the same offer"))))
             (ok (null (read-events source-socket :timeout 0.05))
                 "nothing was said to the source either"))
        (ffi:close-fd source-socket)
        (ffi:close-fd target-socket)))))

(deftest accept-names-the-mime-type-and-receive-carries-a-descriptor
  (with-data-device-display (display)
    (let ((source-socket (raw-connect display))
          (target-socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display source-socket)
             (get-data-device display source-socket)
             (create-data-source display source-socket)
             (set-device-selection display source-socket
                                   :serial (srv:display-next-serial display))
             (bind-data-globals display target-socket :seat-id 34 :manager-id 35)
             (let ((offer (offer-of (get-data-device display target-socket
                                                     :manager-id 35 :seat-id 34
                                                     :device-id 36))))
               ;; accept (opcode 0): a serial, then the mime type.
               (send-message target-socket offer 0
                             (lambda (buffer)
                               (wire:put-uint buffer 0)
                               (wire:put-string buffer "text/plain")))
               (run-server display)
               (let ((events (read-events source-socket)))
                 (ok (= 1 (length events)))
                 (destructuring-bind (id opcode reader) (first events)
                   (ok (= 7 id) "the source hears the accept")
                   (ok (= 0 opcode) "wl_data_source.target is opcode 0")
                   (ok (string= "text/plain" (wire:read-string reader)))))
               ;; receive (opcode 1): a mime type and a descriptor, which must
               ;; cross from this client's connection to the source's.
               (multiple-value-bind (fd size) (make-client-pool 8 4 #xFF00FF00)
                 (declare (ignore size))
                 (unwind-protect
                      (progn
                        (let* ((buffer (wire:make-message-buffer))
                               (start (wire:begin-message buffer offer 1)))
                          (wire:put-string buffer "text/plain")
                          (wire:put-fd buffer fd)
                          (wire:end-message buffer start)
                          (io:flush-buffer target-socket buffer))
                        (run-server display)
                        (multiple-value-bind (messages fds)
                            (read-events-and-fds source-socket)
                          (ok (= 1 (length messages)))
                          (destructuring-bind (id opcode reader) (first messages)
                            (ok (= 7 id))
                            (ok (= 1 opcode) "wl_data_source.send is opcode 1")
                            (ok (string= "text/plain" (wire:read-string reader)))
                            (ok (= 1 (length fds))
                                "exactly one descriptor crossed between clients"))
                          (dolist (received fds) (ffi:close-fd received))))
                   (ffi:close-fd fd)))))
        (ffi:close-fd source-socket)
        (ffi:close-fd target-socket)))))

(deftest clearing-the-selection-is-a-null-offer
  (with-data-device-display (display)
    (let ((source-socket (raw-connect display))
          (target-socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display source-socket)
             (get-data-device display source-socket)
             (create-data-source display source-socket)
             (set-device-selection display source-socket
                                   :serial (srv:display-next-serial display))
             (bind-data-globals display target-socket :seat-id 34 :manager-id 35)
             (get-data-device display target-socket :manager-id 35 :seat-id 34
                              :device-id 36)
             (set-device-selection display source-socket :source-id nil
                                   :serial (srv:display-next-serial display))
             (ok (null (srv:seat-selection (seat-of display))) "the clipboard is empty")
             (let ((events (read-events target-socket)))
               (ok (= 1 (length events)) "one event: selection with a null id")
               (destructuring-bind (id opcode reader) (first events)
                 (ok (= 36 id))
                 (ok (= 5 opcode))
                 (ok (= 0 (wire:read-uint reader)) "nothing is offered"))))
        (ffi:close-fd source-socket)
        (ffi:close-fd target-socket)))))

(deftest a-source-used-twice-is-refused
  (with-data-device-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display socket)
             (get-data-device display socket)
             (create-data-source display socket)
             (set-device-selection display socket
                                   :serial (srv:display-next-serial display))
             (set-device-selection display socket
                                   :serial (srv:display-next-serial display))
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 6 object-id) "the error names the wl_data_device")
               (ok (= 1 code) "wl_data_device.error.used_source")
               (ok (search "already used" message))))
        (ffi:close-fd socket)))))

(deftest an-offer-after-use-is-invalid-source
  (with-data-device-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display socket)
             (get-data-device display socket)
             (create-data-source display socket)
             (set-device-selection display socket
                                   :serial (srv:display-next-serial display))
             (send-message socket 7 0
                           (lambda (buffer) (wire:put-string buffer "text/html")))
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 7 object-id) "the error names the wl_data_source")
               (ok (= 1 code) "wl_data_source.error.invalid_source")
               (ok (search "was used for a selection" message))))
        (ffi:close-fd socket)))))

(deftest an-unknown-drag-action-is-refused
  (with-data-device-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display socket)
             (get-data-device display socket)
             (create-data-source display socket)
             (send-message socket 7 2 (lambda (buffer) (wire:put-uint buffer #x8)))
             (run-server display)
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 7 object-id))
               (ok (= 0 code) "wl_data_source.error.invalid_action_mask")
               (ok (search "does not have" message))))
        (ffi:close-fd socket)))))

(deftest a-serial-this-display-never-issued-changes-nothing
  (with-data-device-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display socket)
             (get-data-device display socket)
             (create-data-source display socket)
             (set-device-selection display socket :serial 999999)
             (ok (null (srv:seat-selection (seat-of display)))
                 "a made-up serial puts nothing on the clipboard")
             (ok (= 1 (length (srv:display-clients display)))
                 "and it is not fatal either: the client is still connected"))
        (ffi:close-fd socket)))))

;;; ---------------------------------------------------------------------------
;;; The drag
;;; ---------------------------------------------------------------------------

(deftest a-drag-enters-the-surface-under-the-pointer-and-drops-on-it
  (with-data-device-display (display)
    (let ((source-socket (raw-connect display))
          (target-socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display source-socket)
             (get-data-device display source-socket)
             (create-data-source display source-socket)
             (bind-data-globals display target-socket :seat-id 34 :manager-id 35)
             (get-data-device display target-socket :manager-id 35 :seat-id 34
                              :device-id 36)
             ;; The target's window, which is what the drag crosses.
             (send-bind target-socket 2 2 "wl_compositor" 1 33)
             (send-message target-socket 33 0
                           (lambda (buffer) (wire:put-new-id buffer 31)))
             ;; start_drag's origin is the surface the drag started from and may
             ;; not be null; the icon may be, and this compositor draws no icon
             ;; (a surface with no role is not composited, D40).
             (send-bind source-socket 2 2 "wl_compositor" 1 32)
             (send-message source-socket 32 0
                           (lambda (buffer) (wire:put-new-id buffer 30)))
             (run-server display)
             (start-device-drag display source-socket :origin 30
                                :serial (srv:display-next-serial display))
             (let* ((seat (seat-of display))
                    (surface (surface-object display 31))
                    (offer nil))
               (ok (srv:data-drag-active-p seat) "the seat has a drag in flight")
               (ok (eq :entered (srv:update-data-drag seat surface 10 20))
                   "the pointer is over the target")
               (run-server display)
               (let ((events (read-events target-socket)))
                 (ok (= 4 (length events)) "data_offer, offer, source_actions, enter")
                 (setf offer (offer-of events))
                 (ok (>= offer wayland.object:+first-server-id+))
                 (destructuring-bind ((id0 op0 r0) (id1 op1 r1) (id2 op2 r2)
                                      (id3 op3 r3))
                     events
                   (declare (ignore op0 r0 op1 op2))
                   (ok (= 36 id0))
                   (ok (= offer id1) "the offer is named before any event about it")
                   (ok (= offer id2))
                   (ok (string= "text/plain" (wire:read-string r1)))
                   (ok (= 3 (wire:read-uint r2)) "source_actions: copy | move")
                   (ok (= 1 op3) "wl_data_device.enter is opcode 1")
                   (ok (plusp (wire:read-uint r3)) "enter carries a serial")
                   (ok (= 31 (wire:read-uint r3)) "and the surface under the pointer")
                   (ok (= 10 (wire:read-fixed r3)) "x, in surface coordinates")
                   (ok (= 20 (wire:read-fixed r3)) "y")
                   (ok (= offer (wire:read-uint r3)) "and the offer itself")))
               ;; A motion inside the same target is a motion, not another enter.
               (ok (eq :motion (srv:update-data-drag seat surface 11 21)))
               (run-server display)
               (let ((events (read-events target-socket)))
                 (ok (= 1 (length events)))
                 (destructuring-bind (id opcode reader) (first events)
                   (ok (= 36 id))
                   (ok (= 3 opcode) "wl_data_device.motion")
                   (let ((time (wire:read-uint reader)))     ; the event's time
                     (declare (ignore time)))
                   (ok (= 11 (wire:read-fixed reader)))
                   (ok (= 21 (wire:read-fixed reader)))))
               ;; The drop: the target hears it, the source hears that a drop
               ;; happened -- and nothing about finishing, because the target has
               ;; not read anything yet (a move must not be licensed to delete).
               (ok (eq :dropped (srv:finish-data-drag seat)))
               (run-server display)
               (let ((events (read-events target-socket)))
                 (ok (= 1 (length events)))
                 (destructuring-bind (id opcode reader) (first events)
                   (declare (ignore reader))
                   (ok (= 36 id))
                   (ok (= 4 opcode) "wl_data_device.drop")))
               (let ((events (read-events source-socket)))
                 (ok (= 1 (length events)))
                 (destructuring-bind (id opcode reader) (first events)
                   (declare (ignore reader))
                   (ok (= 7 id))
                   (ok (= 3 opcode) "wl_data_source.dnd_drop_performed")))
               ;; finish (opcode 3) is the target saying it has the data.
               (send-message target-socket offer 3
                             (lambda (buffer) (declare (ignore buffer))))
               (run-server display)
               (let ((target-events (read-events target-socket))
                     (source-events (read-events source-socket)))
                 (destructuring-bind (id opcode reader) (first target-events)
                   (declare (ignore id))
                   (ok (= 2 opcode) "wl_data_offer.action is opcode 2")
                   (ok (= 1 (wire:read-uint reader)) "copy, by default"))
                 (destructuring-bind (id opcode reader) (first source-events)
                   (declare (ignore id))
                   (ok (= 5 opcode) "wl_data_source.action is opcode 5")
                   (ok (= 1 (wire:read-uint reader)) "copy, by default"))
                 (destructuring-bind (id opcode reader) (second source-events)
                   (declare (ignore id reader))
                   (ok (= 4 opcode) "wl_data_source.dnd_finished is opcode 4"))))
        (ffi:close-fd source-socket)
        (ffi:close-fd target-socket))))))

(deftest a-drag-that-crosses-nothing-cancels-the-source
  (with-data-device-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display socket)
             (get-data-device display socket)
             (create-data-source display socket)
             (send-bind socket 2 2 "wl_compositor" 1 32)
             (send-message socket 32 0
                           (lambda (buffer) (wire:put-new-id buffer 30)))
             (run-server display)
             (start-device-drag display socket :origin 30
                                :serial (srv:display-next-serial display))
             (let ((seat (seat-of display)))
               (ok (srv:data-drag-active-p seat))
               (ok (eq :cancelled (srv:finish-data-drag seat))
                   "a drop on the bare output drops nothing")
               (ok (not (srv:data-drag-active-p seat)) "and the drag is over")
               (run-server display))
             (let ((events (read-events socket)))
               (ok (= 1 (length events)))
               (destructuring-bind (id opcode reader) (first events)
                 (declare (ignore reader))
                 (ok (= 7 id))
                 (ok (= 2 opcode) "wl_data_source.cancelled is opcode 2"))))
        (ffi:close-fd socket)))))

(deftest an-object-that-is-not-a-source-is-refused-not-crashed-into
  ;; The dispatcher resolves an object argument to a resource but does not check
  ;; its interface, so this reaches set_selection as a wl_surface: an internal
  ;; error would escape into the loop, a protocol error is the right answer.
  (with-data-device-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display socket)
             (get-data-device display socket)
             (send-bind socket 2 2 "wl_compositor" 1 33)
             (send-message socket 33 0 (lambda (buffer) (wire:put-new-id buffer 30)))
             (set-device-selection display socket :source-id 30
                                   :serial (srv:display-next-serial display))
             (destructuring-bind (object-id code message)
                 (error-reply (read-events socket))
               (ok (= 6 object-id) "the error names the wl_data_device")
               (ok (= code srv:+error-invalid-object+))
               (ok (search "needs a wl_data_source" message)))
             (ok (null (srv:display-clients display)) "the client is disconnected"))
        (ffi:close-fd socket)))))

(deftest clearing-the-clipboard-needs-no-serial
  (with-data-device-display (display)
    (let ((socket (raw-connect display)))
      (unwind-protect
           (progn
             (bind-data-globals display socket)
             (get-data-device display socket)
             (create-data-source display socket)
             (set-device-selection display socket
                                   :serial (srv:display-next-serial display))
             (ok (srv:seat-selection (seat-of display)) "there is something to clear")
             (set-device-selection display socket :source-id nil :serial 999999)
             (ok (null (srv:seat-selection (seat-of display)))
                 "an expired serial still clears the clipboard")
             (ok (= 1 (length (srv:display-clients display))) "and the client lives"))
        (ffi:close-fd socket)))))
