;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;;
;;;; Package definitions for cl-wayland-core.

(in-package #:cl-user)

(defpackage #:wayland.wire
  (:use #:cl)
  (:documentation
   "Wayland wire format: message framing, argument encoding and decoding, and
file-descriptor bookkeeping.

This package deliberately knows nothing about sockets, object tables or
interfaces: it turns Lisp values into octets and back.  See
docs/protocol-layer.md §1 for the format it implements.")
  (:export
   ;; framing constants
   #:+header-size+
   #:*max-message-size*
   #:+max-fds-per-flush+
   ;; encode side: the message buffer
   #:message-buffer
   #:make-message-buffer
   #:clear-message-buffer
   #:buffer-octets
   #:buffer-contents
   #:buffer-size
   #:buffer-fds
   #:buffer-fd-count
   #:trim-buffer
   #:begin-message
   #:end-message
   #:put-int
   #:put-uint
   #:put-fixed
   #:put-string
   #:put-object
   #:put-new-id
   #:put-array
   #:put-fd
   ;; decode side: the reader
   #:reader
   #:make-reader
   #:reader-position
   #:reader-remaining
   #:reader-done-p
   #:reader-fds-consumed
   #:read-int
   #:read-uint
   #:read-fixed
   #:read-string
   #:read-object
   #:read-array
   #:read-fd
   #:decode-header
   ;; helpers
   #:pad4
   #:fixed-to-rational
   ;; conditions
   #:wire-error
   #:encode-error
   #:value-out-of-range
   #:message-too-large
   #:unsupported-host-endianness
   #:decode-error
   #:truncated-message
   #:invalid-message-header
   #:invalid-string
   #:invalid-array
   #:missing-fd))

(defpackage #:wayland.ffi
  (:use #:cl)
  (:documentation
   "The syscall edge: descriptors, socket pairs, sendmsg/recvmsg with
SCM_RIGHTS, errno and FD_CLOEXEC.  Everything here is libc, not libwayland.

Linux/x86-64 values are asserted at load time rather than guessed: a wrong
MSG_CMSG_CLOEXEC is a silent descriptor leak.")
  (:export
   ;; conditions
   #:io-error
   #:io-error-operation
   #:io-error-errno
   #:connection-closed
   ;; errno
   #:errno
   #:strerror
   #:+eintr+
   #:+ebadf+
   #:+eagain+
   #:+epipe+
   #:+emsgsize+
   #:+econnreset+
   ;; descriptors
   #:make-socket-pair
   #:close-fd
   #:fd-open-p
   #:fd-cloexec-p
   #:set-fd-nonblocking
   #:memfd-create
   ;; i/o
   #:send-with-ancillary
   #:receive-with-ancillary
   #:cmsg-align
   #:cmsg-space))

(defpackage #:wayland.io
  (:use #:cl #:wayland.wire)
  (:documentation
   "Transport for Wayland connections: flushing a message buffer with its
descriptors, receiving into an input buffer, and turning a byte stream back
into whole messages.  WAYLAND.WIRE stays pure format; this package is the
only place that touches a socket.")
  (:export
   #:flush-buffer
   #:input-buffer
   #:make-input-buffer
   #:input-buffer-pending-octets
   #:input-buffer-pending-fds
   #:pump
   #:truncated-descriptors
   #:truncated-descriptors-count))
