;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(in-package #:cl-user)

(defpackage #:wayland.server
  (:use #:cl)
  (:nicknames #:wl.server)
  (:documentation
   "Wayland server: the socket, the clients on it, globals, resources and the
id namespace.

This is a protocol implementation, not a binding: it speaks the wire format that
cl-wayland-core implements and uses the interface metadata the generated WAYLAND
package provides (docs/protocol-layer.md §5).  A compositor is built on top of it
by subclassing RESOURCE and specialising the generated request generic
functions:

  (defmethod wl-surface.attach ((surface my-surface) buffer x y) ...)

Phase 1 covers the transport, ids, globals, bind, sync, errors and teardown; the
protocol content (surfaces, shm, seats) arrives in phase 2.")
  (:import-from #:wayland.object
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
                #:release-server-id)
  (:import-from #:wayland.protocol
                #:resolve-interface
                #:wl-interface
                #:interface-name
                #:interface-version
                #:interface-requests
                #:interface-events
                #:message-name
                #:message-opcode
                #:message-args
                #:message-since
                #:message-symbol
                #:arg-name
                #:arg-type
                #:arg-interface
                #:arg-allow-null)
  (:import-from #:wayland.wire
                #:message-buffer
                #:make-message-buffer
                #:buffer-size
                #:buffer-fds
                #:clear-message-buffer
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
                #:reader
                #:read-int
                #:read-uint
                #:read-fixed
                #:read-string
                #:read-object
                #:read-array
                #:read-fd
                #:reader-done-p
                #:reader-remaining
                #:wire-error)
  (:import-from #:wayland.io
                #:flush-buffer
                #:input-buffer
                #:make-input-buffer
                #:reset-input-buffer
                #:pump
                #:truncated-descriptors)
  (:import-from #:wayland.ffi
                #:close-fd
                #:fd-open-p
                #:effective-uid
                #:listen-unix-socket
                #:accept-unix-socket
                #:open-lock-file
                #:io-error
                #:io-error-errno
                #:connection-closed
                #:+eagain+)
  (:import-from #:wayland.reactor
                #:make-reactor
                #:close-reactor
                #:monotonic-now
                #:add-source
                #:remove-source
                #:set-source-interest
                #:add-idle
                #:add-timer
                #:cancel-timer
                #:request-stop
                #:source-fd
                #:source-interest)
  ;; The generated generic functions this package implements the server side of
  ;; (docs/protocol-layer.md §4.3).  Requests are specialised on resources;
  ;; events are specialised to *emit*, because on this side a call on an event
  ;; generic function means "send it".
  (:import-from #:wayland
                #:wl-display.sync
                #:wl-display.get-registry
                #:wl-display.error
                #:wl-display.delete-id
                #:wl-registry.bind
                #:wl-registry.global
                #:wl-registry.global-remove
                #:wl-callback.done
                #:wl-compositor.release
                #:wl-output.geometry
                #:wl-output.mode
                #:wl-output.done
                #:wl-output.scale
                #:wl-output.name
                #:wl-output.description
                #:wl-output.release
                ;; opcodes of the events the server sends in phase 1
                #:+wl-display-error+
                #:+wl-display-delete-id+
                #:+wl-registry-global+
                #:+wl-registry-global-remove+
                #:+wl-callback-done+
                #:+wl-output-geometry+
                #:+wl-output-mode+
                #:+wl-output-done+
                #:+wl-output-scale+
                #:+wl-output-name+
                #:+wl-output-description+)
  (:export
   ;; conditions
   #:server-error
   #:server-error-detail
   #:socket-condition
   #:socket-condition-path
   #:socket-in-use
   #:socket-in-use-path
   #:wl-protocol-error
   #:wl-protocol-error-client
   #:wl-protocol-error-object-id
   #:wl-protocol-error-code
   #:wl-protocol-error-message
   #:internal-error
   ;; error codes (wl_display.error)
   #:+error-invalid-object+
   #:+error-invalid-method+
   #:+error-no-memory+
   #:+error-implementation+
   ;; limits
   #:+first-client-id+
   #:+client-id-max+
   #:+first-server-id+
   #:+max-id+
   ;; the display
   #:display
   #:make-display
   #:close-display
   #:run
   #:run-once
   #:display-name
   #:display-socket-path
   #:display-socket-fd
   #:display-lock-fd
   #:display-reactor
   #:display-clients
   #:display-globals
   #:display-closed-p
   #:display-next-serial
   #:flush-all
   ;; clients
   #:client
   #:client-id
   #:client-fd
   #:client-pid
   #:client-uid
   #:client-gid
   #:client-display
   #:client-objects
   #:client-input
   #:client-output
   #:client-registries
   #:client-closed-p
   #:client-congested-p
   #:teardown-client
   #:disconnect-client
   #:flush-client
   ;; resources
   #:resource
   #:resource-id
   #:resource-client
   #:resource-interface
   #:resource-version
   #:resource-destroyed-p
   #:make-resource
   #:allocate-resource
   #:destroy-resource
   #:pending-new-id
   #:take-new-id
   ;; protocol objects this phase speaks
   #:display-resource
   #:registry
   #:callback
   #:compositor
   #:output
   ;; globals
   #:global
   #:global-name
   #:global-interface
   #:global-version
   #:global-resource-class
   #:global-data
   #:add-global
   #:remove-global
   #:find-global
   ;; events a compositor sends
   #:send-event
   ;; limits and policy knobs
   #:+output-high-water-mark+
   #:*log-level*
   #:*log-stream*
   #:log-message
   ;; the demo
   #:make-demo-display))
