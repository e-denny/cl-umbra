;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Transport tests: a real AF_UNIX socket pair, real descriptors from
;;;; memfd_create, and the 28-descriptor ceiling measured rather than assumed.
;;;; See docs/testing.md §3-4.

(in-package #:cl-user)

(defpackage #:wayland.test.io
  (:use #:cl #:rove)
  (:local-nicknames (#:ffi #:wayland.ffi)
                    (#:io #:wayland.io)
                    (#:wire #:wayland.wire))
  (:documentation "Tests for wayland.io and wayland.ffi."))

(in-package #:wayland.test.io)

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun encode (object-id opcode &optional writer)
  (let ((buffer (wire:make-message-buffer)))
    (let ((start (wire:begin-message buffer object-id opcode)))
      (when writer (funcall writer buffer))
      (wire:end-message buffer start))
    buffer))

(defun buffer-contents (buffer)
  (wire:buffer-contents buffer))

(defmacro with-socket-pair ((writer reader &key (nonblocking t)) &body body)
  (let ((w (gensym "WRITER")) (r (gensym "READER")))
    `(multiple-value-bind (,w ,r) (ffi:make-socket-pair :nonblocking ,nonblocking)
       (let ((,writer ,w) (,reader ,r))
         (declare (ignorable ,writer ,reader))
         (unwind-protect (progn ,@body)
           (ffi:close-fd ,w)
           (ffi:close-fd ,r))))))

(defmacro with-memfd ((var &optional (name "cl-wayland-test")) &body body)
  `(let ((,var (ffi:memfd-create ,name)))
     (unwind-protect (progn ,@body)
       (ffi:close-fd ,var))))

(defun make-descriptors (count)
  (loop repeat count collect (ffi:memfd-create "cl-wayland-test")))

(defun close-descriptors (descriptors)
  (dolist (fd descriptors) (ffi:close-fd fd)))

(defun receive-all (reader octets &key (fds-max 28))
  (ffi:receive-with-ancillary reader octets 0 (length octets) :fds-max fds-max))

;;; ---------------------------------------------------------------------------
;;; Plain octets
;;; ---------------------------------------------------------------------------

(deftest flush-then-receive
  (with-socket-pair (writer reader)
    (let* ((buffer (encode 1 0 (lambda (b) (wire:put-string b "hello"))))
           (expected (buffer-contents buffer)))
      (ok (eql (length expected) (io:flush-buffer writer buffer)))
      (ok (zerop (wire:buffer-size buffer)) "a completed flush empties the buffer")
      (let ((target (make-array 64 :element-type '(unsigned-byte 8))))
        (multiple-value-bind (count fds truncated eof) (receive-all reader target)
          (ok (eql (length expected) count))
          (ok (equalp expected (subseq target 0 count)))
          (ok (null fds))
          (ok (not truncated))
          (ok (not eof)))))))

(deftest flush-of-an-empty-buffer-is-a-no-op
  (with-socket-pair (writer reader)
    (ok (zerop (io:flush-buffer writer (wire:make-message-buffer))))
    (let ((target (make-array 8 :element-type '(unsigned-byte 8))))
      (multiple-value-bind (count) (receive-all reader target)
        (ok (zerop count) "nothing was written, so nothing is readable")))))

(deftest receive-on-an-empty-socket-reports-would-block
  (with-socket-pair (writer reader)
    (let ((target (make-array 8 :element-type '(unsigned-byte 8))))
      (multiple-value-bind (count fds truncated eof) (receive-all reader target)
        (ok (zerop count))
        (ok (null fds))
        (ok (not truncated))
        (ok (not eof) "EAGAIN is not end of stream")))))

(deftest pump-dispatches-whole-messages
  (with-socket-pair (writer reader)
    (let ((input (io:make-input-buffer :capacity 256))
          (seen '()))
      (io:flush-buffer writer
                       (encode 1 0 (lambda (b) (wire:put-uint b 42))))
      (ok (eql 1 (io:pump reader input
                          (lambda (object-id opcode message)
                            (push (list object-id opcode
                                        (wire:read-uint message))
                                  seen)))))
      (ok (equal '((1 0 42)) seen))
      (ok (zerop (io:input-buffer-pending-octets input))))))

(deftest pump-keeps-a-partial-message
  (with-socket-pair (writer reader)
    (let* ((buffer (encode 1 0 (lambda (b) (wire:put-uint b 7))))
           (octets (buffer-contents buffer))
           (input (io:make-input-buffer :capacity 256))
           (seen '()))
      ;; Six octets of a twelve-octet message: a header that is not complete.
      (ok (eql 6 (ffi:send-with-ancillary writer octets 0 6 '())))
      (ok (zerop (io:pump reader input
                          (lambda (&rest arguments)
                            (declare (ignore arguments))
                            (push :dispatched seen)))))
      (ok (eql 6 (io:input-buffer-pending-octets input)))
      ;; The rest of it.
      (ok (eql 6 (ffi:send-with-ancillary writer octets 6 12 '())))
      (ok (eql 1 (io:pump reader input
                          (lambda (object-id opcode message)
                            (push (list object-id opcode
                                        (wire:read-uint message))
                                  seen)))))
      (ok (equal '((1 0 7)) seen))
      (ok (zerop (io:input-buffer-pending-octets input))))))

(deftest pump-dispatches-several-messages-in-order
  (with-socket-pair (writer reader)
    (let ((buffer (wire:make-message-buffer))
          (input (io:make-input-buffer :capacity 512))
          (seen '()))
      (let ((start (wire:begin-message buffer 1 0)))
        (wire:put-uint buffer 1)
        (wire:end-message buffer start))
      (let ((start (wire:begin-message buffer 2 3)))
        (wire:put-uint buffer 2)
        (wire:end-message buffer start))
      (io:flush-buffer writer buffer)
      (ok (eql 2 (io:pump reader input
                          (lambda (object-id opcode message)
                            (push (list object-id opcode
                                        (wire:read-uint message))
                                  seen)))))
      (ok (equal '((1 0 1) (2 3 2)) (nreverse seen))))))

(deftest large-buffer-pages-through-partial-writes
  ;; Five 60 KB messages are more than an AF_UNIX socket buffer will take at
  ;; once, so flush-buffer must write a prefix, trim, and be called again --
  ;; interleaved with pumping, or the writer would spin on EAGAIN forever.
  (with-socket-pair (writer reader)
    (let ((input (io:make-input-buffer :capacity 131072))
          (buffer (wire:make-message-buffer))
          (payload (make-array 60000 :element-type '(unsigned-byte 8)
                                     :initial-element 7))
          (received 0)
          (iterations 0))
      (dotimes (i 5)
        (let ((start (wire:begin-message buffer 1 0)))
          (wire:put-array buffer payload)
          (wire:end-message buffer start)))
      (let ((total (wire:buffer-size buffer)))
        (ok (eql (+ (* 5 60012)) total))
        (loop
          (incf iterations)
          (when (> iterations 100)
            (error "flush/pump loop did not converge"))
          (let ((written (io:flush-buffer writer buffer)))
            (io:pump reader input
                     (lambda (object-id opcode message)
                       (declare (ignore object-id opcode))
                       (incf received)
                       (ok (eql 60000 (length (wire:read-array message))))))
            (when (and (zerop written) (zerop (wire:buffer-size buffer)))
              (return))))
        (ok (eql 5 received) "every message survived the split")
        (ok (> iterations 1) "the socket buffer forced a partial write")))))

(deftest pump-reports-end-of-stream
  (with-socket-pair (writer reader)
    (let ((input (io:make-input-buffer :capacity 256)))
      (ffi:close-fd writer)
      (ok (signals (io:pump reader input (lambda (&rest arguments)
                                (declare (ignore arguments)))) 'ffi:connection-closed)))))

;;; ---------------------------------------------------------------------------
;;; Descriptors
;;; ---------------------------------------------------------------------------

(deftest one-descriptor-roundtrip
  (with-socket-pair (writer reader)
    (with-memfd (fd)
      (let ((buffer (encode 1 0 (lambda (b) (wire:put-fd b fd))))
            (received '())
            (input (io:make-input-buffer :capacity 256)))
        (ok (eql (wire:buffer-size buffer) (io:flush-buffer writer buffer)))
        (ok (null (wire:buffer-fds buffer)) "the queue is consumed by the write")
        (ok (eql 1 (io:pump reader input
                            (lambda (object-id opcode message)
                              (declare (ignore object-id opcode))
                              (push (wire:read-fd message) received)))))
        (ok (eql 1 (length received)))
        (unwind-protect
             (let ((new (first received)))
               (ok (ffi:fd-open-p new))
               (ok (ffi:fd-cloexec-p new) "MSG_CMSG_CLOEXEC must be honoured")
               (ok (/= fd new) "the receiver holds a duplicate, not the sender's fd"))
          (close-descriptors received))))))

(deftest twenty-eight-descriptors-in-one-message
  (with-socket-pair (writer reader)
    (let ((originals (make-descriptors 28))
          (received '())
          (input (io:make-input-buffer :capacity 512)))
      (unwind-protect
           (progn
             (let ((buffer (wire:make-message-buffer)))
               (let ((start (wire:begin-message buffer 1 0)))
                 (dolist (fd originals) (wire:put-fd buffer fd))
                 (wire:end-message buffer start))
               (ok (eql 8 (wire:buffer-size buffer))
                   "descriptors do not appear in the stream at all")
               (ok (eql 28 (wire:buffer-fd-count buffer)))
               (io:flush-buffer writer buffer))
             (ok (eql 1 (io:pump reader input
                                 (lambda (object-id opcode message)
                                   (declare (ignore object-id opcode))
                                   (dotimes (i 28)
                                     (push (wire:read-fd message) received))))))
             (ok (eql 28 (length received)))
             (ok (every #'ffi:fd-open-p received))
             (ok (every #'ffi:fd-cloexec-p received)))
        (close-descriptors originals)
        (close-descriptors received)))))

(deftest descriptors-flush-in-batches-at-the-ceiling
  ;; Twenty-nine descriptors cannot ride in one sendmsg, so the caller flushes
  ;; twice: 28 then 1.  The receiver sees the same order.
  (with-socket-pair (writer reader)
    (let ((originals (make-descriptors 29))
          (received '())
          (input (io:make-input-buffer :capacity 1024)))
      (unwind-protect
           (progn
             (flet ((send-batch (descriptors)
                      (let ((buffer (wire:make-message-buffer)))
                        (let ((start (wire:begin-message buffer 1 0)))
                          (wire:put-uint buffer (length descriptors))
                          (dolist (fd descriptors)
                            (wire:put-fd buffer fd))
                          (wire:end-message buffer start))
                        (io:flush-buffer writer buffer))))
               (send-batch (subseq originals 0 28))
               (send-batch (subseq originals 28)))
             ;; Each message announces its own descriptor count, so the handler
             ;; knows how many to claim.
             (io:pump reader input
                      (lambda (object-id opcode message)
                        (declare (ignore object-id opcode))
                        (dotimes (i (wire:read-uint message))
                          (push (wire:read-fd message) received))))
             (ok (eql 29 (length received)))
             (ok (eql 29 (length (remove-duplicates received))))
             (ok (every #'ffi:fd-open-p received)))
        (close-descriptors originals)
        (close-descriptors received)))))

(deftest truncated-descriptors-are-refused
  ;; The kernel allows 29 descriptors in one control message; the receiver only
  ;; made room for 28.  Losing one silently would be a leak nobody could ever
  ;; find, so this must be a hard error.
  (with-socket-pair (writer reader)
    (let ((originals (make-descriptors 29))
          (input (io:make-input-buffer :capacity 256)))
      (unwind-protect
           (let ((buffer (wire:make-message-buffer)))
             (let ((start (wire:begin-message buffer 1 0)))
               (dotimes (i 29) (wire:put-uint buffer 0))
               (wire:end-message buffer start))
             (ffi:send-with-ancillary writer
                                      (wire:buffer-octets buffer)
                                      0
                                      (wire:buffer-size buffer)
                                      originals)
             (ok (signals (io:pump reader input (lambda (&rest arguments)
                                       (declare (ignore arguments)))) 'io:truncated-descriptors)))
        (close-descriptors originals)))))

(deftest closed-descriptors-are-not-open
  (with-memfd (fd)
    (ok (ffi:fd-open-p fd))
    (ok (ffi:fd-cloexec-p fd))
    (ffi:close-fd fd)
    (ok (not (ffi:fd-open-p fd)))))
