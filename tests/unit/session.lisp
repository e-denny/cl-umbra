;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; cf.session: the seat state machine, with a recording seat in place of logind
;;;; (D56).
;;;;
;;;; No seat is opened here, and nothing here needs one.  The module's content is
;;;; the availability machine -- opening, enabling, disabling, acknowledging,
;;;; reopening -- and the eight generics it stands on are what a fake replaces, in
;;;; the same way tests/unit/drm.lisp replaces the kernel calls.  What only a real
;;;; provider can answer (does logind give us the seat at all? is somebody else
;;;; holding control?) is scripts/input-gate.lisp's business.
;;;;
;;;; The assertions are about order and about state, because those are the two
;;;; things a VT switch gets wrong: a device closed after the provider revoked it,
;;;; an acknowledgement sent before the opens are accounted for, a hook that runs
;;;; while the state still says the old thing.

(in-package #:cl-user)

(defpackage #:wayland.test.session
  (:use #:cl #:rove)
  (:local-nicknames (#:session #:cf.session))
  (:documentation "Tests for cf.session: the availability machine (D56)."))

(in-package #:wayland.test.session)

;;; ---------------------------------------------------------------------------
;;; A recording seat
;;; ---------------------------------------------------------------------------
;;
;; Every call appends to LOG, so a test can assert the *order* the provider would
;; have seen, not just the final state.  PENDING is the queue of availability
;; events the fake reports on dispatch: :enable, :disable.

(defclass fake-session (session:session)
  ((log :initform '() :accessor fake-log)
   (pending :initarg :pending :initform '() :accessor fake-pending)
   (next-device-id :initform 0 :accessor fake-next-device-id)
   (next-fd :initform 10 :accessor fake-next-fd)
   (fail-close-once :initform nil :accessor fake-fail-close-once)))

(defmethod session:%open-seat ((session fake-session))
  (push :open-seat (fake-log session))
  (cffi:null-pointer))

(defmethod session:%close-seat ((session fake-session))
  (push :close-seat (fake-log session))
  t)

(defmethod session:%acknowledge-disable ((session fake-session))
  (push :acknowledge (fake-log session))
  t)

(defmethod session:%open-device ((session fake-session) path)
  (push (list :open-device path) (fake-log session))
  (let ((id (incf (fake-next-device-id session)))
        (fd (incf (fake-next-fd session))))
    (values fd id)))

(defmethod session:%close-device ((session fake-session) id)
  (push (list :close-device id) (fake-log session))
  (when (fake-fail-close-once session)
    (setf (fake-fail-close-once session) nil)
    (error 'session-error :operation "close-device" :errno 9))
  t)

(defmethod session:%dispatch ((session fake-session) timeout)
  (declare (ignore timeout))
  (push :dispatch (fake-log session))
  (let ((event (pop (fake-pending session))))
    (case event
      (:enable (session:note-seat-enabled session) 1)
      (:disable (session:note-seat-disabled session) 1)
      (t 0))))

(defmethod session:%switch-session ((session fake-session) vt)
  (push (list :switch vt) (fake-log session))
  t)

(defmethod session:%seat-fd ((session fake-session))
  99)

(defun make-fake (&key on-enabled on-disabled pending)
  "An opened fake session.  PENDING availability events are queued before the open,
so they fire from the dispatch OPEN-SESSION does itself -- which is how logind
behaves for a session that is already active."
  (let ((session (session:open-session
                  :class 'fake-session
                  :initargs (list :pending pending)
                  :on-enabled on-enabled
                  :on-disabled on-disabled)))
    ;; The log keeps what the open did, so a test can see the order including the
    ;; open itself.  A test that wants a clean slate clears it explicitly.
    session))

(defun log-positions (session entry)
  (loop for item in (reverse (fake-log session))
        for index from 0
        when (equal item entry) collect index))

;;; ---------------------------------------------------------------------------
;;; Opening
;;; ---------------------------------------------------------------------------

(deftest opening-the-seat-makes-it-usable
  ;; logind's enable_seat arrives from inside libseat_open_seat for a session that is
  ;; already active, which is why the session is registered before the open call.
  (let ((session (make-fake :pending '(:enable))))
    (unwind-protect
         (progn
           (ok (session:session-enabled-p session)
               "the seat is usable without a second dispatch")
           (ok (= 1 (session:session-enable-count session)))
           (ok (equal "enabled" (session:session-state-string session)))
           (ok (= 99 (session:session-fd session)))
           (ok (member :open-seat (fake-log session) :test #'equal)))
      (session:close-session session))))

(deftest opening-dispatches-once-so-a-seatd-seat-can-report
  ;; The seatd backend reports availability only through dispatch, so one
  ;; non-blocking dispatch after the open is what keeps that backend from looking
  ;; like a disabled seat forever.
  (let ((session (make-fake)))
    (unwind-protect
         (progn
           (ok (= 1 (session:session-dispatch-count session))
               "opening dispatches exactly once")
           (ok (equal "opening" (session:session-state-string session))
               "with no availability event yet the seat is neither enabled nor
                disabled: it is not known, and no device may be opened")
           (ok (null (session:session-enabled-p session))))
      (session:close-session session))))

(deftest the-enable-hook-runs-after-the-state-changes
  (let* ((seen '())
         (session (make-fake :pending '(:enable)
                             :on-enabled (lambda (s)
                                           (push (session:session-state s) seen)))))
    (unwind-protect
         (ok (equal '(:enabled) seen)
             "a hook that opens devices must find the seat enabled")
      (session:close-session session))))

(deftest a-hook-that-fails-does-not-unmake-the-seat
  ;; The hook is how a compositor reopens its devices.  If it fails, the seat is
  ;; still ours: losing that fact would make the compositor wait for an enable
  ;; that already happened.
  (let ((session (make-fake :pending '(:enable)
                            :on-enabled (lambda (s) (declare (ignore s))
                                          (error "hook failed")))))
    (unwind-protect
         (progn
           (ok (session:session-enabled-p session))
           (ok (= 1 (length (session:session-callback-errors session)))
               "the error is recorded, not swallowed"))
      (session:close-session session))))

;;; ---------------------------------------------------------------------------
;;; Devices
;;; ---------------------------------------------------------------------------

(deftest devices-open-through-the-seat-only-while-it-is-enabled
  (let ((session (make-fake)))
    (unwind-protect
         (progn
           (ok (signals (session:open-session-device session "/dev/input/event0")
                        'session:session-not-enabled)
               "a disabled seat refuses: the provider has revoked the device")
           (session:note-seat-enabled session)
           (multiple-value-bind (fd id) (session:open-session-device session "/dev/input/event0")
             (ok (= 11 fd))
             (ok (= 1 id))
             (ok (equal (list "/dev/input/event0") (session:session-device-paths session)))
             (ok (= 1 (session:session-open-device-count session)))
             (ok (session:close-session-device session id))
             (ok (null (session:close-session-device session id))
                 "closing twice is tidy, not an error")))
      (session:close-session session))))

(deftest a-disable-closes-devices-before-it-acknowledges
  ;; libseat's header is explicit: a disable that is not acknowledged promptly is
  ;; enforced by revoking the fds.  Closing first means the closes succeed; the
  ;; acknowledgement is what tells the provider we are done.
  (let ((session (make-fake :pending '(:enable))))
    (unwind-protect
         (progn
           (session:open-session-device session "/dev/input/event0")
           (session:open-session-device session "/dev/input/event1")
           (setf (fake-log session) '()
                 (fake-pending session) '(:disable))
           (let ((result (session:dispatch-session session)))
             (ok (eq :event result))
             (ok (session:session-disabled-p session))
             (ok (null (session:session-device-paths session))
                 "no device is left open on a disabled seat")
             (ok (= 0 (session:session-open-device-count session)))
             (let ((closes (log-positions session (list :close-device 1)))
                   (ack (log-positions session :acknowledge)))
               (ok (= 1 (length closes)))
               (ok (= 1 (length ack)))
               (ok (> (first ack) (first closes))
                   "the acknowledgement comes after the closes"))
             (ok (= 1 (session:session-disable-count session)))))
      (session:close-session session))))

(deftest an-enable-without-a-disable-still-counts
  ;; Availability is a count as well as a state: a provider that re-enables after
  ;; a switch tells us twice, and a compositor that reopens its devices on every
  ;; enable wants both events, not just the first.
  (let ((session (make-fake :pending '(:enable))))
    (unwind-protect
         (progn
           (session:note-seat-enabled session)
           (ok (session:session-enabled-p session))
           (ok (= 2 (session:session-enable-count session))))
      (session:close-session session))))

(deftest a-close-that-fails-is-counted-and-does-not-stop-the-rest
  (let ((session (make-fake :pending '(:enable))))
    (unwind-protect
         (progn
           (session:open-session-device session "/dev/input/event0")
           (session:open-session-device session "/dev/input/event1")
           (setf (fake-fail-close-once session) t)
           (session:close-all-session-devices session)
           (ok (= 1 (session:session-failed-closes session)))
           (ok (null (session:session-device-paths session))
               "both are forgotten even though one close reported an error"))
      (session:close-session session))))

;;; ---------------------------------------------------------------------------
;;; Closing and switching
;;; ---------------------------------------------------------------------------

(deftest closing-closes-devices-then-the-seat-and-is-idempotent
  (let ((session (make-fake :pending '(:enable))))
    (session:open-session-device session "/dev/input/event0")
    (setf (fake-log session) '())
    (ok (session:close-session session))
    (ok (session:session-closed-p session))
    (ok (equal '((:close-device 1) :close-seat) (reverse (fake-log session)))
        "the device goes before the seat")
    (setf (fake-log session) '())
    (ok (session:close-session session))
    (ok (null (fake-log session))
        "a second close does nothing at all")))

(deftest switching-asks-the-provider
  (let ((session (make-fake :pending '(:enable))))
    (unwind-protect
         (progn
           (session:switch-session-to session 3)
           (ok (member (list :switch 3) (fake-log session) :test #'equal)))
      (session:close-session session))))

(deftest a-dispatch-that-does-nothing-says-so
  (let ((session (make-fake)))
    (unwind-protect
         (ok (eq :none (session:dispatch-session session)))
      (session:close-session session))))

(deftest a-closed-session-ignores-late-availability
  ;; A callback can arrive after CLOSE-SESSION: the seat connection is closed but
  ;; the C side may still call enable_seat once.  The machine must not resurrect
  ;; itself.
  (let ((session (make-fake)))
    (session:close-session session)
    (let ((enables (session:session-enable-count session))
          (disables (session:session-disable-count session)))
      (ok (null (session:note-seat-enabled session)))
      (ok (null (session:note-seat-disabled session)))
      (ok (session:session-closed-p session))
      (ok (= enables (session:session-enable-count session))
          "a late enable is not counted")
      (ok (= disables (session:session-disable-count session))))))
