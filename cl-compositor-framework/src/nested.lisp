;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The nested backend: our compositor as a client of another compositor.
;;;; (docs/framework.md §2, docs/roadmap.md phase 3.)
;;;;
;;;; There is no new rendering here.  A nested session is a HEADLESS-COMPOSITOR --
;;;; same display, same scene, same seat -- whose frame destination is a wl_shm
;;;; buffer in a parent compositor instead of a target of its own, and whose input
;;;; devices are the parent's wl_pointer and wl_keyboard instead of a test's
;;;; INJECT-* calls.  Two function slots on the compositor (compositor-frame-preparer
;;;; and compositor-frame-presenter) are the whole seam, which is why this file can
;;;; live outside cf.backend.headless and the headless backend never learns that a
;;;; parent exists.
;;;;
;;;; What the parent sees is an ordinary toplevel: an xdg_surface with a title and
;;;; an app_id, double-buffered shm buffers attached and committed, and a frame
;;;; callback requested per commit.  What the nested compositor sees is its own
;;;; display on its own socket, with clients of its own -- the two are the same
;;;; process and still two separate protocol endpoints.
;;;;
;;;; Input crosses in the other direction: a parent pointer motion becomes
;;;; CF:INJECT-POINTER-MOTION in our output space, and a parent key becomes
;;;; CF:INJECT-KEY after its evdev code is translated back to a key name.  Modifier
;;;; state is recomputed from our own key table rather than copied from the parent's
;;;; masks, because the masks belong to the parent's keymap and our clients are sent
;;;; ours.
;;;;
;;;; v0 limits, stated so they are not mistaken for bugs:
;;;;   * the nested output's size is fixed at start; a parent configure offering a
;;;;     different size is accepted and ignored (a client may choose its own size)
;;;;   * two shm buffers, no more: a frame that finds no free buffer is deferred
;;;;     until the parent releases one
;;;;   * the two reactors are polled, not merged into one epoll set
;;;;   * only the toplevel role is created; no popups, no decoration negotiation

(in-package #:cf.backend.nested)

;;; ---------------------------------------------------------------------------
;;; State
;;; ---------------------------------------------------------------------------

(defstruct (buffer-slot (:constructor make-buffer-slot))
  (buffer nil)                    ; wayland.client:client-buffer
  (target nil)                    ; pixman target over the buffer's pixels
  (free-p t))

(defclass nested-backend ()
  ((display :initarg :display :reader nested-display)
   (compositor :initarg :compositor :reader nested-compositor)
   (width :initarg :width :reader nested-width)
   (height :initarg :height :reader nested-height)
   (parent-compositor :initform nil :accessor nested-parent-compositor)
   (surface :initform nil :accessor nested-surface)
   (shm :initform nil :accessor nested-shm)
   (seat :initarg :seat :initform nil :accessor nested-seat)
   (seat-name :initform nil :accessor nested-seat-name)
   (pointer :initform nil :accessor nested-pointer)
   (keyboard :initform nil :accessor nested-keyboard)
   (wm-base :initform nil :accessor nested-wm-base)
   (xdg-surface :initform nil :accessor nested-xdg-surface)
   (toplevel :initform nil :accessor nested-toplevel)
   (pool :initform nil :accessor nested-pool)
   (buffers :initform nil :accessor nested-buffers)
   (current :initform nil :accessor nested-current)
   (configure-serial :initform nil :accessor nested-configure-serial)
   (configured-p :initform nil :accessor nested-configured-p)
   (mapped-p :initform nil :accessor nested-mapped-p)
   (awaiting-frame-p :initform nil :accessor nested-awaiting-frame-p)
   (closing-p :initform nil :accessor nested-closing-p)
   ;; An optional hook that lets the *parent's own* reactor run: it takes a timeout
   ;; in seconds.  It is NIL in the ordinary case (the parent is another process, so
   ;; our socket read is all the waiting there is); the in-process gate passes one
   ;; that runs the parent compositor's reactor.  Dispatching our own connection is
   ;; this package's job and happens whether a pump is set or not.
   (pump :initarg :pump :initform nil :accessor nested-pump)
   ;; Evidence a gate can read without guessing (all counted, never inferred).
   (frame-count :initform 0 :accessor nested-frame-count)
   (pointer-event-count :initform 0 :accessor nested-pointer-event-count)
   (key-count :initform 0 :accessor nested-key-count)
   (parent-keymap-size :initform 0 :accessor nested-parent-keymap-size))
  (:documentation
   "A nested session: the parent connection, the parent-side window, and the
nested compositor that draws into it."))

(defmethod print-object ((backend nested-backend) stream)
  (print-unreadable-object (backend stream :type t)
    (format stream "~Dx~D, ~D frame~:P, ~:[not mapped~;mapped~]"
            (nested-width backend) (nested-height backend)
            (nested-frame-count backend) (nested-mapped-p backend))))

;;; ---------------------------------------------------------------------------
;;; Waiting without blocking the parent
;;; ---------------------------------------------------------------------------

(defun wait-until (backend predicate &key (timeout 10) (interval 0.01))
  "Pump the parent connection until PREDICATE returns true, or TIMEOUT seconds pass.

Every wait in this file goes through here, so the in-process gate (where the parent
compositor is in this image and must be pumped) and a real session (where the
parent is another process and its reply arrives on the socket) take the same path."
  (let ((deadline (+ (get-internal-real-time)
                     (round (* timeout internal-time-units-per-second)))))
    (loop
      (when (funcall predicate)
        (return t))
      (when (> (get-internal-real-time) deadline)
        (return nil))
      (handler-case
          (wc:dispatch (nested-display backend) :timeout interval)
        (wc:client-error ()
          (return nil)))
      (when (nested-pump backend)
        (funcall (nested-pump backend) 0)))))

;;; ---------------------------------------------------------------------------
;;; Starting
;;; ---------------------------------------------------------------------------

(defun make-parent-pointer (backend)
  "Bind the parent's wl_pointer and route its events into our seat."
  (let ((pointer (wc:wl-seat.get-pointer (nested-seat backend))))
    (push (lambda (event &rest arguments)
            (handle-pointer-event backend event arguments))
          (wc:proxy-hooks pointer))
    pointer))

(defun make-parent-keyboard (backend)
  "Bind the parent's wl_keyboard and route its events into our seat."
  (let ((keyboard (wc:wl-seat.get-keyboard (nested-seat backend))))
    (push (lambda (event &rest arguments)
            (handle-keyboard-event backend event arguments))
          (wc:proxy-hooks keyboard))
    keyboard))

(defun update-devices (backend capabilities)
  "Create the devices the parent's new capability mask allows.

A device is not destroyed when a capability goes away: releasing it is a request
the client sends, and a nested session that lost its pointer is a session whose
parent stopped offering one -- it will not be sent events either way."
  (when (and (logtest srv:+wl-seat-capability-pointer+ capabilities)
             (null (nested-pointer backend)))
    (setf (nested-pointer backend) (make-parent-pointer backend)))
  (when (and (logtest srv:+wl-seat-capability-keyboard+ capabilities)
             (null (nested-keyboard backend)))
    (setf (nested-keyboard backend) (make-parent-keyboard backend))))

(defun parent-seat-hooks (backend seat)
  (push (lambda (event &rest arguments)
          ;; CASE, not ECASE: a newer parent may send a seat event this version has
          ;; no use for, and that is not an error.
          (case event
            (:capabilities (update-devices backend (first arguments)))
            (:name (setf (nested-seat-name backend) (first arguments)))))
        (wc:proxy-hooks seat)))

(defun bind-parent-globals (backend registry)
  "Bind what a nested output needs; return false when the parent cannot host us."
  (let ((globals '()))
    (push (lambda (event &rest arguments)
            (when (eq event :global)
              (push arguments globals)))
          (wc:proxy-hooks registry))
    (wc:flush (nested-display backend))
    (unless (wait-until backend
                        (lambda ()
                          (and (find "wl_compositor" globals :key #'second :test #'string=)
                               (find "wl_shm" globals :key #'second :test #'string=)))
                        :timeout 10)
      (error "the parent did not announce wl_compositor and wl_shm"))
    (flet ((bind (interface version)
             (let ((global (find interface globals :key #'second :test #'string=)))
               (and global
                    (wc:wl-registry.bind registry (first global) interface version)))))
      (let ((compositor (bind "wl_compositor" 3))
            (shm (bind "wl_shm" 1))
            (seat (bind "wl_seat" 4))
            (wm-base (bind "xdg_wm_base" 1)))
        (unless (and compositor shm)
          (error "the parent does not offer wl_compositor and wl_shm"))
        (when seat
          (setf (nested-seat backend) seat)
          (parent-seat-hooks backend seat))
        (when wm-base
          (setf (nested-wm-base backend) wm-base))
        ;; The parent answers get_registry, the binds, the seat's capabilities and
        ;; (with xdg-shell) nothing else yet; one roundtrip after the binds is where
        ;; the devices exist and a configure can be acked.
        (setf (nested-parent-compositor backend) compositor
              (nested-shm backend) shm)
        t))))

(defun create-parent-surface (backend)
  "Create the parent-side wl_surface our output is presented into."
  (let ((surface (wc:wl-compositor.create-surface
                  (nested-parent-compositor backend))))
    (setf (nested-surface backend) surface)
    surface))

(defun pump-roundtrip (backend)
  "A roundtrip that lets the parent (in another process, or in this image) run."
  (let* ((display (nested-display backend))
         (callback (wc:wl-display.sync display))
         (done nil))
    (push (lambda (event &rest arguments)
            (declare (ignore arguments))
            (when (eq event :done)
              (setf done t)))
          (wc:proxy-hooks callback))
    (wc:flush display)
    (unless (wait-until backend (lambda () done) :timeout 10)
      (error "the parent did not answer a sync"))))

(defun request-parent-frame (backend &key after)
  "Ask the parent for a frame callback; call AFTER, if any, when it fires."
  (let ((callback (wc:wl-surface.frame (nested-surface backend))))
    (push (lambda (event &rest arguments)
            (declare (ignore arguments))
            (when (eq event :done)
              (setf (nested-awaiting-frame-p backend) nil)
              (when after (funcall after))))
          (wc:proxy-hooks callback))
    callback))

(defun create-buffers (backend)
  "One pool, two buffers, one pixman target per buffer, and their release hooks."
  (let* ((width (nested-width backend))
         (height (nested-height backend))
         (stride (* width 4))
         (frame-size (* stride height))
         (pool (wc:make-client-pool (nested-shm backend) (* 2 frame-size))))
    (setf (nested-pool backend) pool)
    (dotimes (index 2)
      (let* ((buffer (wc:allocate-client-buffer pool
                                                :offset (* index frame-size)
                                                :width width :height height
                                                :stride stride :format 0))
             (slot (make-buffer-slot
                    :buffer buffer
                    :target (render:make-target-over-pointer
                             (wc:client-buffer-pointer buffer) width height
                             :stride stride))))
        ;; A release is the parent saying "I have the pixels".  The slot becomes
        ;; drawable again, and if a frame was deferred for want of a buffer it is
        ;; requested now -- only when something is actually dirty, or every release
        ;; would schedule another frame forever.
        (push (lambda (event &rest arguments)
                (declare (ignore arguments))
                (when (eq event :release)
                  (setf (buffer-slot-free-p slot) t)
                  (when (headless:compositor-dirty-p (nested-compositor backend))
                    (headless:request-frame (nested-compositor backend)))))
              (wc:proxy-hooks (wc:client-buffer-proxy buffer)))
        (push slot (nested-buffers backend))))))

(defun create-parent-toplevel (backend)
  "Give our parent surface the toplevel role and wait for the initial configure.

The commit that asks for the configure carries no buffer on purpose: the protocol's
first commit is the client saying \"tell me a size\".  Our size is chosen already, so
the configure is acknowledged and its size ignored (see the header)."
  (let* ((wm-base (nested-wm-base backend))
         (surface (nested-surface backend))
         (shell (wc:xdg-wm-base.get-xdg-surface wm-base surface))
         (toplevel (wc:xdg-surface.get-toplevel shell)))
    (setf (nested-xdg-surface backend) shell
          (nested-toplevel backend) toplevel)
    (wc:xdg-toplevel.set-title toplevel "cl-umbra nested")
    (wc:xdg-toplevel.set-app-id toplevel "cl-umbra")
    (push (lambda (event &rest arguments)
            (declare (ignore arguments))
            (when (eq event :close)
              ;; The user closed the window: end the nested session, do not
              ;; pretend the surface is still there.
              (setf (nested-closing-p backend) t)
              (headless:stop-compositor (nested-compositor backend))))
          (wc:proxy-hooks toplevel))
    ;; xdg_surface.configure arrives on the xdg_surface object, not the toplevel.
    (push (lambda (event &rest arguments)
            (when (eq event :configure)
              (let ((serial (first arguments)))
                (setf (nested-configure-serial backend) serial)
                (wc:xdg-surface.ack-configure shell serial)
                (setf (nested-configured-p backend) t))))
          (wc:proxy-hooks shell))
    (wc:wl-surface.commit surface)
    (wc:flush (nested-display backend))
    (unless (wait-until backend (lambda () (nested-configured-p backend)) :timeout 10)
      (error "the parent never configured our toplevel"))))

(defun start-nested (&key parent-path (width 256) (height 256)
                          (display-name "wayland-1")
                          runtime-dir
                          (pump nil))
  "Run a compositor inside the compositor at PARENT-PATH.

Returns a NESTED-BACKEND.  The nested compositor's own display is
`(compositor-display (nested-compositor ...))`; a client is started against it the
same way a client is started against any compositor.  DISPLAY-NAME defaults to
wayland-1, which is wrong if the parent is also wayland-1: pass one.

PUMP takes a timeout in seconds and is for the case where the parent compositor is
in *this* image (the gate); it is NIL by default, which is right when the parent is
another process, because then our own socket read is the only thing that has to
wait."
  (let ((display nil)
        (compositor nil)
        (backend nil))
    (handler-case
        (progn
          (setf display (wc:connect :path parent-path)
                compositor (headless:make-headless-compositor
                            :width width :height height
                            :display-name display-name
                            :runtime-dir runtime-dir)
                backend (make-instance 'nested-backend
                                       :display display
                                       :compositor compositor
                                       :width width
                                       :height height
                                       :pump pump))
          (let ((registry (wc:wl-display.get-registry display)))
            ;; BIND-PARENT-GLOBALS fills in the slots of what the parent offers.
            (unless (bind-parent-globals backend registry)
              (error "the parent cannot host a nested output"))
            (create-parent-surface backend)
            (pump-roundtrip backend)
            (when (nested-wm-base backend)
              (create-parent-toplevel backend))
            (create-buffers backend)
            ;; From here on the compositor owns the frame clock: a dirty output asks
            ;; for a render, our preparer hands it a free parent buffer, and the
            ;; presenter attaches and commits it.
            (setf (headless:compositor-frame-preparer compositor)
                  (lambda (inner)
                    (declare (ignore inner))
                    (prepare-nested-frame backend))
                  (headless:compositor-frame-presenter compositor)
                  (lambda (inner target)
                    (declare (ignore inner target))
                    (present-nested-frame backend)))
            (headless:request-frame compositor)
            backend))
      (error (condition)
        ;; A half-started backend owns a socket, a parent connection and a display;
        ;; leaving any of them behind turns a failed start into a leaked one.
        (cond
          (backend (ignore-errors (stop-nested backend)))
          (t
           (when display (ignore-errors (wc:disconnect display)))
           (when compositor
             (ignore-errors (srv:close-display
                             (headless:compositor-display compositor))))))
        (error condition)))))

;;; ---------------------------------------------------------------------------
;;; Drawing and presenting
;;; ---------------------------------------------------------------------------

(defun prepare-nested-frame (backend)
  "The target for this frame: the first parent buffer the parent has released."
  ;; One frame in flight: the parent's frame callback is the clock, so a second
  ;; commit before it arrives would be a second frame the parent never asked for.
  (when (or (nested-closing-p backend)
            (nested-awaiting-frame-p backend))
    (return-from prepare-nested-frame nil))
  (let ((slot (find-if #'buffer-slot-free-p (nested-buffers backend))))
    (unless slot
      (return-from prepare-nested-frame nil))
    (setf (buffer-slot-free-p slot) nil
          (nested-current backend) slot)
    (buffer-slot-target slot)))

(defun present-nested-frame (backend)
  "Attach the frame we just drew, damage all of it, commit, ask for a frame.

Presenting before the inner clients' buffers are released is deliberate: the
pixels are in the parent's buffer now, so the frame that contains them exists."
  (let ((slot (nested-current backend)))
    (unless slot
      (return-from present-nested-frame nil))
    (let ((surface (nested-surface backend))
          (width (nested-width backend))
          (height (nested-height backend)))
      (wc:wl-surface.attach surface (buffer-slot-buffer slot) 0 0)
      ;; v0 damages everything: the renderer repaints the whole target, so saying
      ;; anything smaller would be a lie (2b's damage tracking changes both).
      (wc:wl-surface.damage surface 0 0 width height)
      (request-parent-frame backend
                            :after (lambda ()
                                     (when (and (not (nested-closing-p backend))
                                                (headless:compositor-dirty-p
                                                 (nested-compositor backend)))
                                       (headless:request-frame
                                        (nested-compositor backend)))))
      (wc:wl-surface.commit surface)
      (wc:flush (nested-display backend))
      (setf (nested-awaiting-frame-p backend) t
            (nested-mapped-p backend) t)
      (incf (nested-frame-count backend))))
  nil)

;;; ---------------------------------------------------------------------------
;;; Input from the parent
;;; ---------------------------------------------------------------------------
;;
;; Every event is translated into the same call a test or a future libinput
;; backend makes (docs/framework.md §2: a backend only reports).  The pointer's
;; coordinates are surface-local to our parent surface, which is output-local to
;; us because the parent surface starts at (0, 0) inside itself.

(defparameter +parent-pointer-buttons+
  '((#x110 . :left) (#x111 . :right) (#x112 . :middle)))

(defun handle-pointer-event (backend event arguments)
  (let ((compositor (nested-compositor backend)))
    (incf (slot-value backend 'pointer-event-count))
    (ecase event
      (:enter
       (destructuring-bind (serial surface x y) arguments
         (declare (ignore serial surface))
         (cf:inject-pointer-motion compositor (round x) (round y))))
      (:leave
       ;; Off the output: the scene's hit test finds nothing and the seat's pointer
       ;; focus is cleared, which is exactly what a real backend reports.
       (cf:inject-pointer-motion compositor -1 -1))
      (:motion
       (destructuring-bind (time x y) arguments
         (declare (ignore time))
         (cf:inject-pointer-motion compositor (round x) (round y))))
      (:button
       (destructuring-bind (serial time button state) arguments
         (declare (ignore serial time))
         (cf:inject-pointer-button compositor
                                   (or (cdr (assoc button +parent-pointer-buttons+))
                                       button)
                                   (if (= state 1) :pressed :released))))
      (:axis
       (destructuring-bind (time axis value) arguments
         (declare (ignore time))
         (cf:inject-pointer-axis compositor axis (round value))))
      (t nil))
    nil))

(defun handle-keyboard-event (backend event arguments)
  (let ((compositor (nested-compositor backend)))
    (ecase event
      (:keymap
       (destructuring-bind (format fd size) arguments
         (declare (ignore format))
         ;; The parent's keymap belongs to the parent's layout; our clients are sent
         ;; ours (D28), so the descriptor is read for evidence and closed.  A client
         ;; that never closes a received descriptor leaks one per keyboard.
         (setf (slot-value backend 'parent-keymap-size) size)
         (when (and (integerp size) (plusp size))
           (let ((pointer (ignore-errors
                           (ffi:map-file fd size :protection ffi:+prot-read+))))
             (when pointer
               (unwind-protect
                    ;; Read a little of it: enough to prove the descriptor was
                    ;; delivered and is readable, without pretending to parse
                    ;; another compositor's keymap.
                    (ffi:mapped-octets pointer 0 (min size 64))
                 (ignore-errors (ffi:unmap-file pointer size))))))
         (ignore-errors (ffi:close-fd fd))))
      (:key
       (destructuring-bind (serial time key state) arguments
         (declare (ignore serial time))
         ;; wl_keyboard.key carries the evdev code, which our table can look up.
         ;; A key this compositor has no name for is not forwarded: sending the
         ;; wrong name would be worse than dropping one key.
         (let ((name (handler-case (input:key-name key) (error () nil))))
           (when name
             (incf (slot-value backend 'key-count))
             (cf:inject-key compositor name
                            (if (= state 1) :pressed :released))))))
      ((:enter :leave :modifiers :repeat-info) nil)
      (t nil))
    nil))

;;; ---------------------------------------------------------------------------
;;; Running
;;; ---------------------------------------------------------------------------

(defun nested-dispatch (backend &key (timeout 0))
  "One pass: the parent's events, then a cycle of the nested compositor.

TIMEOUT is how long to wait for a parent event.  The two reactors are separate
epoll sets in v0, so this is a poll loop rather than one merged wait; a nested
session is a debugging and test backend, and merging waits is phase-4 work."
  (unless (nested-closing-p backend)
    (handler-case
        (wc:dispatch (nested-display backend) :timeout timeout)
      (wc:client-error ()
        (setf (nested-closing-p backend) t)))
    (when (nested-pump backend)
      (funcall (nested-pump backend) 0)))
  ;; After STOP-NESTED the inner display is closed, and running a closed reactor is
  ;; an error rather than a no-op: the caller may still pump the parent.
  (unless (nested-closing-p backend)
    (srv:run-once (headless:compositor-display (nested-compositor backend))
                  :timeout 0))
  backend)

(defun run-nested (backend &key (timeout 0.01))
  "The nested session's main loop, until the nested compositor stops or the parent goes."
  (let ((reactor (srv:display-reactor
                  (headless:compositor-display (nested-compositor backend)))))
    (loop until (or (nested-closing-p backend) (reactor:stopped-p reactor))
          do (nested-dispatch backend :timeout timeout))
    backend))

;;; ---------------------------------------------------------------------------
;;; Stopping
;;; ---------------------------------------------------------------------------

(defun stop-nested (backend)
  "Tear the nested session down; idempotent.

Order matters: the parent-side objects are destroyed (so the parent unmaps a window
instead of noticing a dead socket), then our own buffers and pool, then the inner
display.  Every step is guarded, because a failed start may have created only some
of them."
  (unless (nested-closing-p backend)
    (setf (nested-closing-p backend) t)
    (let ((display (nested-display backend)))
      (handler-case
          (progn
            (when (nested-toplevel backend)
              (ignore-errors (wc:xdg-toplevel.destroy (nested-toplevel backend))))
            (when (nested-xdg-surface backend)
              (ignore-errors (wc:xdg-surface.destroy (nested-xdg-surface backend))))
            (when (nested-surface backend)
              (ignore-errors (wc:wl-surface.destroy (nested-surface backend))))
            (wc:flush display))
        (wc:client-error () nil))
      (dolist (slot (nested-buffers backend))
        (ignore-errors (wc:destroy-client-buffer (buffer-slot-buffer slot))))
      (when (nested-pool backend)
        (ignore-errors (wc:destroy-client-pool (nested-pool backend))))
      (ignore-errors (wc:disconnect display)))
    (let ((compositor (nested-compositor backend)))
      (headless:stop-compositor compositor)
      (ignore-errors (srv:close-display (headless:compositor-display compositor)))))
  backend)
