;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Reactor tests: real epoll, a real timerfd, a real eventfd, a real
;;;; signalfd.  No mocks -- the point of this layer is that the kernel does
;;;; what we think it does.

(in-package #:cl-user)

(defpackage #:wayland.test.reactor
  (:use #:cl #:rove)
  (:local-nicknames (#:ffi #:wayland.ffi)
                    (#:rt #:wayland.reactor))
  (:documentation "Tests for wayland.reactor."))

(in-package #:wayland.test.reactor)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defmacro with-reactor ((var) &body body)
  `(let ((,var (rt:make-reactor)))
     (unwind-protect (progn ,@body)
       (rt:close-reactor ,var))))

(defmacro with-socket-pair ((writer reader) &body body)
  (let ((w (gensym "WRITER")) (r (gensym "READER")))
    `(multiple-value-bind (,w ,r) (ffi:make-socket-pair)
       (let ((,writer ,w) (,reader ,r))
         (declare (ignorable ,writer ,reader))
         (unwind-protect (progn ,@body)
           (ffi:close-fd ,w)
           (ffi:close-fd ,r))))))

(defun octets (&rest values)
  (make-array (length values)
              :element-type '(unsigned-byte 8)
              :initial-contents values))

(defun send-octets (fd octets)
  (let ((octets (if (typep octets '(simple-array (unsigned-byte 8) (*)))
                    octets
                    (coerce octets '(simple-array (unsigned-byte 8) (*))))))
    (ffi:send-with-ancillary fd octets 0 (length octets) '())))

(defun read-some (fd &key (size 64))
  (let ((buffer (make-array size :element-type '(unsigned-byte 8))))
    (multiple-value-bind (count) (ffi:read-into fd buffer 0 size)
      (subseq buffer 0 count))))

(defun elapsed-since (start)
  (- (rt:monotonic-now) start))

;;; ---------------------------------------------------------------------------
;;; Time
;;; ---------------------------------------------------------------------------

(deftest timer-sleeps-about-as-long-as-asked
  (with-reactor (reactor)
    (let ((fired 0)
          (start (rt:monotonic-now)))
      (rt:add-timer reactor 0.05
                    (lambda (timer) (declare (ignore timer)) (incf fired)))
      (rt:run-once reactor :timeout 2.0)
      (let ((elapsed (elapsed-since start)))
        (ok (= 1 fired))
        (ok (>= elapsed 0.045) "woke before the deadline")
        (ok (< elapsed 0.5) "slept far longer than asked")))))

(deftest the-callers-timeout-caps-the-wait
  (with-reactor (reactor)
    (let ((start (rt:monotonic-now)))
      (rt:run-once reactor :timeout 0.03)
      (let ((elapsed (elapsed-since start)))
        (ok (>= elapsed 0.025))
        (ok (< elapsed 0.4))))))

(deftest the-nearest-timer-wins
  (with-reactor (reactor)
    (let ((fired '())
          (start (rt:monotonic-now)))
      (rt:add-timer reactor 0.03
                    (lambda (timer) (declare (ignore timer)) (push :first fired)))
      (rt:add-timer reactor 0.20
                    (lambda (timer) (declare (ignore timer)) (push :second fired)))
      (rt:run-once reactor :timeout 1.0)
      (ok (equal '(:first) fired) "only the earlier timer may fire")
      (ok (< (elapsed-since start) 0.15))
      (rt:run-once reactor :timeout 1.0)
      (ok (equal '(:second :first) fired))
      (ok (>= (elapsed-since start) 0.19)))))

(deftest repeating-timers-rearm-themselves
  (with-reactor (reactor)
    (let ((fired 0))
      (rt:add-timer reactor 0.01
                    (lambda (timer) (declare (ignore timer)) (incf fired))
                    :repeat 0.01)
      (rt:run-once reactor :timeout 1.0)
      (ok (= 1 fired))
      (rt:run-once reactor :timeout 1.0)
      (ok (= 2 fired)))))

(deftest cancelled-timers-never-fire
  (with-reactor (reactor)
    (let* ((fired 0)
           (timer (rt:add-timer reactor 0.0
                               (lambda (timer)
                                 (declare (ignore timer))
                                 (incf fired)))))
      (rt:cancel-timer reactor timer)
      (rt:run-once reactor :timeout 0.02)
      (ok (= 0 fired)))))

;;; ---------------------------------------------------------------------------
;;; Descriptor sources
;;; ---------------------------------------------------------------------------

(deftest readable-sources-are-dispatched
  (with-reactor (reactor)
    (with-socket-pair (writer reader)
      (let ((calls 0)
            (received nil))
        (rt:add-source reactor reader
                       :name "probe"
                       :on-readable (lambda (source events)
                                      (declare (ignore events))
                                      (incf calls)
                                      (setf received
                                            (read-some (rt:source-fd source)))))
        (send-octets writer (octets 1 2 3))
        (rt:run-once reactor :timeout 0.5)
        (ok (= 1 calls))
        (ok (equalp (octets 1 2 3) received))))))

(deftest interest-can-be-reprogrammed
  (with-reactor (reactor)
    (with-socket-pair (writer reader)
      (let ((readable 0)
            (writable 0))
        (let ((source (rt:add-source reactor reader
                                     :interest :write
                                     :on-readable
                                     (lambda (source events)
                                       (declare (ignore source events))
                                       (incf readable))
                                     :on-writable
                                     (lambda (source events)
                                       (declare (ignore source events))
                                       (incf writable)))))
          ;; A socket pair end is writable at once.
          (rt:run-once reactor :timeout 0.2)
          (ok (= 1 writable))
          (ok (= 0 readable))
          ;; Stop asking for writability, then wait: silence.
          (rt:set-source-interest reactor source :read)
          (rt:run-once reactor :timeout 0.03)
          (ok (= 1 writable) "writability was switched off")
          (ok (= 0 readable))
          ;; Now there is something to read.
          (send-octets writer (octets 9))
          (rt:run-once reactor :timeout 0.3)
          (ok (= 1 readable)))))))

(deftest removed-sources-stop-firing
  (with-reactor (reactor)
    (with-socket-pair (writer reader)
      (let ((calls 0))
        (let ((source (rt:add-source reactor reader
                                     :on-readable
                                     (lambda (source events)
                                       (declare (ignore source events))
                                       (incf calls)))))
          (rt:remove-source reactor source))
        (send-octets writer (octets 1))
        (rt:run-once reactor :timeout 0.05)
        (ok (= 0 calls))))))

(deftest hanging-up-is-readable-news
  (with-reactor (reactor)
    (with-socket-pair (writer reader)
      (let ((calls 0)
            (mask 0))
        (rt:add-source reactor reader
                       :on-readable (lambda (source events)
                                      (declare (ignore source))
                                      (incf calls)
                                      (setf mask events)))
        (ffi:close-fd writer)
        (rt:run-once reactor :timeout 0.3)
        (ok (= 1 calls) "a closed peer must reach the readable callback")
        (ok (not (zerop (logand mask (logior rt:+epoll-hup+
                                             rt:+epoll-rdhup+))))
            "the callback must be told it was a hangup")))))

(deftest registering-one-descriptor-twice-is-refused
  (with-reactor (reactor)
    (with-socket-pair (writer reader)
      (rt:add-source reactor reader :on-readable (lambda (source events)
                                                   (declare (ignore source events))))
      (ok (signals (rt:add-source reactor reader
                                  :on-readable (lambda (source events)
                                                 (declare (ignore source events))))
                   'rt:duplicate-source)))))

;;; ---------------------------------------------------------------------------
;;; Commands and threads
;;; ---------------------------------------------------------------------------

#+sb-thread
(deftest posted-commands-wake-the-loop
  (with-reactor (reactor)
    (let ((ran nil)
          (start (rt:monotonic-now)))
      (sb-thread:make-thread
       (lambda ()
         (sleep 0.03)
         (rt:post reactor (lambda ()
                            (setf ran t)
                            (rt:request-stop reactor)))))
      (ok (eq :stopped (rt:run reactor :timeout 2.0)))
      (ok ran "the posted command did not run")
      (ok (< (elapsed-since start) 0.8) "the eventfd did not wake the loop"))))

(deftest a-command-posted-by-a-callback-runs-next-cycle
  (with-reactor (reactor)
    (let ((order '()))
      (rt:add-idle reactor
                   (lambda ()
                     (push :idle order)
                     (rt:post reactor (lambda () (push :posted order)))))
      (rt:run-once reactor :timeout 0.02)
      (ok (equal '(:idle) order) "a post must not run inside the cycle that made it")
      (rt:run-once reactor :timeout 0.02)
      (ok (equal '(:posted :idle) order)))))

(deftest cycle-order-is-commands-then-descriptors-then-timers-then-idles
  (with-reactor (reactor)
    (with-socket-pair (writer reader)
      (let ((order '()))
        (send-octets writer (octets 1 2 3))
        (rt:add-source reactor reader
                       :on-readable (lambda (source events)
                                      (declare (ignore source events))
                                      (push :descriptor order)))
        (rt:add-timer reactor 0.0
                      (lambda (timer) (declare (ignore timer)) (push :timer order)))
        (rt:add-idle reactor (lambda () (push :idle order)))
        (rt:post reactor (lambda () (push :command order)))
        (rt:run-once reactor :timeout 0.2)
        (ok (equal '(:command :descriptor :timer :idle) (reverse order)))))))

(deftest idles-run-once-per-cycle
  (with-reactor (reactor)
    (let ((runs 0))
      (rt:add-idle reactor (lambda () (incf runs)))
      (rt:run-once reactor :timeout 0.01)
      (rt:run-once reactor :timeout 0.01)
      (ok (= 1 runs)))))

(deftest reentering-the-loop-is-refused
  (with-reactor (reactor)
    (rt:add-idle reactor (lambda () (rt:run-once reactor :timeout 0)))
    (ok (signals (rt:run-once reactor :timeout 0.02) 'rt:reactor-reentry))
    (ok (not (rt:dispatching-p reactor))
        "the reactor must be usable again after a refused re-entry")))

(deftest closing-a-reactor-twice-is-harmless
  (let ((reactor (rt:make-reactor)))
    (ok (rt:close-reactor reactor))
    (ok (rt:close-reactor reactor))
    (ok (signals (rt:run-once reactor :timeout 0) 'rt:reactor-error))))

;;; ---------------------------------------------------------------------------
;;; Signals
;;; ---------------------------------------------------------------------------

(deftest signalfd-delivers-a-blocked-signal
  (with-reactor (reactor)
    (let* ((seen '())
           (source (rt:add-signal-source
                   reactor (list rt:+sigusr1+)
                   :on-signal (lambda (source signal)
                                (declare (ignore source))
                                (push signal seen)))))
      (unwind-protect
           (progn
             (ffi:raise-signal rt:+sigusr1+)
             (rt:run-once reactor :timeout 0.5)
             (ok (equal (list rt:+sigusr1+) seen)
                 "a blocked signal must arrive through the descriptor"))
        (rt:remove-source reactor source)
        (ffi:close-fd (rt:source-fd source))
        (ffi:unblock-signals rt:+sigusr1+)))))

(deftest sigpipe-is-ignored
  ;; If this fails, the test image dies rather than reporting: that is the
  ;; failure mode SIGPIPE has, and the reason a compositor must ignore it.
  (ffi:ignore-sigpipe)
  (with-socket-pair (writer reader)
    (ffi:close-fd reader)
    (let ((payload (octets 1 2 3)))
      (ok (signals (cffi:with-pointer-to-vector-data (pointer payload)
          (ffi:write-from-pointer writer pointer 3)) 'ffi:connection-closed)))))
