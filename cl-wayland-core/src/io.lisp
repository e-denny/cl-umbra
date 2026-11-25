;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Transport: message buffers out, message stream in.
;;;;
;;;; WAYLAND.WIRE owns the octets; this file owns the socket.  Two directions:
;;;;
;;;;   flush-buffer  out buffer -> sendmsg, descriptors attached, partial
;;;;                 writes trimmed, EAGAIN reported as zero.
;;;;
;;;;   pump          recvmsg -> input buffer -> whole messages -> handler,
;;;;                 with a partial tail left for the next read.
;;;;
;;;; The rule that makes descriptors work: they ride with the first octets of a
;;;; write, exactly as libwayland does, and the receiver queues them in arrival
;;;; order and hands them to messages in argument order.

(in-package #:wayland.io)

;;; ---------------------------------------------------------------------------
;;; Outbound
;;; ---------------------------------------------------------------------------

(defun flush-buffer (socket buffer)
  "Write as much of BUFFER as the socket accepts; return the octets written.

Zero means EAGAIN and nothing was consumed.  A successful write consumes the
descriptor queue even if the write was short, because the descriptors were
attached to the octets that did go out."
  (let ((size (buffer-size buffer)))
    (when (zerop size)
      (return-from flush-buffer 0))
    (let ((written (wayland.ffi:send-with-ancillary
                    socket
                    (buffer-octets buffer)
                    0 size
                    (buffer-fds buffer))))
      (when (plusp written)
        (trim-buffer buffer written :drop-fds t))
      written)))

;;; ---------------------------------------------------------------------------
;;; Inbound
;;; ---------------------------------------------------------------------------

(defstruct (input-buffer (:constructor %make-input-buffer (octets size fds)))
  ;; Simple array, explicit size: recvmsg writes straight into the free tail
  ;; through a pinned pointer.
  (octets (make-array 65536 :element-type '(unsigned-byte 8))
          :type (simple-array (unsigned-byte 8) (*)))
  (size 0 :type fixnum)
  ;; Descriptors that have arrived but not yet been claimed by a message,
  ;; in arrival order.
  (fds '() :type list))

(defun make-input-buffer (&key (capacity 65536))
  (%make-input-buffer (make-array (max capacity 1)
                                  :element-type '(unsigned-byte 8))
                      0
                      nil))

(defun input-buffer-capacity (input-buffer)
  "Allocated octets, which is the number the allocation bound is checked against."
  (length (input-buffer-octets input-buffer)))

(defun input-buffer-pending-octets (input-buffer)
  "Octets received but not yet forming a whole message."
  (input-buffer-size input-buffer))

(defun input-buffer-pending-fds (input-buffer)
  "Descriptors received but not yet claimed by a message."
  (input-buffer-fds input-buffer))

(defun reset-input-buffer (input-buffer &key (close-fds t))
  "Discard pending octets and the descriptor queue; return closed descriptors.

For when the stream can no longer be trusted -- a protocol error, a dead
connection, or a fuzzer feeding garbage -- rather than for ordinary partial
messages.  Descriptors that arrived are duplicates the kernel made for us and
nobody else will close them, so they are closed here unless the caller has
already taken ownership and passes :CLOSE-FDS NIL."
  (let ((fds (input-buffer-fds input-buffer)))
    (when close-fds
      (dolist (fd fds) (wayland.ffi:close-fd fd)))
    (setf (input-buffer-size input-buffer) 0)
    (setf (input-buffer-fds input-buffer) nil)
    (if close-fds (length fds) 0)))

(defun ensure-input-room (input-buffer extra)
  (let* ((octets (input-buffer-octets input-buffer))
         (size (input-buffer-size input-buffer))
         (capacity (length octets))
         (needed (+ size extra)))
    (when (> needed capacity)
      (let ((new (make-array (max needed (* 2 capacity) 1024)
                             :element-type '(unsigned-byte 8))))
        (replace new octets :end2 size)
        (setf (input-buffer-octets input-buffer) new)))
    input-buffer))

(defun pump (socket input-buffer handler &key (max-receives 16))
  "Read everything the socket has, then dispatch every complete message.

HANDLER is called with (object-id opcode reader).  Descriptors are claimed from
the reader in argument order, so a handler that reads fewer descriptors than
the message carried leaves the rest queued for the next message -- a bug the
protocol layer will catch, not this one.

Returns the number of messages dispatched.  Signals WAYLAND.FFI:CONNECTION-CLOSED
at end of stream (after dispatching what arrived), and TRUNCATED-DESCRIPTORS
when the kernel dropped descriptors."
  (let ((eof nil))
    (loop repeat max-receives
      do (ensure-input-room input-buffer 1)
      (multiple-value-bind (count fds truncated-p eof-p)
          (wayland.ffi:receive-with-ancillary
           socket
           (input-buffer-octets input-buffer)
           (input-buffer-size input-buffer)
           (length (input-buffer-octets input-buffer))
           :fds-max +max-fds-per-flush+)
        (when truncated-p
          ;; We have already lost descriptors; close the ones that did arrive so
          ;; they do not join the leak, and let the connection die.
          (dolist (fd fds)
            (wayland.ffi:close-fd fd))
          (error 'truncated-descriptors :count (length fds)))
        (when fds
          (setf (input-buffer-fds input-buffer)
                (nconc (input-buffer-fds input-buffer) fds)))
        (incf (input-buffer-size input-buffer) count)
        (when eof-p
          (setf eof t)
          (return))
        (when (zerop count)
          (return))))                   ; EAGAIN: nothing more right now
    (let ((dispatched (drain-input input-buffer handler)))
      (when eof
        (error 'wayland.ffi:connection-closed
               :operation 'pump
               :errno wayland.ffi:+epipe+))
      dispatched)))

(define-condition truncated-descriptors (error)
  ((count :initarg :count :reader truncated-descriptors-count))
  (:report (lambda (condition stream)
             (format stream
                     "received descriptors were truncated (~D arrived, more were dropped); the connection cannot be trusted"
                     (truncated-descriptors-count condition)))))

(defun drain-input (input-buffer handler)
  "Dispatch every complete message in INPUT-BUFFER; keep the partial tail."
  (let* ((octets (input-buffer-octets input-buffer))
         (end (input-buffer-size input-buffer))
         (start 0)
         (dispatched 0))
    (loop
      (multiple-value-bind (object-id opcode size)
          (decode-header octets :start start :end end)
        (unless object-id
          (return))                     ; not even a full header yet
        (when (> (+ start size) end)
          (return))                     ; header but not the body
        (let ((reader (make-reader octets
                                   :start (+ start +header-size+)
                                   :end (+ start size)
                                   :fds (coerce (input-buffer-fds input-buffer)
                                                'vector))))
          (funcall handler object-id opcode reader)
          (let ((claimed (reader-fds-consumed reader)))
            (when (plusp claimed)
              (setf (input-buffer-fds input-buffer)
                    (nthcdr claimed (input-buffer-fds input-buffer)))))
          (incf start size)
          (incf dispatched))))
    (when (plusp start)
      (replace octets octets :start1 0 :start2 start :end2 end)
      (setf (input-buffer-size input-buffer) (- end start)))
    dispatched))
