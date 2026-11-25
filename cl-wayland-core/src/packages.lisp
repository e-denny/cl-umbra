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
   #:buffer-size
   #:buffer-fds
   #:buffer-fd-count
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
