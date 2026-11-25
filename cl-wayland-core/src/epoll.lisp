;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; epoll: the only level-triggered wait in the system.
;;;;
;;;; Level-triggered, never edge-triggered (docs/protocol-layer.md §7): the
;;;; caller reads until EAGAIN and we simply ask again next cycle.  Edge
;;;; triggering would require every source to remember partial state, and a
;;;; client that trickles half a message would be dispatched far too late.

(in-package #:wayland.reactor)

;;; ---------------------------------------------------------------------------
;;; Constants (linux/eventpoll.h, x86-64)
;;; ---------------------------------------------------------------------------

(defconstant +epoll-in+ #x1)
(defconstant +epoll-out+ #x4)
(defconstant +epoll-err+ #x8)
(defconstant +epoll-hup+ #x10)
(defconstant +epoll-rdhup+ #x2000)
(defconstant +epoll-cloexec+ #x80000)

(defconstant +epoll-ctl-add+ 1)
(defconstant +epoll-ctl-del+ 2)
(defconstant +epoll-ctl-mod+ 3)

(defconstant +epoll-event-size+ 12
  "sizeof(struct epoll_event) on x86-64: uint32 events, then the 8-byte data
union, with __attribute__((packed)) -- so the data starts at offset 4, not 8.
CFFI would pad it to 16, which is why this file addresses the bytes by hand.")

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition epoll-error (wayland.ffi:io-error) ()
  (:default-initargs :operation 'epoll))

(defun epoll-check (result operation)
  (when (minusp result)
    (error 'epoll-error :operation operation :errno (wayland.ffi:errno)))
  result)

;;; ---------------------------------------------------------------------------
;;; libc
;;; ---------------------------------------------------------------------------

(cffi:defcfun ("epoll_create1" %epoll-create1) :int
  (flags :int))

(cffi:defcfun ("epoll_ctl" %epoll-ctl) :int
  (epoll-fd :int) (operation :int) (fd :int) (event :pointer))

(cffi:defcfun ("epoll_wait" %epoll-wait) :int
  (epoll-fd :int) (events :pointer) (max-events :int) (timeout :int))

;;; ---------------------------------------------------------------------------
;;; Wrapper
;;; ---------------------------------------------------------------------------

(defun epoll-create ()
  "An epoll instance with EPOLL_CLOEXEC: it must not leak into xwayland."
  (epoll-check (%epoll-create1 +epoll-cloexec+) 'epoll-create1))

(defun set-event (event events data)
  "Write a packed epoll_event: uint32 events, then uint64 data at offset 4."
  (setf (cffi:mem-ref event :uint32 0) events)
  (setf (cffi:mem-ref event :uint64 4) data)
  event)

(defun epoll-add (epoll-fd fd events data)
  (cffi:with-foreign-object (event :char +epoll-event-size+)
    (set-event event events data)
    (epoll-check (%epoll-ctl epoll-fd +epoll-ctl-add+ fd event) 'epoll-ctl)))

(defun epoll-mod (epoll-fd fd events data)
  (cffi:with-foreign-object (event :char +epoll-event-size+)
    (set-event event events data)
    (epoll-check (%epoll-ctl epoll-fd +epoll-ctl-mod+ fd event) 'epoll-ctl)))

(defun epoll-del (epoll-fd fd)
  ;; The event argument is ignored for EPOLL_CTL_DEL on Linux.
  (epoll-check (%epoll-ctl epoll-fd +epoll-ctl-del+ fd (cffi:null-pointer))
               'epoll-ctl))

(defun epoll-wait (epoll-fd buffer max-events timeout-ms)
  "Wait for ready events.  TIMEOUT-MS is milliseconds, 0 to poll, NIL to block
until something happens.  Returns the number of events written to BUFFER."
  (loop
    (let ((result (%epoll-wait epoll-fd buffer max-events
                               (if timeout-ms timeout-ms -1))))
      (cond ((>= result 0) (return result))
            ((= (wayland.ffi:errno) wayland.ffi:+eintr+) (return 0))
            (t (error 'epoll-error :operation 'epoll-wait
                                   :errno (wayland.ffi:errno)))))))

(defun event-events (buffer index)
  "The event mask of the INDEXth packed epoll_event in BUFFER."
  (cffi:mem-ref buffer :uint32 (* index +epoll-event-size+)))

(defun event-data (buffer index)
  "The 64-bit data word the registration stored: we store the file descriptor."
  (cffi:mem-ref buffer :uint64 (+ (* index +epoll-event-size+) 4)))
