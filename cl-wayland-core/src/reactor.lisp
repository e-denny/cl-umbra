;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The reactor: one thread, one epoll, one timerfd, one signalfd.
;;;;
;;;; One cycle is, in this order (docs/protocol-layer.md §7):
;;;;
;;;;   1. run commands posted from other threads
;;;;   2. arm the timerfd for the nearest deadline, then wait
;;;;   3. dispatch ready sources: readable first, then writable
;;;;   4. fire timers that are due
;;;;   5. run idle callbacks, once per cycle
;;;;
;;;; The order is the contract, and it is tested: a command posted before a
;;;; cycle runs before anything that cycle waits for, and an idle never runs
;;;; ahead of a descriptor that was already readable.
;;;;
;;;; Re-entrancy is forbidden on purpose.  A callback may post a command and may
;;;; append to an out buffer, but calling RUN-ONCE again from inside a callback
;;;; signals REACTOR-REENTRY.  Everything a compositor wants to do "later" is a
;;;; post or a timer, never a nested loop.

(in-package #:wayland.reactor)

(defparameter *max-events-per-wait* 64
  "How many ready descriptors one epoll_wait reports.  The rest are still ready
and come back next cycle: level-triggered means no event is ever lost.")

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition reactor-error (error)
  ((detail :initarg :detail :initform nil :reader reactor-error-detail))
  (:report (lambda (condition stream)
             (format stream "reactor error~@[: ~A~]"
                     (reactor-error-detail condition)))))

(define-condition reactor-reentry (reactor-error) ()
  (:default-initargs
   :detail "run-once called from inside a callback; post a command instead"))

(define-condition duplicate-source (reactor-error)
  ((fd :initarg :fd :reader duplicate-source-fd))
  (:report (lambda (condition stream)
             (format stream "fd ~D already has a source; remove it first"
                     (duplicate-source-fd condition)))))

;;; ---------------------------------------------------------------------------
;;; The reactor structure
;;; ---------------------------------------------------------------------------
;;
;; Defined before anything that touches its slots, so the whole file compiles
;; through the real accessors.

(defstruct (reactor (:constructor %make-reactor))
  (epfd -1 :type fixnum)
  (wake-fd -1 :type fixnum)
  (timer-fd -1 :type fixnum)
  (events (cffi:null-pointer))
  (max-events *max-events-per-wait* :type fixnum)
  (sources (make-hash-table) :type hash-table)
  (timers nil)
  (idles nil)
  (commands nil)
  (command-lock nil)
  (dispatching-p nil)
  (stop-p nil)
  (armed-deadline nil)
  (closed-p nil))

;;; ---------------------------------------------------------------------------
;;; Sources
;;; ---------------------------------------------------------------------------

(defstruct (fd-source (:constructor %make-source
                                    (fd interest on-readable on-writable name)))
  (fd 0 :type fixnum)
  (interest :read :type keyword)
  on-readable
  on-writable
  (name nil :type (or null string)))

(defun source-fd (source) (fd-source-fd source))
(defun source-name (source) (fd-source-name source))
(defun source-interest (source) (fd-source-interest source))

(defun interest-events (interest)
  (ecase interest
    (:read +epoll-in+)
    (:write +epoll-out+)
    (:read-write (logior +epoll-in+ +epoll-out+))
    (:none 0)))

(defun add-source (reactor fd &key (interest :read) on-readable on-writable name)
  "Register FD with the reactor.  ON-READABLE is called with (SOURCE EVENTS) and
fires on EPOLLIN, EPOLLHUP, EPOLLERR and EPOLLRDHUP -- a hangup is readable
news: the caller's next read reports why.  ON-WRITABLE fires on EPOLLOUT.

The reactor never closes FD: whoever opened it closes it, after REMOVE-SOURCE."
  (when (nth-value 1 (gethash fd (reactor-sources reactor)))
    (error 'duplicate-source :fd fd))
  (let ((source (%make-source fd interest on-readable on-writable name)))
    (setf (gethash fd (reactor-sources reactor)) source)
    (epoll-add (reactor-epfd reactor) fd (interest-events interest) fd)
    source))

(defun remove-source (reactor source)
  "Forget SOURCE.  The descriptor stays open; closing it is the caller's job."
  (let ((fd (source-fd source)))
    (when (gethash fd (reactor-sources reactor))
      (remhash fd (reactor-sources reactor))
      (epoll-del (reactor-epfd reactor) fd)
      t)))

(defun set-source-interest (reactor source interest)
  "Reprogram a source's epoll interest, e.g. from :write to :read after a flush."
  (setf (fd-source-interest source) interest)
  (epoll-mod (reactor-epfd reactor) (source-fd source)
             (interest-events interest) (source-fd source))
  source)

;;; ---------------------------------------------------------------------------
;;; Timers
;;; ---------------------------------------------------------------------------

(defstruct (timer (:constructor %make-timer (deadline interval function)))
  (deadline 0d0 :type real)
  (interval nil :type (or null real))
  function
  (cancelled-p nil))

(defun add-timer (reactor delay function &key repeat)
  "Call FUNCTION with the timer after DELAY seconds.  With REPEAT (an interval in
seconds) the timer re-arms itself; the deadline advances by whole intervals, so
a loop that slept too long fires once instead of bursting."
  (unless (and (realp delay) (not (minusp delay)))
    (error 'reactor-error :detail (format nil "bad timer delay ~S" delay)))
  (when repeat
    (unless (and (realp repeat) (plusp repeat))
      (error 'reactor-error :detail (format nil "bad repeat interval ~S" repeat))))
  (let ((timer (%make-timer (+ (monotonic-now) delay) repeat function)))
    (push timer (reactor-timers reactor))
    timer))

(defun cancel-timer (reactor timer)
  (setf (timer-cancelled-p timer) t)
  (setf (reactor-timers reactor) (delete timer (reactor-timers reactor)))
  t)

(defun nearest-deadline (reactor)
  (let ((best nil))
    (dolist (timer (reactor-timers reactor) best)
      (unless (timer-cancelled-p timer)
        (when (or (null best) (< (timer-deadline timer) best))
          (setf best (timer-deadline timer)))))))

(defun run-due-timers (reactor)
  (let ((now (monotonic-now))
        (fired 0))
    (dolist (timer (reactor-timers reactor))
      (when (and (not (timer-cancelled-p timer))
                 (<= (timer-deadline timer) now))
        (let ((interval (timer-interval timer)))
          (if interval
              (loop while (<= (timer-deadline timer) now)
                    do (incf (timer-deadline timer) interval))
              (setf (timer-cancelled-p timer) t)))
        (funcall (timer-function timer) timer)
        (incf fired)))
    (when (some #'timer-cancelled-p (reactor-timers reactor))
      (setf (reactor-timers reactor)
            (delete-if #'timer-cancelled-p (reactor-timers reactor))))
    fired))

(defun arm-timer-fd (reactor)
  (let ((deadline (nearest-deadline reactor)))
    (unless (equal deadline (reactor-armed-deadline reactor))
      (wayland.ffi:set-timer-absolute (reactor-timer-fd reactor) deadline)
      (setf (reactor-armed-deadline reactor) deadline))))

;;; ---------------------------------------------------------------------------
;;; Idles and posted commands
;;; ---------------------------------------------------------------------------

(defun add-idle (reactor function)
  "Run FUNCTION once, after the next cycle's descriptors and timers are done."
  (push function (reactor-idles reactor))
  function)

(defun remove-idle (reactor function)
  (setf (reactor-idles reactor) (remove function (reactor-idles reactor)))
  function)

(defun run-idles (reactor)
  (let ((idles (nreverse (reactor-idles reactor))))
    (setf (reactor-idles reactor) nil)
    (dolist (idle idles) (funcall idle))
    (length idles)))

(defun make-command-lock ()
  #+sb-thread (sb-thread:make-mutex :name "wayland.reactor commands")
  #-sb-thread nil)

(defmacro with-command-lock ((reactor) &body body)
  #+sb-thread `(sb-thread:with-mutex ((reactor-command-lock ,reactor)) ,@body)
  #-sb-thread `(progn ,@body))

(defun post (reactor function)
  "Queue FUNCTION to run on the reactor thread, and wake the loop.

Safe from another thread: the queue is locked and the eventfd write makes
epoll_wait return even when nothing else is happening.  This is how the REPL,
the eval socket and the control surface reach the compositor (D14)."
  (with-command-lock (reactor)
    (push function (reactor-commands reactor)))
  (wayland.ffi:signal-event-fd (reactor-wake-fd reactor))
  function)

(defun run-commands (reactor)
  (let ((commands (with-command-lock (reactor)
                    (prog1 (nreverse (reactor-commands reactor))
                      (setf (reactor-commands reactor) nil)))))
    (dolist (command commands)
      (funcall command))
    (length commands)))

;;; ---------------------------------------------------------------------------
;;; The reactor
;;; ---------------------------------------------------------------------------

(defun monotonic-now ()
  "Seconds on the monotonic clock; the only time the reactor uses."
  (wayland.ffi:monotonic-seconds))

(defun make-reactor (&key (max-events *max-events-per-wait*))
  (let ((reactor (%make-reactor)))
    (setf (reactor-max-events reactor) max-events
          (reactor-events reactor)
          (cffi:foreign-alloc :char :count (* +epoll-event-size+ max-events))
          (reactor-command-lock reactor) (make-command-lock)
          (reactor-epfd reactor) (epoll-create)
          (reactor-wake-fd reactor) (wayland.ffi:make-event-fd)
          (reactor-timer-fd reactor) (wayland.ffi:make-timer-fd))
    ;; The wakeup and timer descriptors are sources like any other; their
    ;; callbacks only drain the counter, because everything they trigger
    ;; (commands, due timers) happens at a defined point in the cycle.
    (add-source reactor (reactor-wake-fd reactor)
                :name "wakeup"
                :on-readable (lambda (source events)
                               (declare (ignore events))
                               (wayland.ffi:read-event-fd (source-fd source))))
    (add-source reactor (reactor-timer-fd reactor)
                :name "timer"
                :on-readable (lambda (source events)
                               (declare (ignore events))
                               (wayland.ffi:read-timer-fd (source-fd source))))
    reactor))

(defun close-reactor (reactor)
  "Close every descriptor the reactor owns.  Sources' own descriptors are left
open: they belong to their owners."
  (unless (reactor-closed-p reactor)
    (setf (reactor-closed-p reactor) t)
    (loop for source being the hash-values of (reactor-sources reactor)
          do (ignore-errors (epoll-del (reactor-epfd reactor) (source-fd source))))
    (clrhash (reactor-sources reactor))
    (wayland.ffi:close-fd (reactor-wake-fd reactor))
    (wayland.ffi:close-fd (reactor-timer-fd reactor))
    (wayland.ffi:close-fd (reactor-epfd reactor))
    (unless (cffi:null-pointer-p (reactor-events reactor))
      (cffi:foreign-free (reactor-events reactor))
      (setf (reactor-events reactor) (cffi:null-pointer))
      (setf (reactor-armed-deadline reactor) nil)))
  t)

(defun dispatching-p (reactor)
  (reactor-dispatching-p reactor))

(defun stopped-p (reactor)
  (reactor-stop-p reactor))

(defun request-stop (reactor)
  "Ask RUN to return after the cycle in progress.  Safe from another thread."
  (setf (reactor-stop-p reactor) t)
  (wayland.ffi:signal-event-fd (reactor-wake-fd reactor))
  reactor)

(defun timeout-milliseconds (reactor timeout)
  "The epoll timeout: the caller's limit, further limited by the nearest timer.
NIL means block until something happens; 0 means poll."
  (let* ((deadline (nearest-deadline reactor))
         (timer-limit (when deadline
                        (max 0 (ceiling (* 1000 (- deadline (monotonic-now)))))))
         (caller-limit (when timeout
                         (max 0 (ceiling (* 1000 timeout))))))
    (cond ((and timer-limit caller-limit) (min timer-limit caller-limit))
          (timer-limit timer-limit)
          (caller-limit caller-limit)
          (t nil))))

(defun dispatch-source (reactor source events)
  (declare (ignore reactor))
  (let ((dispatched 0)
        (readable (logior +epoll-in+ +epoll-rdhup+ +epoll-hup+ +epoll-err+)))
    (when (and (logtest events readable) (fd-source-on-readable source))
      (funcall (fd-source-on-readable source) source events)
      (incf dispatched))
    (when (and (logtest events +epoll-out+) (fd-source-on-writable source))
      (funcall (fd-source-on-writable source) source events)
      (incf dispatched))
    dispatched))

(defun dispatch-event (reactor index)
  (let* ((events (event-events (reactor-events reactor) index))
         (fd (event-data (reactor-events reactor) index))
         (source (gethash fd (reactor-sources reactor))))
    (if source
        (dispatch-source reactor source events)
        0)))

(defun run-once (reactor &key timeout)
  "One cycle.  Returns the number of callbacks dispatched."
  (when (reactor-dispatching-p reactor)
    (error 'reactor-reentry))
  (when (reactor-closed-p reactor)
    (error 'reactor-error :detail "reactor is closed"))
  (setf (reactor-dispatching-p reactor) t)
  (unwind-protect
       (let ((dispatched 0))
         ;; 1. Commands queued before we slept.  A command posted by a callback
         ;;    below runs next cycle, so this phase stays the first thing that
         ;;    happens after a wakeup.
         (incf dispatched (run-commands reactor))
         ;; 2. Wait.
         (arm-timer-fd reactor)
         (let ((count (epoll-wait (reactor-epfd reactor)
                                  (reactor-events reactor)
                                  (reactor-max-events reactor)
                                  (timeout-milliseconds reactor timeout))))
           (dotimes (index count)
             (incf dispatched (dispatch-event reactor index))))
         ;; 3. Timers due now.  The deadline check is the authority; the
         ;;    timerfd only ensures we woke up on time.
         (incf dispatched (run-due-timers reactor))
         ;; 4. Idles, once.
         (incf dispatched (run-idles reactor))
         dispatched)
    (setf (reactor-dispatching-p reactor) nil)))

(defun run (reactor &key timeout stop)
  "Run cycles until REQUEST-STOP, STOP returns true, or TIMEOUT seconds elapse.
Returns :stopped or :timeout."
  (let ((deadline (when timeout (+ (monotonic-now) timeout))))
    (setf (reactor-stop-p reactor) nil)
    (loop
      (when (reactor-stop-p reactor)
        (return :stopped))
      (when (or (and stop (funcall stop))
                (and deadline (>= (monotonic-now) deadline)))
        (return :timeout))
      (run-once reactor :timeout (when deadline
                                   (max 0 (- deadline (monotonic-now))))))))

;;; ---------------------------------------------------------------------------
;;; Signals
;;; ---------------------------------------------------------------------------

(defun add-signal-source (reactor signals &key on-signal (name "signals"))
  "Block SIGNALS and deliver them to ON-SIGNAL as (source signal-number).

SIGTERM/SIGINT for shutdown, SIGUSR1 for VT switch, SIGCHLD for children: all
of them arrive as readable events, never as a handler that preempts dispatch."
  (let* ((fd (apply #'wayland.ffi:make-signal-fd signals))
         (source (add-source reactor fd
                             :name name
                             :on-readable
                             (lambda (source events)
                               (declare (ignore events))
                               (loop for signal =
                                     (wayland.ffi:read-signal (source-fd source))
                                     while signal
                                     do (funcall on-signal source signal))))))
    source))

;;; ---------------------------------------------------------------------------
;;; Signals, when signalfd is not enough
;;; ---------------------------------------------------------------------------
;;;
;;; signalfd only sees a process-directed signal if *every* thread blocks it, and
;;; implemented Lisp runtimes have threads of their own: SBCL creates a finalizer
;;; thread on demand, so a SIGTERM sent to the process can be delivered there and
;;; never reach our descriptor.  That is not hypothetical -- it is what happened
;;; the first time the demo server was asked to shut down, and the process stayed
;;; in epoll_wait with the signal unreadable.
;;;
;;; The fix is the shape D9 already demands: an implementation-level handler that
;;; does nothing but enqueue a command.  It may run on any thread, it never
;;; touches protocol state, and the command itself runs between messages at the
;;; top of a cycle.  signalfd stays for signals whose blocking we control from
;;; the start of the image (and for implementations with no extra threads).

#+sbcl
(defun add-signal-handler (reactor signals &key on-signal (name "signals"))
  "Deliver SIGNALS to ON-SIGNAL as (NIL signal-number), via posted commands.

Unlike ADD-SIGNAL-SOURCE this does not block anything, so it works no matter how
many threads the runtime has.  The handler only posts; ON-SIGNAL runs inside a
reactor cycle, between messages, exactly like any other command (see the comment
above).  NAME is accepted and ignored, so call sites read the same either way.

The handler stays installed for the life of the process, and a signal that
arrives after the reactor closed is ignored rather than posted."
  (declare (ignore name))
  (dolist (signal signals)
    ;; SB-SYS:ENABLE-INTERRUPT takes the number, not a keyword (SBCL 2.6 passes
    ;; its argument straight to the alien call).
    (sb-sys:enable-interrupt
     signal
     (lambda (signal-number code context)
       (declare (ignore code context))
       (unless (reactor-closed-p reactor)
         (post reactor (lambda () (funcall on-signal nil signal-number)))))))
  t)

#-sbcl
(defun add-signal-handler (reactor signals &key on-signal (name "signals"))
  "On implementations without extra runtime threads, a signalfd source is the
same thing and costs less."
  (add-signal-source reactor signals :on-signal on-signal :name name))
