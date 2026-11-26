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
                #:wl-shm.format
                #:wl-shm.create-pool
                #:wl-shm-pool.create-buffer
                #:wl-shm-pool.destroy
                #:wl-shm-pool.resize
                #:wl-buffer.destroy
                #:wl-buffer.release
                #:wl-compositor.create-surface
                #:wl-compositor.create-region
                #:wl-surface.attach
                #:wl-surface.damage
                #:wl-surface.frame
                #:wl-surface.set-opaque-region
                #:wl-surface.set-input-region
                #:wl-surface.commit
                #:wl-surface.destroy
                #:wl-surface.enter
                #:wl-surface.leave
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
                #:+wl-output-description+
                #:+wl-shm-format+
                #:+wl-buffer-release+
                #:+wl-surface-enter+
                #:+wl-surface-leave+
                ;; wl_shm / wl_shm_pool error codes
                #:+wl-shm-error-invalid-format+
                #:+wl-shm-error-invalid-stride+
                #:+wl-shm-error-invalid-fd+
                #:+wl-shm-pool-error-invalid-format+
                #:+wl-shm-pool-error-invalid-stride+)
  ;; xdg-shell is a separate generated package (it is a separate protocol), and
  ;; this server implements the v1 subset of it: see XDG-SHELL.LISP.
  (:import-from #:xdg-shell
                #:xdg-wm-base.destroy
                #:xdg-wm-base.get-xdg-surface
                #:xdg-wm-base.pong
                #:xdg-wm-base.ping
                #:xdg-surface.destroy
                #:xdg-surface.get-toplevel
                #:xdg-surface.get-popup
                #:xdg-surface.set-window-geometry
                #:xdg-surface.ack-configure
                #:xdg-surface.configure
                #:xdg-toplevel.destroy
                #:xdg-toplevel.set-parent
                #:xdg-toplevel.set-title
                #:xdg-toplevel.set-app-id
                #:xdg-toplevel.show-window-menu
                #:xdg-toplevel.move
                #:xdg-toplevel.resize
                #:xdg-toplevel.set-max-size
                #:xdg-toplevel.set-min-size
                #:xdg-toplevel.set-maximized
                #:xdg-toplevel.unset-maximized
                #:xdg-toplevel.set-fullscreen
                #:xdg-toplevel.unset-fullscreen
                #:xdg-toplevel.set-minimized
                #:xdg-toplevel.configure
                #:xdg-toplevel.close
                ;; opcodes of the events the server sends
                #:+xdg-wm-base-ping+
                #:+xdg-surface-configure+
                #:+xdg-toplevel-configure+
                #:+xdg-toplevel-close+
                ;; xdg_wm_base.error
                #:+xdg-wm-base-error-role+
                #:+xdg-wm-base-error-defunct-surfaces+
                ;; xdg_surface.error
                #:+xdg-surface-error-not-constructed+
                #:+xdg-surface-error-already-constructed+
                #:+xdg-surface-error-unconfigured-buffer+
                #:+xdg-surface-error-invalid-serial+
                #:+xdg-surface-error-invalid-size+
                #:+xdg-surface-error-defunct-role-object+
                ;; xdg_toplevel.error
                #:+xdg-toplevel-error-invalid-resize-edge+
                #:+xdg-toplevel-error-invalid-parent+
                #:+xdg-toplevel-error-invalid-size+
                ;; xdg_toplevel.state
                #:+xdg-toplevel-state-maximized+
                #:+xdg-toplevel-state-fullscreen+
                #:+xdg-toplevel-state-activated+)
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
   #:client-resources
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
   #:compositor-surface-class
   #:output
   #:surface
   #:surface-pending-buffer
   #:surface-current-buffer
   #:surface-mapped-p
   #:surface-committed-p
   #:surface-committed-callbacks
   #:surface-pending-damage
   #:surface-owner
   #:surface-current-x
   #:surface-current-y
   #:surface-frame-callbacks
   #:surface-shell-surface
   #:surface-shell-check-commit
   #:surface-shell-committed
   #:surface-shell-lost
   #:surface-committed
   #:surface-presented
   #:fire-frame-callbacks
   #:release-surface-buffer
   #:shm
   #:shm-pool
   #:shm-buffer
   #:shm-buffer-pool
   #:shm-buffer-offset
   #:shm-buffer-width
   #:shm-buffer-height
   #:shm-buffer-stride
   #:shm-buffer-format
   #:shm-buffer-pointer
   #:shm-buffer-byte-length
   #:shm-buffer-in-use-p
   #:shm-buffer-released-p
   #:shm-pool-fd
   #:shm-pool-size
   #:shm-pool-mapping
   #:shm-pool-buffers
   #:release-shm-pool-mapping
   #:release-shm-buffer
   #:claim-shm-buffer
   #:send-shm-formats
   #:shm-format-supported-p
   #:+wl-shm-format-argb8888+
   #:+wl-shm-format-xrgb8888+
   #:+wl-shm-error-invalid-format+
   #:+wl-shm-error-invalid-stride+
   #:+wl-shm-error-invalid-fd+
   #:+wl-shm-pool-error-invalid-format+
   #:+wl-shm-pool-error-invalid-stride+
   #:resource-destroy-function
   ;; xdg-shell (v1): the objects, their state, and the policy hooks
   #:xdg-wm-base
   #:xdg-surface
   #:xdg-toplevel
   #:xdg-wm-base-shell-surfaces
   #:xdg-wm-base-pending-pings
   #:xdg-wm-base-ping-count
   #:xdg-wm-base-pong-count
   #:xdg-surface-surface
   #:xdg-surface-wm-base
   #:xdg-surface-role
   #:xdg-surface-role-name
   #:xdg-surface-configured-p
   #:xdg-surface-acknowledged-p
   #:xdg-surface-configure-serial
   #:xdg-surface-pending-serials
   #:xdg-surface-last-acked-serial
   #:xdg-surface-ack-count
   #:xdg-surface-window-geometry
   #:xdg-surface-mapped-p
   #:xdg-surface-live-p
   #:xdg-toplevel-shell-surface
   #:xdg-toplevel-title
   #:xdg-toplevel-app-id
   #:xdg-toplevel-parent
   #:xdg-toplevel-min-width
   #:xdg-toplevel-min-height
   #:xdg-toplevel-max-width
   #:xdg-toplevel-max-height
   #:xdg-toplevel-maximized-p
   #:xdg-toplevel-fullscreen-p
   #:xdg-toplevel-minimized-p
   #:xdg-toplevel-configure-count
   #:xdg-toplevel-configure-width
   #:xdg-toplevel-configure-height
   #:xdg-toplevel-configure-states
   #:xdg-toplevel-mapped-p
   #:xdg-toplevel-closed-p
   #:send-configure
   #:ping-xdg-wm-base
   #:close-toplevel
   #:set-toplevel-activated
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
