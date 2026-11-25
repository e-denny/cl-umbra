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
