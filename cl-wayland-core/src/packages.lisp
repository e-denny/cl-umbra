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
   #:+econnreset+
   #:+enametoolong+
   #:+eintr+
   #:+ebadf+
   #:+eagain+
   #:+epipe+
   #:+emsgsize+
   #:+enoent+
   #:+eacces+
   #:+eexist+
   #:+enotsup+
   #:+eaddrinuse+
   ;; descriptors
   #:make-socket-pair
   #:connect-unix-socket
   #:listen-unix-socket
   #:accept-unix-socket
   #:unix-socket-peer-credentials
   #:open-lock-file
   #:chmod-path
   #:effective-uid
   #:process-id
   #:signal-disposition
   #:signal-handler-installed-p
   #:close-fd
   #:fd-open-p
   #:fd-cloexec-p
   #:set-fd-nonblocking
   #:memfd-create
   #:dup-fd
   #:map-file
   #:unmap-file
   #:mapped-octets
   #:set-file-size
   #:write-mapped-octets
   #:pointer+
   #:+prot-read+
   #:+prot-write+
   ;; i/o
   #:send-with-ancillary
   #:receive-with-ancillary
   #:cmsg-align
   #:cmsg-space
   ;; clocks and byte streams
   #:monotonic-seconds
   #:read-into
   #:read-into-pointer
   #:write-from-pointer
   ;; event sources
   #:make-event-fd
   #:read-event-fd
   #:signal-event-fd
   #:make-timer-fd
   #:set-timer-absolute
   #:read-timer-fd
   #:make-signal-fd
   #:unblock-signals
   #:read-signal
   #:raise-signal
   #:ignore-sigpipe
   ;; signal numbers
   #:+sigint+
   #:+sigusr1+
   #:+sigpipe+
   #:+sigterm+
   #:+sigchld+))

(defpackage #:wayland.io
  (:use #:cl #:wayland.wire)
  (:documentation
   "Transport for Wayland connections: flushing a message buffer with its
descriptors, receiving into an input buffer, and turning a byte stream back
into whole messages.  WAYLAND.WIRE stays pure format; this package is the
only place that touches a socket.")
  (:export
   #:flush-buffer
   #:socket-path
   #:socket-path-error
   #:socket-path-error-detail
   #:input-buffer
   #:make-input-buffer
   #:input-buffer-pending-octets
   #:input-buffer-pending-fds
   #:input-buffer-capacity
   #:reset-input-buffer
   #:pump
   #:truncated-descriptors
   #:truncated-descriptors-count))

(defpackage #:wayland.object
  (:use #:cl)
  (:documentation
   "Object tables and the two id namespaces, shared by both directions of the
protocol (docs/protocol-layer.md §3).

A table maps ids to objects and allocates the lowest free id; the client half is
2..0xFEFFFFFF, the server half 0xFF000000.. Nothing here knows whether the
objects are proxies or resources, and nothing here sends messages: destruction
and wl_display.delete_id belong to the dispatch layer, which differs between the
two ends.")
  (:export
   #:+first-client-id+
   #:+client-id-max+
   #:+first-server-id+
   #:+max-id+
   #:client-id-p
   #:server-id-p
   #:object-table
   #:make-object-table
   #:object-table-ref
   #:object-table-set
   #:object-table-remove
   #:object-table-count
   #:object-table-ids
   #:allocate-client-id
   #:release-client-id
   #:allocate-server-id
   #:release-server-id
   #:id-space-exhausted
   #:id-space-exhausted-limit))

(defpackage #:wayland.reactor
  (:use #:cl)
  (:import-from #:wayland.ffi
                #:+sigint+
                #:+sigusr1+
                #:+sigpipe+
                #:+sigterm+
                #:+sigchld+
                #:read-signal
                #:ignore-sigpipe)
  (:documentation
   "The event loop: epoll, level-triggered; timerfd for the nearest deadline;
eventfd for wakeups from other threads; signalfd for termination and children;
idle callbacks that run once per cycle.

One cycle is: run queued commands, wait, dispatch ready sources, fire due
timers, run idles.  See docs/protocol-layer.md §7.  Nothing here knows what a
Wayland client is.")
  (:export
   ;; reactor
   #:reactor
   #:make-reactor
   #:close-reactor
   #:run-once
   #:run
   #:request-stop
   #:stopped-p
   #:dispatching-p
   #:monotonic-now
   ;; sources
   #:fd-source
   #:add-source
   #:remove-source
   #:set-source-interest
   #:source-fd
   #:source-name
   #:source-interest
   ;; timers
   #:timer
   #:add-timer
   #:cancel-timer
   #:timer-deadline
   ;; idles and commands
   #:add-idle
   #:remove-idle
   #:post
   ;; signals
   #:add-signal-source
   #:add-signal-handler
   #:ignore-sigpipe
   #:read-signal
   #:timer-interval
   #:timer-function
   #:+sigint+
   #:+sigterm+
   #:+sigusr1+
   #:+sigchld+
   #:+sigpipe+
   ;; epoll masks, for callbacks that care what happened
   #:+epoll-in+
   #:+epoll-out+
   #:+epoll-err+
   #:+epoll-hup+
   #:+epoll-rdhup+
   ;; conditions
   #:reactor-error
   #:reactor-reentry
   #:epoll-error
   #:duplicate-source))

(defpackage #:wayland.protocol
  (:use #:cl)
  (:documentation
   "Protocol metadata: the XML corpus parsed into CLOS objects.

An INTERFACE knows its version, its requests and events in wire order (so the
opcode is the position), its enums, and the generated signature of every
message.  This package parses and validates; it does not generate code and does
not open sockets.")
  (:export
   ;; XML
   #:xml-element
   #:xml-element-name
   #:xml-element-attributes
   #:xml-element-children
   #:parse-xml
   ;; schema objects
   #:wl-protocol
   #:protocol-name
   #:protocol-copyright
   #:protocol-interfaces
   #:protocol-source
   #:wl-interface
   #:interface-name
   #:interface-version
   #:interface-requests
   #:interface-events
   #:interface-enums
   #:interface-summary
   #:interface-description
   #:interface-protocol
   #:wl-message
   #:message-name
   #:message-opcode
   #:message-kind
   #:message-args
   #:message-symbol
   #:message-since
   #:message-summary
   #:message-description
   #:message-interface
   #:message-signature
   #:message-interface-references
   #:wl-arg
   #:arg-name
   #:arg-type
   #:arg-type-character
   #:arg-interface
   #:arg-allow-null
   #:arg-enum
   #:arg-summary
   #:wl-enum
   #:enum-name
   #:enum-bitfield-p
   #:enum-entries
   #:enum-summary
   #:enum-description
   #:enum-interface
   #:wl-entry
   #:entry-name
   #:entry-value
   #:entry-since
   #:entry-summary
   #:entry-description
   ;; parsing
   #:parse-protocol-string
   #:parse-protocol-file
   #:resolve-interface
   ;; registry
   #:register-protocol
   #:unregister-protocol
   #:find-interface
   #:registered-interfaces
   #:clear-protocol-registry
   ;; conditions
   ;; define-* forms and their helpers
   #:define-interface
   #:define-enum
   #:define-request
   #:define-event
   #:wire-name-of
   #:lisp-name-of
   #:version-constant-name
   #:opcode-constant-name
   #:enum-constant-name
   ;; conditions
   #:schema-error
   #:xml-error
   #:invalid-schema
   #:conflicting-interface
   #:conflicting-interface-name))

(defpackage #:wayland.codegen
  (:use #:cl #:wayland.protocol)
  (:documentation
   "Schema -> Lisp source: the DEFINE-* forms the ASDF component writes.

Generation is a re-spelling of the schema, never a second opinion: loading what
this produces must yield exactly the metadata the XML produced.")
  (:export
   #:generate-protocol-text
   #:generate-protocol-file
   #:protocol-package-name
   #:protocol-export-names))
