;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(in-package #:cl-user)

(defpackage #:wayland.client
  (:use #:cl)
  (:nicknames #:wl.client)
  (:documentation
   "Wayland client: display connection, proxies, registry, event dispatch.

The client half of the protocol layer (docs/protocol-layer.md §6).  It owns
one socket, one reactor and one table of objects the server knows by id; it
turns Lisp calls into messages and messages back into calls.

Requests are generic functions generated from the XML: this package
specialises them for a display or a proxy, so

  (wl-display.get-registry display)

sends wl_display.get_registry and returns the wl_registry proxy.  Events reach
either hooks attached to a proxy (the wayflan-shaped API) or methods on the
generated event generic functions, whichever the caller prefers.")
  (:import-from #:wayland.protocol
                #:find-interface
                #:resolve-interface
                #:wl-interface
                #:interface-name
                #:interface-version
                #:interface-requests
                #:interface-events
                #:message-name
                #:message-opcode
                #:message-args
                #:message-symbol
                #:message-kind
                #:arg-name
                #:arg-type
                #:arg-interface
                #:arg-allow-null)
  (:import-from #:wayland.object
                #:+first-client-id+
                #:+client-id-max+
                #:make-object-table
                #:object-table-ref
                #:object-table-set
                #:object-table-remove
                #:allocate-client-id
                #:release-client-id)
  (:import-from #:wayland.wire
                #:message-buffer
                #:make-message-buffer
                #:buffer-size
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
                #:reader-remaining)
  (:import-from #:wayland.io
                #:flush-buffer
                #:input-buffer
                #:make-input-buffer
                #:pump)
  (:import-from #:wayland.reactor
                #:make-reactor
                #:close-reactor
                #:run-once
                #:add-source
                #:remove-source
                #:set-source-interest
                #:monotonic-now)
  (:import-from #:wayland.ffi
                #:close-fd
                #:connect-unix-socket
                #:make-socket-pair
                #:fd-open-p
                #:io-error)
  ;; The request generic functions this package implements a client side for.
  ;; The package is named after the protocol (docs/protocol-layer.md §4.1).
  (:import-from #:wayland
                #:wl-display.get-registry
                #:wl-display.sync
                #:wl-registry.bind)
  (:export
   ;; conditions
   #:client-error
   #:client-error-detail
   #:connection-failed
   #:connection-failed-path
   #:protocol-error
   #:protocol-error-interface
   #:protocol-error-message
   #:display-error
   #:display-error-object-id
   #:display-error-code
   #:display-error-message
   #:unknown-object
   #:unknown-object-id
   #:unknown-message
   #:id-exhausted
   #:destroyed-proxy
   #:roundtrip-timeout
   #:roundtrip-timeout-seconds
   ;; limits
   #:+first-client-id+
   #:+client-id-max+
   ;; connection
   #:connect
   #:disconnect
   #:socket-path
   #:with-open-display
   #:display
   #:display-socket
   #:display-reactor
   #:display-input
   #:display-output
   #:display-objects
   #:display-source
   #:display-closed-p
   #:make-display-from-fd
   ;; proxies
   #:proxy
   #:registry
   #:proxy-id
   #:proxy-interface
   #:proxy-version
   #:proxy-display
   #:proxy-hooks
   #:proxy-destroyed-p
   #:check-live
   #:allocate-proxy
   #:register-proxy
   #:release-object
   #:object-for-id
   #:interface-request
   #:interface-event
   ;; transport and dispatch
   #:send-request
   #:flush
   #:dispatch
   #:roundtrip
   ;; re-exported request generic functions
   #:wl-display.get-registry
   #:wl-display.sync
   #:wl-registry.bind))
