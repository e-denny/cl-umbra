;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; The syscall edge: sockets, sendmsg/recvmsg with SCM_RIGHTS, errno.
;;;;
;;;; This is libc, not libwayland (decision D1).  Every constant here is a
;;;; Linux value, and the struct layouts are asserted at load time: a wrong
;;;; MSG_CMSG_CLOEXEC or a mismatched msghdr is a silent descriptor leak, and
;;;; that is exactly the class of bug nobody notices until a compositor has
;;;; been up for three days.
;;;;
;;;; The 64-bit assumption is deliberate and checked.  A 32-bit build would
;;;; need different struct layouts; we would rather fail loudly at load time.

(in-package #:wayland.ffi)

;;; ---------------------------------------------------------------------------
;;; Linux constants
;;; ---------------------------------------------------------------------------

(defconstant +af-unix+ 1)
(defconstant +sock-stream+ 1)
(defconstant +sock-nonblock+ #x800)     ; O_NONBLOCK
(defconstant +sock-cloexec+ #x80000)    ; O_CLOEXEC

(defconstant +sol-socket+ 1)
(defconstant +scm-rights+ 1)

(defconstant +msg-nosignal+ #x4000)
(defconstant +msg-cmsg-cloexec+ #x40000000)
(defconstant +msg-ctrunc+ #x8)
(defconstant +msg-dontwait+ #x40)

(defconstant +f-getfd+ 1)
(defconstant +f-setfd+ 2)
(defconstant +f-getfl+ 3)
(defconstant +f-setfl+ 4)
(defconstant +fd-cloexec+ 1)
(defconstant +o-nonblock+ #x800)

(defconstant +mfd-cloexec+ 1)

(defconstant +eintr+ 4)
(defconstant +ebadf+ 9)
(defconstant +eagain+ 11)
(defconstant +epipe+ 32)
(defconstant +emsgsize+ 90)
(defconstant +econnreset+ 104)

;;; ---------------------------------------------------------------------------
;;; C structures
;;; ---------------------------------------------------------------------------

(cffi:defcstruct (iovec :conc-name iovec-)
  (base :pointer)
  (length :size))

;; struct msghdr, linux/socket.h.  CFFI inserts the same padding the C compiler
;; does; the load-time check below catches a field list that drifted.
(cffi:defcstruct (msghdr :conc-name msghdr-)
  (name :pointer)
  (namelen :unsigned-int)
  (iov :pointer)
  (iovlen :size)
  (control :pointer)
  (controllen :size)
  (flags :int))

;; struct cmsghdr: size_t cmsg_len, int cmsg_level, int cmsg_type.
(cffi:defcstruct (cmsghdr :conc-name cmsghdr-)
  (len :size)
  (level :int)
  (type :int))

(defconstant +cmsghdr-size+ 16
  "sizeof(struct cmsghdr) on 64-bit Linux: 8 + 4 + 4, no tail padding.")

(defun cmsg-align (length)
  "CMSG_ALIGN: round LENGTH up to the alignment of size_t."
  (let ((alignment (cffi:foreign-type-size :size)))
    (logand (+ length (1- alignment)) (lognot (1- alignment)))))

(defun cmsg-space (length)
  "CMSG_SPACE: bytes needed for one control message carrying LENGTH bytes."
  (+ +cmsghdr-size+ (cmsg-align length)))

(defun check-abi ()
  "Fail loudly at load time if the C layouts are not the ones this file assumes.
SBCL constant-folds the comparisons and deletes the ERROR branch when they hold,
which is the proof we want; other implementations simply run the check."
  (unless (and (= 8 (cffi:foreign-type-size :pointer))
               (= 8 (cffi:foreign-type-size :size))
               (= 16 (cffi:foreign-type-size '(:struct cmsghdr)))
               (= 16 (cffi:foreign-type-size '(:struct iovec)))
               (= 56 (cffi:foreign-type-size '(:struct msghdr))))
    (error "wayland.ffi: unexpected ABI (pointer ~D, size_t ~D, cmsghdr ~D, iovec ~D, msghdr ~D); check the struct layouts against linux/socket.h"
           (cffi:foreign-type-size :pointer)
           (cffi:foreign-type-size :size)
           (cffi:foreign-type-size '(:struct cmsghdr))
           (cffi:foreign-type-size '(:struct iovec))
           (cffi:foreign-type-size '(:struct msghdr)))))

(eval-when (:load-toplevel :execute)
  (check-abi))

;;; ---------------------------------------------------------------------------
;;; libc
;;; ---------------------------------------------------------------------------

(cffi:defcfun ("socketpair" %socketpair) :int
  (domain :int) (type :int) (protocol :int) (pair :pointer))

(cffi:defcfun ("sendmsg" %sendmsg) :ssize
  (fd :int) (message :pointer) (flags :int))

(cffi:defcfun ("recvmsg" %recvmsg) :ssize
  (fd :int) (message :pointer) (flags :int))

(cffi:defcfun ("close" %close) :int
  (fd :int))

(cffi:defcfun ("fcntl" %fcntl) :int
  (fd :int) (command :int) (argument :int))

(cffi:defcfun ("memfd_create" %memfd-create) :int
  (name :string) (flags :unsigned-int))

(cffi:defcfun ("__errno_location" %errno-location) :pointer)

(cffi:defcfun ("strerror" %strerror) :string
  (error-number :int))

(defun errno ()
  "The calling thread's errno (glibc's __errno_location)."
  (cffi:mem-ref (%errno-location) :int))

(defun strerror (error-number)
  (%strerror error-number))

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition io-error (error)
  ((operation :initarg :operation :reader io-error-operation)
   (error-number :initarg :errno :reader io-error-errno))
  (:report (lambda (condition stream)
             (format stream "~A failed: ~A (errno ~D)"
                     (io-error-operation condition)
                     (strerror (io-error-errno condition))
                     (io-error-errno condition)))))

(define-condition connection-closed (io-error) ()
  (:report (lambda (condition stream)
             (format stream "~A: peer closed the connection (errno ~D, ~A)"
                     (io-error-operation condition)
                     (io-error-errno condition)
                     (strerror (io-error-errno condition))))))

(defun syscall-failed (operation error-number)
  "Signal the right condition for a failed syscall."
  (error (if (member error-number (list +epipe+ +econnreset+))
             'connection-closed
             'io-error)
         :operation operation
         :errno error-number))

(defun %retry-on-eintr (thunk)
  (loop for result = (funcall thunk)
        unless (and (minusp result) (= (errno) +eintr+))
          return result))

;;; ---------------------------------------------------------------------------
;;; Descriptors
;;; ---------------------------------------------------------------------------

(defun make-socket-pair (&key (nonblocking t) (cloexec t))
  "A connected AF_UNIX stream pair.  Both ends are non-blocking and close-on-exec
by default: those flags are set atomically at creation, never raced."
  (let ((type (logior +sock-stream+
                      (if nonblocking +sock-nonblock+ 0)
                      (if cloexec +sock-cloexec+ 0))))
    (cffi:with-foreign-object (pair :int 2)
      (let ((result (%retry-on-eintr
                     (lambda () (%socketpair +af-unix+ type 0 pair)))))
        (when (minusp result)
          (syscall-failed 'socketpair (errno))))
      (values (cffi:mem-aref pair :int 0)
              (cffi:mem-aref pair :int 1)))))

(defun close-fd (fd)
  "Close FD, ignoring EBADF.  Closing twice is a bug, but not one worth a
debugger entry in a teardown path."
  (when fd
    (%retry-on-eintr (lambda () (%close fd))))
  nil)

(defun fd-open-p (fd)
  (and (integerp fd)
       (>= (%fcntl fd +f-getfd+ 0) 0)))

(defun fd-cloexec-p (fd)
  "True when FD carries FD_CLOEXEC, i.e. it will not leak into a child."
  (let ((flags (%fcntl fd +f-getfd+ 0)))
    (and (>= flags 0) (logtest flags +fd-cloexec+))))

(defun set-fd-nonblocking (fd)
  (let ((flags (%fcntl fd +f-getfl+ 0)))
    (when (minusp flags)
      (syscall-failed 'fcntl (errno)))
    (when (minusp (%fcntl fd +f-setfl+ (logior flags +o-nonblock+)))
      (syscall-failed 'fcntl (errno))))
  fd)

(defun memfd-create (name &key (cloexec t))
  "A sealed-capable anonymous file, as wl_shm pools want.  MFD_CLOEXEC by
default so a pool can never leak into xwayland or a spawned client."
  (let ((fd (%retry-on-eintr
             (lambda () (%memfd-create name (if cloexec +mfd-cloexec+ 0))))))
    (when (minusp fd)
      (syscall-failed 'memfd-create (errno)))
    fd))

;;; ---------------------------------------------------------------------------
;;; sendmsg / recvmsg
;;; ---------------------------------------------------------------------------

(defun send-with-ancillary (fd octets start end fds &key (flags +msg-nosignal+))
  "sendmsg(2) OCTETS[START:END], attaching FDS as SCM_RIGHTS.

Returns the number of octets written.  0 means EAGAIN: nothing was written and
the descriptors are still the caller's.  EINTR is retried.  A short write is
normal and not an error: the descriptors travel with the octets that did go
out, which is exactly where the peer expects them.

MSG_NOSIGNAL by default, so a dead peer is an EPIPE we handle rather than a
SIGPIPE that kills the image."
  (when (= start end)
    (return-from send-with-ancillary 0))
  (let* ((count (length fds))
         (data-size (* 4 count))
         (control-size (if (plusp count) (cmsg-space data-size) 0))
         (control (if (plusp control-size)
                      (cffi:foreign-alloc :char :count control-size)
                      (cffi:null-pointer))))
    (unwind-protect
         (cffi:with-foreign-object (iov '(:struct iovec))
           (cffi:with-foreign-object (message '(:struct msghdr))
             (cffi:with-pointer-to-vector-data (data octets)
               (setf (iovec-base iov) (cffi:inc-pointer data start)
                     (iovec-length iov) (- end start))
               (setf (msghdr-name message) (cffi:null-pointer)
                     (msghdr-namelen message) 0
                     (msghdr-iov message) iov
                     (msghdr-iovlen message) 1
                     (msghdr-control message) control
                     (msghdr-controllen message) control-size
                     (msghdr-flags message) 0)
               (when (plusp count)
                 ;; One cmsghdr holding COUNT ints.
                 (setf (cffi:mem-ref control :size 0) (+ +cmsghdr-size+ data-size)
                       (cffi:mem-ref control :int 8) +sol-socket+
                       (cffi:mem-ref control :int 12) +scm-rights+)
                 (loop for descriptor in fds
                       for index from 0
                       do (setf (cffi:mem-ref control
                                             :int (+ +cmsghdr-size+ (* 4 index)))
                                descriptor)))
               (let ((result (%retry-on-eintr
                              (lambda () (%sendmsg fd message flags)))))
                 (cond ((>= result 0) result)
                       ((= (errno) +eagain+) 0)
                       (t (syscall-failed 'sendmsg (errno))))))))
      (unless (cffi:null-pointer-p control)
        (cffi:foreign-free control)))))

(defun receive-with-ancillary (fd octets start end
                               &key (fds-max 28) (flags +msg-cmsg-cloexec+))
  "recvmsg(2) into OCTETS[START:END].

Returns (values octets-received received-fds truncated-p eof-p).

TRUNCATED-P means the kernel had to drop descriptors: the ones returned are
still valid and the caller must close them, but the dropped ones are gone
forever, so the connection has to die.  EOF-P means the peer closed and no
octets arrived.  MSG_CMSG_CLOEXEC is requested, so received descriptors never
leak into a child."
  (let ((control (cffi:foreign-alloc :char :count (cmsg-space (* 4 fds-max)))))
    (unwind-protect
         (cffi:with-foreign-object (iov '(:struct iovec))
           (cffi:with-foreign-object (message '(:struct msghdr))
             (cffi:with-pointer-to-vector-data (data octets)
               (setf (iovec-base iov) (cffi:inc-pointer data start)
                     (iovec-length iov) (- end start))
               (setf (msghdr-name message) (cffi:null-pointer)
                     (msghdr-namelen message) 0
                     (msghdr-iov message) iov
                     (msghdr-iovlen message) 1
                     (msghdr-control message) control
                     (msghdr-controllen message) (cmsg-space (* 4 fds-max))
                     (msghdr-flags message) 0)
               (loop
                 for result = (%recvmsg fd message flags)
                 do (cond
                      ((>= result 0)
                       (return (parse-control control
                                              (msghdr-controllen message)
                                              (msghdr-flags message)
                                              result)))
                      ((= (errno) +eintr+))          ; retry
                      ((= (errno) +eagain+)
                       (return (values 0 nil nil nil)))
                      (t (syscall-failed 'recvmsg (errno))))))))
      (cffi:foreign-free control))))

(defun parse-control (control controllen msg-flags octets-read)
  "Walk the control messages and collect SCM_RIGHTS descriptors."
  (let ((fds '())
        (offset 0)
        (truncated (logtest msg-flags +msg-ctrunc+)))
    (loop
      while (<= (+ offset +cmsghdr-size+) controllen)
      do (let ((length (cffi:mem-ref control :size offset)))
           (when (< length +cmsghdr-size+)
             (return))
           (let ((level (cffi:mem-ref control :int (+ offset 8)))
                 (kind (cffi:mem-ref control :int (+ offset 12))))
             (when (and (= level +sol-socket+) (= kind +scm-rights+))
               (let* ((data-start (+ offset +cmsghdr-size+))
                      (data-end (min (+ offset length) controllen))
                      (count (max 0 (floor (- data-end data-start) 4))))
                 (dotimes (index count)
                   (push (cffi:mem-ref control :int (+ data-start (* 4 index)))
                         fds)))))
           (let ((next (+ offset (cmsg-align length))))
             (when (<= next offset)
               (return))
             (setf offset next))))
    (values octets-read
            (nreverse fds)
            truncated
            (zerop octets-read))))

;;; ---------------------------------------------------------------------------
;;; Clocks and plain byte streams
;;; ---------------------------------------------------------------------------

(cffi:defcstruct (timespec :conc-name timespec-)
  (seconds :long)
  (nanoseconds :long))

(cffi:defcfun ("clock_gettime" %clock-gettime) :int
  (clock-id :int) (time :pointer))

(defconstant +clock-monotonic+ 1)

(defun monotonic-seconds ()
  "CLOCK_MONOTONIC as seconds, for deadlines that must not jump when the wall
clock is adjusted."
  (cffi:with-foreign-object (time '(:struct timespec))
    (when (minusp (%clock-gettime +clock-monotonic+ time))
      (syscall-failed 'clock-gettime (errno)))
    (+ (timespec-seconds time)
       (/ (timespec-nanoseconds time) 1d9))))

(cffi:defcfun ("read" %read) :ssize
  (fd :int) (buffer :pointer) (count :size))

(cffi:defcfun ("write" %write) :ssize
  (fd :int) (buffer :pointer) (count :size))

(defun read-into-pointer (fd pointer length)
  "read(2) into foreign memory.

Returns (values octets-read eof-p).  EAGAIN returns zero and no EOF; a zero
return with LENGTH above zero is end of stream.  EINTR is retried."
  (loop
    (let ((result (%read fd pointer length)))
      (cond ((>= result 0)
             (return (values result (and (plusp length) (zerop result)))))
            ((= (errno) +eintr+))
            ((= (errno) +eagain+) (return (values 0 nil)))
            (t (syscall-failed 'read (errno)))))))

(defun read-into (fd octets start end)
  "read(2) into OCTETS[START:END].  Returns (values octets-read eof-p)."
  (cffi:with-pointer-to-vector-data (data octets)
    (read-into-pointer fd (cffi:inc-pointer data start) (- end start))))

(defun write-from-pointer (fd pointer length)
  "write(2); returns the octets written, zero on EAGAIN.  EINTR is retried."
  (loop
    (let ((result (%write fd pointer length)))
      (cond ((>= result 0) (return result))
            ((= (errno) +eintr+))
            ((= (errno) +eagain+) (return 0))
            (t (syscall-failed 'write (errno)))))))

;;; ---------------------------------------------------------------------------
;;; eventfd, timerfd, signalfd
;;; ---------------------------------------------------------------------------
;;;
;;; These three exist to feed epoll, which is why they live at the syscall edge
;;; and not in the reactor: the reactor decides *when* to arm a timer, this file
;;; only knows how.

(defconstant +efd-nonblock+ #x800)
(defconstant +efd-cloexec+ #x80000)
(defconstant +tfd-nonblock+ #x800)
(defconstant +tfd-cloexec+ #x80000)
(defconstant +tfd-timer-abstime+ 1)
(defconstant +sfd-nonblock+ #x800)
(defconstant +sfd-cloexec+ #x80000)

(defconstant +sig-block+ 0)
(defconstant +sig-unblock+ 1)
(defconstant +sigmask-size+ 128
  "sizeof(sigset_t) on 64-bit Linux: 16 unsigned longs.")
(defconstant +signalfd-siginfo-size+ 128
  "sizeof(struct signalfd_siginfo); ssi_signo is the first u32.")
(defconstant +itimerspec-size+ 32
  "sizeof(struct itimerspec): interval and value, two timespecs of two longs.")
(defconstant +sig-ign+ 1
  "SIG_IGN as a handler pointer.")

(defconstant +sigint+ 2)
(defconstant +sigusr1+ 10)
(defconstant +sigpipe+ 13)
(defconstant +sigterm+ 15)
(defconstant +sigchld+ 17)

(cffi:defcfun ("eventfd" %eventfd) :int
  (initial-value :unsigned-int) (flags :int))

(cffi:defcfun ("timerfd_create" %timerfd-create) :int
  (clock-id :int) (flags :int))

(cffi:defcfun ("timerfd_settime" %timerfd-settime) :int
  (fd :int) (flags :int) (new-value :pointer) (old-value :pointer))

(cffi:defcfun ("signalfd" %signalfd) :int
  (fd :int) (mask :pointer) (flags :int))

(cffi:defcfun ("sigemptyset" %sigemptyset) :int (set :pointer))
(cffi:defcfun ("sigaddset" %sigaddset) :int (set :pointer) (signal :int))
(cffi:defcfun ("pthread_sigmask" %pthread-sigmask) :int
  (how :int) (set :pointer) (old-set :pointer))
(cffi:defcfun ("raise" %raise) :int (signal :int))
(cffi:defcfun ("signal" %signal) :pointer (signal :int) (handler :pointer))

(defun check-fd (fd operation)
  (when (minusp fd)
    (syscall-failed operation (errno)))
  fd)

(defun make-event-fd ()
  "A non-blocking, close-on-exec eventfd counter, for waking the loop."
  (check-fd (%eventfd 0 (logior +efd-nonblock+ +efd-cloexec+)) 'eventfd))

(defun read-event-fd (fd)
  "Read and reset the counter.  Zero when nothing is pending (EAGAIN)."
  (cffi:with-foreign-object (value :uint64)
    (multiple-value-bind (count) (read-into-pointer fd value 8)
      (if (plusp count) (cffi:mem-ref value :uint64) 0))))

(defun signal-event-fd (fd)
  "Increment the counter.  EAGAIN means it is already saturated, which is a
wakeup either way."
  (cffi:with-foreign-object (value :uint64)
    (setf (cffi:mem-ref value :uint64) 1)
    (write-from-pointer fd value 8)))

(defun make-timer-fd ()
  (check-fd (%timerfd-create +clock-monotonic+
                             (logior +tfd-nonblock+ +tfd-cloexec+))
            'timerfd-create))

(defun set-timer-absolute (fd seconds)
  "Arm the timerfd for the absolute CLOCK_MONOTONIC time SECONDS, or disarm it
when SECONDS is NIL.  A time in the past fires immediately, which is what a
deadline that slipped during dispatch should do."
  (declare (type (or null real) seconds))
  (cffi:with-foreign-object (spec :char +itimerspec-size+)
    (dotimes (index 4)
      (setf (cffi:mem-ref spec :long (* index 8)) 0))
    (when seconds
      (let* ((whole (floor seconds))
             (fraction (round (* (- seconds whole) 1000000000))))
        (when (>= fraction 1000000000)
          (incf whole)
          (decf fraction 1000000000))
        (setf (cffi:mem-ref spec :long 16) whole
              (cffi:mem-ref spec :long 24) fraction)))
    (when (minusp (%timerfd-settime fd +tfd-timer-abstime+ spec
                                    (cffi:null-pointer)))
      (syscall-failed 'timerfd-settime (errno)))))

(defun read-timer-fd (fd)
  "Expirations since the last read; zero on EAGAIN."
  (cffi:with-foreign-object (value :uint64)
    (multiple-value-bind (count) (read-into-pointer fd value 8)
      (if (plusp count) (cffi:mem-ref value :uint64) 0))))

(defun make-signal-fd (&rest signal-numbers)
  "Block SIGNAL-NUMBERS in the calling thread and return a signalfd for them.

Blocking is the point: a signal that is blocked stays pending, so this thread
can read it from the descriptor instead of having a handler preempt a dispatch.
SIGCHLD for children and SIGTERM/SIGUSR1 for shutdown go here, not in handlers."
  (cffi:with-foreign-object (mask :char +sigmask-size+)
    (%sigemptyset mask)
    (dolist (signal signal-numbers)
      (%sigaddset mask signal))
    (when (minusp (%pthread-sigmask +sig-block+ mask (cffi:null-pointer)))
      (syscall-failed 'pthread-sigmask (errno)))
    (check-fd (%signalfd -1 mask (logior +sfd-nonblock+ +sfd-cloexec+))
              'signalfd)))

(defun unblock-signals (&rest signal-numbers)
  (cffi:with-foreign-object (mask :char +sigmask-size+)
    (%sigemptyset mask)
    (dolist (signal signal-numbers)
      (%sigaddset mask signal))
    (when (minusp (%pthread-sigmask +sig-unblock+ mask (cffi:null-pointer)))
      (syscall-failed 'pthread-sigmask (errno)))))

(defun read-signal (fd)
  "The next pending signal number, or NIL when none is queued."
  (cffi:with-foreign-object (info :char +signalfd-siginfo-size+)
    (multiple-value-bind (count) (read-into-pointer fd info +signalfd-siginfo-size+)
      (if (plusp count)
          (cffi:mem-ref info :uint32 0)
          nil))))

(defun raise-signal (signal)
  (when (minusp (%raise signal))
    (syscall-failed 'raise (errno))))

(defun ignore-sigpipe ()
  "Ignore SIGPIPE process-wide.  A compositor whose clients vanish constantly
must see EPIPE from write(2), not die from a signal."
  (%signal +sigpipe+ (cffi:make-pointer +sig-ign+))
  nil)
