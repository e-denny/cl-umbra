;;;; SPDX-FileCopyrightText: 2026 Edgar Denny
;;;; SPDX-License-Identifier: GPL-3.0-or-later

(in-package #:cl-user)

;;; The modules come first, and CF re-exports their public names: one package per
;;; module is how docs/framework.md §1 lays the framework out, and CF is the face
;;; a compositor author writes against.

(defpackage #:cf.render.pixman
  (:use #:cl)
  (:documentation
   "The pixman renderer: the reference implementation, and by definition the
output golden tests compare against (docs/memory-and-rendering.md §6-§7).

It draws into a `target' -- a pixman image over an octet vector -- from wl_shm
buffers, which are read in place: no copy, no texture, no upload.")
  (:export
   #:make-target
   #:make-target-over-pointer
   #:destroy-target
   #:target-octets-copy
   #:target-width
   #:target-height
   #:target-stride
   #:target-set-clip
   #:target-clear-clip
   #:fill-target
   #:fill-rect
   #:composite-buffer
   #:composite-bitmap
   #:pixman-format-for-shm
   #:buffer-display-size
   #:transform-matrix
   #:region
   #:make-region
   #:destroy-region
   #:region-clear
   #:region-empty-p
   #:region-add
   #:region-add-box
   #:region-add-box
   #:region-union
   #:region-intersect
   #:region-subtract
   #:region-copy
   #:region-intersect-rect
   #:region-set-rect
   #:region-translate
   #:region-rectangles
   #:region-bounds
   #:+pixman-op-src+
   #:+pixman-op-over+))

(defpackage #:cf.input
  (:use #:cl)
  (:documentation
   "Keymaps, keycodes and modifier state (docs/framework.md §5).

Phase 3 needs a small, self-contained XKB keymap generated from a table, and the
modifier mask each key sets.  Phase 4 adds libxkbcommon here, for real layouts and
device-specific keymaps from libinput; the protocol and the rest of the framework
already speak in keycodes and masks, so that change stays inside this package.")
  (:export
   ;; the keymap
   #:keymap
   #:keymap-error
   #:keymap-error-detail
   #:compile-keymap
   #:default-keymap
   #:unref-keymap
   #:keymap-text
   #:keymap-from-string
   #:make-keymap
   #:keymap-rules
   #:keymap-model
   #:keymap-layout
   #:keymap-variant
   #:keymap-options
   #:keymap-min-keycode
   #:keymap-max-keycode
   ;; names and codes
   #:keycode
   #:xkb-keycode
   #:key-name-for-code
   #:keysym
   #:keysym-name
   #:keymap-syms
   #:key-repeats-p
   ;; modifiers
   #:key-modifier-mask
   #:modifier-mask
   #:keymap-modifier-mask
   #:modifiers
   #:make-modifiers
   #:unref-modifiers
   #:modifiers-depressed
   #:modifiers-latched
   #:modifiers-locked
   #:modifiers-group
   #:modifiers-keysym
   #:modifiers-keysym-name
   #:update-modifiers
   #:+modifier-shift+
   #:+modifier-lock+
   #:+modifier-control+
   #:+modifier-mod1+
   #:+modifier-mod4+))

(defpackage #:cf.font
  (:use #:cl)
  (:documentation
   "A 5x7 bitmap font and its rasteriser (docs/framework.md §4, D51).

The only text the framework draws, and the smallest thing that can: 95 glyphs,
one size, printable ASCII, no library.  A raster is premultiplied ARGB8888 with
one font cell per SCALE x SCALE device pixels, so text is drawn bigger at scale 2
rather than upscaled.")
  (:export
   #:+glyph-width+
   #:+glyph-height+
   #:+glyph-advance+
   #:+first-char-code+
   #:+last-char-code+
   #:+fallback-character+
   #:glyph-count
   #:glyph-cell-p
   #:glyph-row-mask
   #:text-width
   #:text-height
   #:truncate-text
   #:rasterize-text))

(defpackage #:cf.scene
  (:use #:cl)
  (:local-nicknames (#:render #:cf.render.pixman)
                    (#:font #:cf.font))
  (:import-from #:wayland.server
                #:surface-current-buffer
                #:surface-current-x
                #:surface-current-y
                #:surface-input-region
                #:surface-mapped-p
                #:surface-opaque-region
                #:surface-buffer-scale
                #:surface-buffer-transform
                #:surface-damage-since-frame
                #:resource-destroyed-p
                #:shm-buffer-width
                #:shm-buffer-height
                #:shm-buffer-format
                #:shm-buffer-pool
                #:shm-pool-mapping)
  (:documentation
   "The scene graph: nodes with positions, a stacking order, hit testing and
compositing (docs/framework.md §4).  Policy stays outside; this package knows
nothing about seats, toplevels or focus.")
  (:export
   ;; the scene and its two ends
   #:scene
   #:make-scene
   #:scene-width
   #:scene-height
   #:scene-root
   #:scene-overlay
   #:scene-add-overlay-node
   #:scene-clear-overlay
   #:scene-cursor
   #:scene-cursor-visible-p
   #:scene-cursor-surface
   #:scene-cursor-hotspot-x
   #:scene-cursor-hotspot-y
   #:client-cursor-usable-p
   #:scene-add-node
   #:scene-remove-node
   #:scene-hit-test
   #:scene-scale
   #:scene-render
   #:scene-render-items
   #:scene-draw-list
   #:scene-background-region
   #:scene-damage-between
   #:scene-consume-damage
   #:surface-layout-size
   #:draw-item
   #:draw-item-kind
   #:draw-item-node
   #:draw-item-surface
   #:draw-item-x
   #:draw-item-y
   #:draw-item-width
   #:draw-item-height
   ;; the content damage a client reported for this frame's item, in device pixels
   #:draw-item-damage
   ;; nodes
   #:scene-node
   #:node-parent
   #:node-x
   #:node-y
   #:node-position
   #:set-node-position
   #:set-node-size
   #:node-visible-p
   #:node-width
   #:node-height
   #:node-raised
   #:tree-node
   #:node-children
   #:buffer-node
   #:make-buffer-node
   #:buffer-node-surface
   #:rect-node
   #:make-rect-node
   #:rect-node-color
   #:image-node
   #:make-image-node
   #:image-node-octets
   #:bitmap-node
   #:bitmap-node-octets
   #:bitmap-node-source-width
   #:bitmap-node-source-height
   #:snapshot-node
   #:make-snapshot-node
   #:buffer-drawable-p
   #:snapshot-surface
   #:text-node
   #:make-text-node
   #:text-node-text
   #:text-node-colour
   #:text-node-raster
   ;; the built-in cursor
   #:+cursor-width+
   #:+cursor-height+
   #:make-cursor-image))

(defpackage #:cf.grab
  (:use #:cl)
  (:local-nicknames (#:scene #:cf.scene)
                    (#:srv #:wayland.server))
  (:documentation
   "Grabs: an interaction that owns the pointer until it ends (docs/framework.md
§5).  Move and resize are the two a window manager cannot do without; a grab knows
about nodes and sizes, and tells the compositor about frames and configures through
two hooks.")
  (:export
   #:grab
   #:grab-node
   #:grab-owner
   #:grab-button-code
   #:grab-active-p
   #:grab-motion
   #:grab-button
   #:grab-key
   #:grab-changed
   #:grab-resize
   #:grab-ended
   #:grab-end
   #:move-grab
   #:begin-move-grab
   #:move-grab-start-x
   #:move-grab-start-y
   #:move-grab-origin-x
   #:move-grab-origin-y
   #:resize-grab
   #:begin-resize-grab
   #:resize-grab-edges
   #:resize-grab-anchor-right
   #:resize-grab-anchor-bottom
   #:grab-anchored
   #:place-anchored
   #:clamp-to-output
   #:clamp-node-to-output
   #:node-geometry
   #:resize-grab-max-size
   #:resize-grab-anchor-left
   #:resize-grab-anchor-top
   #:resize-grab-output-width
   #:resize-grab-output-height
   #:popup-grab
   #:begin-popup-grab
   #:popup-grab-popup
   #:popup-grab-swallowed
   #:move-grab-output-width
   #:move-grab-output-height
   #:resize-target-size
   #:resize-grab-requested-width
   #:resize-grab-requested-height
   #:resize-grab-seen-width
   #:resize-grab-seen-height
   #:+edge-top+
   #:+edge-bottom+
   #:+edge-left+
   #:+edge-right+))

(defpackage #:cf.keybindings
  (:use #:cl)
  (:documentation
   "Compositor keybindings, consulted before the focused client (docs/framework.md
§5).  A binding is (modifiers, key name) -> a function; a consumed key never
reaches the client.")
  (:export
   #:keybinding
   #:keybinding-key
   #:keybinding-modifiers
   #:keybinding-function
   #:keybinding-description
   #:keybinding-table
   #:keybinding-table-bindings
   #:make-keybinding-table
   #:add-keybinding
   #:remove-keybinding
   #:binding-for
   #:dispatch-keybinding))

(defpackage #:cf.backend.headless.png
  (:use #:cl)
  (:documentation
   "PNG writing for readback: the smallest correct encoder (stored deflate blocks,
one filter byte per scanline, real CRC-32 and Adler-32), because a screenshot is
a debugging artefact and a test fixture, not a compression benchmark.")
  (:export #:write-png))

(defpackage #:cf.backend.drm
  (:use #:cl)
  (:local-nicknames (#:ffi #:wayland.ffi)
                    (#:render #:cf.render.pixman)
                    (#:scene #:cf.scene))
  (:documentation
   "The DRM backend, first half (docs/framework.md §2, PLAN.md phase 4).

A card, what is plugged into it, mode choice, dumb buffers, and the screen
(D54, D55).

The first half describes a card and changes nothing on it, so it works on a card
another session already presents on.  The second half takes the screen: master,
SETCRTC, page flips and the events they retire with, wrapped as a DRM-SCANOUT that
saves the CRTC's state when it opens and puts it back when it closes.  A card
somebody is presenting on answers EBUSY to master, and that is the answer the
project keeps rather than works around.")
  (:export
   ;; conditions
   #:drm-error
   #:drm-error-operation
   #:drm-error-errno
   #:drm-error-path
   ;; the device
   #:drm-device
   #:open-drm-device
   #:open-drm-device-from-fd
   #:close-drm-device
   #:drm-device-open-p
   #:drm-device-path
   #:drm-device-fd
   #:drm-device-driver-name
   #:drm-device-version
   #:drm-device-version-major
   #:drm-device-version-minor
   #:drm-device-version-patchlevel
   #:drm-device-master-p
   #:drm-device-capabilities
   #:drm-device-flips
   #:drm-device-paths
   #:drm-driver-at
   ;; what the card says about itself
   #:drm-inventory
   #:drm-inventory-driver-name
   #:drm-inventory-driver-version
   #:drm-inventory-crtcs
   #:drm-inventory-connectors
   #:drm-inventory-encoders
   #:drm-inventory-framebuffers
   #:drm-inventory-min-width
   #:drm-inventory-max-width
   #:drm-inventory-min-height
   #:drm-inventory-max-height
   #:drm-inventory-connector
   #:drm-inventory-crtc
   #:drm-inventory-encoder
   #:drm-inventory-connected-connectors
   #:drm-mode
   #:drm-mode-name
   #:drm-mode-clock
   #:drm-mode-hdisplay
   #:drm-mode-hsync-start
   #:drm-mode-hsync-end
   #:drm-mode-htotal
   #:drm-mode-hskew
   #:drm-mode-vdisplay
   #:drm-mode-vsync-start
   #:drm-mode-vsync-end
   #:drm-mode-vtotal
   #:drm-mode-vscan
   #:drm-mode-vrefresh
   #:drm-mode-flags
   #:drm-mode-type
   #:drm-mode-refresh
   #:drm-mode-refresh-milli-hz
   #:drm-mode-preferred-p
   #:drm-mode-better-p
   #:drm-connection-status
   #:drm-connector
   #:drm-connector-id
   #:drm-connector-name
   #:drm-connector-type
   #:drm-connector-type-id
   #:drm-connector-status
   #:drm-connector-connected-p
   #:drm-connector-status-string
   #:drm-connector-mm-width
   #:drm-connector-mm-height
   #:drm-connector-encoder-id
   #:drm-connector-modes
   #:drm-connector-encoders
   #:drm-connector-preferred-mode
   #:drm-connector-type-name
   #:drm-connector-hotplug-key
   #:drm-inventory-hotplug-key
   #:drm-hotplug-key
   #:drm-pick-mode
   #:drm-encoder
   #:drm-encoder-id
   #:drm-encoder-type
   #:drm-encoder-crtc-id
   #:drm-encoder-possible-crtcs
   #:drm-encoder-possible-clones
   #:drm-crtc
   #:drm-crtc-id
   #:drm-crtc-buffer-id
   #:drm-crtc-x
   #:drm-crtc-y
   #:drm-crtc-width
   #:drm-crtc-height
   #:drm-crtc-mode-valid-p
   #:drm-crtc-mode
   ;; dumb buffers
   #:dumb-buffer
   #:dumb-buffer-device
   #:dumb-buffer-width
   #:dumb-buffer-height
   #:dumb-buffer-bits-per-pixel
   #:dumb-buffer-handle
   #:dumb-buffer-pitch
   #:dumb-buffer-size
   #:dumb-buffer-mapping
   #:dumb-buffer-framebuffer-id
   #:dumb-buffer-mapped-p
   #:dumb-buffer-framebuffer-p
   #:dumb-buffer-minimum-size
   #:dumb-buffer-pointer
   #:dumb-buffer-pixel
   #:dumb-buffer-octets
   #:dumb-buffer-depth
   #:drm-create-dumb
   #:drm-map-dumb
   #:drm-unmap-dumb
   #:drm-add-framebuffer
   #:drm-remove-framebuffer
   #:drm-destroy-dumb
   #:drm-inventory
   #:drm-claim-dumb
   #:drm-map-dumb-memory
   #:drm-unmap-dumb-memory
   #:drm-allocate-framebuffer
   #:drm-release-framebuffer
   #:drm-release-dumb
   #:+dumb-buffer-bits-per-pixel+
   #:+dumb-buffer-depth+
   #:+mode-type-preferred+
   ;; the kernel's own view
   ;; the screen
   #:drm-take-master
   #:drm-drop-master
   #:drm-refresh-master
   #:drm-crtc-state
   #:drm-crtc-connectors
   #:drm-set-mode
   #:drm-restore-crtc
   #:drm-page-flip
   #:drm-await-flip
   #:drm-next-event
   #:drm-virtual-driver-p
   #:drm-connector-crtcs
   #:drm-scanout-crtc
   #:drm-scanout
   #:drm-open-scanout
   #:drm-close-scanout
   #:drm-scanout-device
   #:drm-scanout-crtc-id
   #:drm-scanout-connector
   #:drm-scanout-mode
   #:drm-scanout-buffers
   #:drm-scanout-saved-state
   #:drm-scanout-saved-connectors
   #:drm-scanout-front
   #:drm-scanout-frames
   #:drm-scanout-master-p
   #:drm-scanout-last-event
   #:drm-scanout-open-p
   #:drm-scanout-width
   #:drm-scanout-height
   #:drm-scanout-buffer
   #:drm-scanout-buffer-count
   #:drm-scanout-next-buffer
   #:drm-scanout-present
   #:drm-scanout-present-next
   #:drm-scanout-target
   #:drm-scanout-render
   ;; the kernel-call protocol
   #:drm-program-crtc
   #:drm-queue-page-flip
   #:drm-query-master
   #:drm-request-master
   #:drm-release-master
   #:drm-read-events
   #:drm-claim-dumb
   #:drm-map-dumb-memory
   #:drm-unmap-dumb-memory
   #:drm-allocate-framebuffer
   #:drm-release-framebuffer
   #:drm-release-dumb
   ;; events and modes as the kernel spells them
   #:parse-drm-events
   #:drm-event-type
   #:write-mode-info
   ;; the CFFI struct SETCRTC is given a mode in; callers allocate one of these
   #:drm-mode-info
   #:read-mode-info
   #:+event-vblank+
   #:+event-flip-complete+
   #:+page-flip-event+
   #:drm-sysfs-cards
   #:drm-sysfs-state
   #:drm-sysfs-driver-name))

(defpackage #:cf.session
  (:use #:cl)
  (:local-nicknames (#:ffi #:wayland.ffi))
  (:documentation
   "The seat, through libseat (docs/framework.md §2, PLAN.md phase 4, D56).

A seat is an availability subscription, not a file: logind (or seatd) calls
enable_seat and disable_seat, every device it handed out may be revoked when the
VT goes away, and a disable has to be acknowledged.  SESSION is that state
machine; the eight generics at the bottom of the module are the calls that need a
real seat, so a test can stand a recording session in their place.")
  (:export
   ;; conditions
   #:session-error
   #:session-error-operation
   #:session-error-errno
   #:session-error-path
   #:session-not-enabled
   ;; the session
   #:session
   #:session-id
   #:session-name
   #:session-seat-name
   #:session-state
   #:session-state-string
   #:session-fd
   #:session-seat-pointer
   #:session-devices
   #:session-device-paths
   #:session-open-device-count
   #:session-enabled-p
   #:session-disabled-p
   #:session-closed-p
   #:session-enable-count
   #:session-disable-count
   #:session-dispatch-count
   #:session-failed-closes
   #:session-callback-errors
   #:session-on-enabled
   #:session-on-disabled
   ;; what a compositor does with it
   #:open-session
   #:add-session-enable-hook
   #:add-session-disable-hook
   #:remove-session-enable-hook
   #:remove-session-disable-hook
   #:close-session
   #:dispatch-session
   #:open-session-device
   #:close-session-device
   #:close-all-session-devices
   #:switch-session-to
   ;; the state machine, for tests and for a fake seat
   #:note-seat-enabled
   #:note-seat-disabled
   ;; the eight calls
   #:%open-seat
   #:%close-seat
   #:%acknowledge-disable
   #:%open-device
   #:%close-device
   #:%dispatch
   #:%switch-session
   #:%seat-fd))

(defpackage #:cf.backend.libinput
  (:use #:cl)
  (:local-nicknames (#:ffi #:wayland.ffi)
                    (#:input #:cf.input)
                    (#:session #:cf.session)
                    (#:reactor #:wayland.reactor)
                    (#:srv #:wayland.server))
  (:documentation
   "Devices into events, events into the seat (docs/framework.md §2, D56).

libinput's heuristics, a descriptor that has to be dispatched, and the
translation from what a device reports (evdev codes, deltas, scroll values) to what
the seat wants (keysym names, output coordinates, named buttons).  The pure half
-- classification, pointer accumulation, clamping, key naming -- is what the unit
tests drive; the context and the event pointers are the C half.")
  (:export
   #:input-error
   #:input-error-operation
   #:input-error-detail
   #:input-driver
   #:input-driver-id
   #:input-driver-session
   #:input-driver-width
   #:input-driver-height
   #:input-driver-pointer-x
   #:input-driver-pointer-y
   #:input-driver-devices
   #:input-driver-device-names
   #:input-driver-event-count
   #:input-driver-key-count
   #:input-driver-motion-count
   #:input-driver-button-count
   #:input-driver-axis-count
   #:input-driver-ignored-count
   #:input-driver-unknown-key-count
   #:input-driver-device-added-count
   #:input-driver-device-removed-count
   #:input-driver-config-applied-count
   #:input-driver-open-count
   #:input-driver-suspended-p
   #:input-driver-callback-errors
   #:input-driver-source
   #:input-driver-sink
   #:make-input-driver
   #:open-input
   #:close-input
   #:start-input
   #:stop-input
   #:suspend-input
   #:resume-input
   #:suspend-input
   #:resume-input
   #:poll-input
   #:add-input-device
   #:input-fd
   #:compositor-sink
   #:deliver
   #:apply-raw-event
   #:read-event
   #:handle-event
   #:raw-event
   #:make-raw-event
   #:raw-event-type
   #:raw-event-kind
   #:raw-event-key
   #:raw-event-key-state
   #:raw-event-dx
   #:raw-event-dy
   #:raw-event-absolute-x
   #:raw-event-absolute-y
   #:raw-event-button
   #:raw-event-button-state
   #:raw-event-axis
   #:raw-event-value
   #:raw-event-device
   #:event-kind
   #:button-name
   #:key-state-keyword
   #:button-state-keyword
   #:axis-keyword
   #:clamp-coordinate
   #:accumulate-pointer
   #:+event-device-added+
   #:+event-device-removed+
   #:+event-keyboard-key+
   #:+event-pointer-motion+
   #:+event-pointer-button+
   #:+event-pointer-scroll-wheel+
   #:+event-pointer-scroll-finger+
   #:+event-pointer-scroll-continuous+
   #:+cap-keyboard+
   #:+cap-pointer+
   #:+cap-touch+))

(defpackage #:cf.backend.headless
  (:use #:cl)
  (:local-nicknames (#:render #:cf.render.pixman)
                    (#:png #:cf.backend.headless.png)
                    (#:input #:cf.input)
                    (#:scene #:cf.scene)
                    (#:grab #:cf.grab)
                    (#:kb #:cf.keybindings)
                    (#:srv #:wayland.server)
                    (#:ffi #:wayland.ffi)
                    (#:reactor #:wayland.reactor))
  (:import-from #:wayland
                #:wl-surface.enter
                #:wl-output.geometry
                #:wl-output.mode
                #:wl-output.scale
                #:wl-output.name
                #:wl-output.description
                #:wl-output.done)
  (:import-from #:cf.render.pixman
                #:target-octets-copy)
  (:documentation
   "The headless backend: an in-memory target of a configured size, an idle-driven
frame clock, and `read-pixels' for golden tests (docs/memory-and-rendering.md §8.1).")
  (:export
   #:headless-compositor
   #:make-headless-compositor
   #:request-frame
   #:render-frame
   #:frame-pixel
   #:target-octets-copy
   #:compositor-display
   #:compositor-width
   #:compositor-height
   #:compositor-scale
   #:compositor-device-width
   #:compositor-device-height
   #:invalidate-output
   #:output-damage-bounds
   #:compositor-frame-change
   #:compositor-client-damage
   #:compositor-draw-ms
   #:compositor-background-bounds
   #:compositor-partial-frame-count
   #:frame-pixel-device
   #:frame-octets
   #:resize-compositor
   #:compositor-surfaces
   #:compositor-shells
   #:compositor-seat
   #:compositor-modifiers
   #:compositor-scene
   #:compositor-cursor-x
   #:compositor-cursor-y
   #:seat-pointer-cursor-image
   #:sync-cursor-image
   #:compositor-cursor-visible-p
   #:compositor-placement-x
   #:compositor-placement-y
   #:on-new-toplevel
   #:on-new-popup
   #:raise-window-with-popups
   #:sync-popup-positions
   #:popup-parent-geometry
   #:popup-compositor
   #:surface-under-cursor
   #:update-pointer
   #:on-pointer-button
   #:window-node-p
   #:surface-scene-node
   #:surface-pointer-image-p
   #:compositor-grab
   #:compositor-focus-stack
   #:compositor-keybindings
   #:compositor-consumed-keys
   #:compositor-switcher
   #:window-title
   #:switcher-key
   #:switcher-pointer-press
   #:focusable-window-p
   #:start-grab
   #:end-active-grab
   #:add-keybinding
   #:remove-keybinding
   #:handle-key
   #:stop-compositor
   #:cycle-views
   #:focus-surface
   #:focus-stack-cycle
   #:focus-stack-window
   #:inject-key
   #:inject-pointer-motion
   #:inject-pointer-leave
   #:inject-pointer-button
   #:inject-pointer-axis
   #:compositor-target
   #:compositor-frame-count
   #:compositor-frame-preparer
   #:compositor-frame-presenter
   #:compositor-dirty-p
   #:write-frame-png
   #:cf-surface
   #:cf-compositor))

(defpackage #:cf.backend.vt
  (:use #:cl)
  (:local-nicknames (#:ffi #:wayland.ffi)
                    (#:drm #:cf.backend.drm)
                    (#:headless #:cf.backend.headless)
                    (#:session #:cf.session)
                    (#:render #:cf.render.pixman)
                    (#:scene #:cf.scene))
  (:documentation
   "The card a seat hands out -- the VT backend (docs/framework.md §2, 4d-3).

On a VT the compositor never opens /dev/dri itself: libseat opens the card on its
behalf, hands over a descriptor, and revokes it when the VT goes away (D56's
TakeDevice route).  VT-OUTPUT is the thing that survives that: it remembers which
card, connector and mode it programmed, opens the descriptor through the session,
takes the screen with DRM-OPEN-SCANOUT, and gives both back on a disable -- so a
compositor's whole VT story is registering this object and doing nothing else.

It does not own the reactor and does not draw: the frame loop and the renderer are
the compositor's (D58's DRM-SCANOUT-RENDER is what draws into the buffer).")
  (:export
   ;; the output
   #:vt-output
   #:open-vt-output
   #:close-vt-output
   #:enable-vt-output
   #:disable-vt-output
   #:vt-output-enabled-p
   #:vt-output-screen-p
   #:vt-output-session
   #:vt-output-path
   #:vt-output-device
   #:vt-output-scanout
   #:vt-output-connector-name
   #:vt-output-connector-explicit-p
   #:vt-output-connector-key
   #:vt-output-crtc-id
   #:vt-output-mode
   #:vt-output-width
   #:vt-output-height
   #:vt-output-enable-count
   #:vt-output-disable-count
   #:vt-output-hotplug-count
   ;; hotplug, as a question rather than an event (D62)
   #:pump-vt-hotplug
   #:blank-vt-output
   ;; resume, noticed from the two clocks (D63)
   #:pump-vt-resume
   #:resume-gap
   #:vt-output-resume-count
   #:vt-output-sleep-gap
   ;; drawing, one frame at a time
   #:vt-output-frame-target
   #:make-vt-frame-hooks
   #:render-vt-output
   #:present-vt-output
   ;; what each buffer may still be trusted to hold (D61)
   #:vt-buffer-repaint-region
   #:record-vt-frame-damage
   #:forget-vt-frame-history
   #:vt-output-frame-sequence
   #:vt-output-current-frame
   #:vt-output-damage-history
   ;; one line per frame, for a flicker read from the console (TINYWL_FRAME_LOG)
   #:vt-output-frame-log
   #:format-vt-frame-line
   ;; the seam a test replaces: a descriptor into a card
   #:open-vt-device))

(defpackage #:cf.backend.nested
  (:use #:cl)
  (:local-nicknames (#:wc #:wayland.client)
                    (#:srv #:wayland.server)
                    (#:render #:cf.render.pixman)
                    (#:input #:cf.input)
                    (#:headless #:cf.backend.headless)
                    (#:reactor #:wayland.reactor)
                    (#:ffi #:wayland.ffi))
  (:documentation
   "The nested backend: our compositor inside another compositor
(docs/framework.md §2, docs/roadmap.md phase 3).

The nested output is a parent wl_surface with shm buffers; the nested input devices
are the parent's wl_pointer and wl_keyboard; the parent's frame callback is our frame
clock.  Nothing here renders: the inner compositor draws into a mapping this package
owns, and the presentation step is attach + damage + commit.")
  (:export
   #:nested-backend
   ;; the card a seat hands out
   #:vt-output
   #:open-vt-output
   #:close-vt-output
   #:vt-output-width
   #:vt-output-height
   #:vt-output-scanout
   #:vt-output-device
   #:make-vt-frame-hooks
   #:start-nested
   #:stop-nested
   #:run-nested
   #:nested-dispatch
   #:nested-display
   #:nested-compositor
   #:nested-parent-compositor
   #:nested-surface
   #:nested-width
   #:nested-height
   #:nested-seat
   #:nested-seat-name
   #:nested-pointer
   #:nested-keyboard
   #:nested-wm-base
   #:nested-xdg-surface
   #:nested-toplevel
   #:nested-configured-p
   #:nested-mapped-p
   #:nested-awaiting-frame-p
   #:nested-closing-p
   #:nested-frame-count
   #:nested-pointer-event-count
   #:nested-key-count
   #:nested-parent-keymap-size))

(defpackage #:cf.switcher
  (:use #:cl)
  (:local-nicknames (#:scene #:cf.scene)
                    (#:font #:cf.font)
                    (#:headless #:cf.backend.headless)
                    (#:input #:cf.input)
                    (#:srv #:wayland.server))
  (:documentation
   "A visible Alt+Tab switcher: an overlay listing the focus stack, one row
highlighted, driven by keys held down (docs/framework.md §5, D51).

The switcher is a *view* of the focus stack and a *decision made at the end*: it
touches neither the stack nor the stacking order while it is open, and then makes
one call -- focus and raise the row it was showing.  It owns no policy beyond
that, so a compositor chooses it by binding START-SWITCHER.")
  (:export
   #:switcher
   #:start-switcher
   #:advance-switcher
   #:commit-switcher
   #:cancel-switcher
   #:switcher-open-p
   #:switcher-entries
   #:switcher-index
   #:switcher-selected
   #:switcher-titles
   #:switcher-snapshots
   #:switcher-layout
   #:thumbnail-size
   #:switcher-highlight
   #:switcher-modifier
   #:+switcher-panel-colour+
   #:+switcher-border-colour+
   #:+switcher-highlight-colour+
   #:+switcher-text-colour+
   #:+switcher-fallback-title+
   #:+switcher-thumbnail-width+
   #:+switcher-thumbnail-height+
   #:+switcher-thumbnail-gap+))

(defpackage #:cf
  (:nicknames #:cl-compositor-framework)
  (:import-from #:cf.backend.headless
                #:headless-compositor
                #:make-headless-compositor
                #:request-frame
                #:write-frame-png
                #:render-frame
                #:frame-pixel
                #:target-octets-copy
                #:compositor-display
                #:compositor-width
                #:compositor-height
                #:compositor-scale
                #:compositor-device-width
                #:compositor-device-height
                #:invalidate-output
                #:output-damage-bounds
                #:compositor-frame-change
                #:compositor-client-damage
                #:compositor-draw-ms
                #:compositor-background-bounds
                #:compositor-partial-frame-count
                #:frame-pixel-device
                #:frame-octets
                #:resize-compositor
                #:compositor-surfaces
                #:compositor-shells
                #:compositor-seat
                #:compositor-modifiers
                #:compositor-scene
                #:compositor-cursor-x
                #:compositor-cursor-y
                #:seat-pointer-cursor-image
                #:sync-cursor-image
                #:compositor-cursor-visible-p
                #:compositor-placement-x
                #:compositor-placement-y
                #:on-new-toplevel
                #:on-new-popup
                #:raise-window-with-popups
                #:sync-popup-positions
                #:popup-parent-geometry
                #:popup-compositor
                #:surface-under-cursor
                #:update-pointer
                #:on-pointer-button
                #:window-node-p
                #:surface-scene-node
                #:compositor-grab
                #:compositor-focus-stack
                #:compositor-keybindings
                #:compositor-consumed-keys
                #:compositor-switcher
                #:window-title
                #:focusable-window-p
                #:switcher-key
                #:switcher-pointer-press
                #:start-grab
                #:end-active-grab
                #:add-keybinding
                #:remove-keybinding
                #:handle-key
                #:stop-compositor
                #:cycle-views
                #:focus-surface
                #:focus-stack-cycle
                #:focus-stack-window
                #:inject-key
                #:inject-pointer-motion
                #:inject-pointer-leave
                #:inject-pointer-button
                #:inject-pointer-axis
                #:compositor-frame-count
                #:compositor-dirty-p
                #:cf-surface
                #:cf-compositor)
  (:import-from #:cf.backend.nested
                #:nested-backend
                #:start-nested
                #:stop-nested
                #:run-nested
                #:nested-dispatch
                #:nested-display
                #:nested-compositor
                #:nested-frame-count
                #:nested-key-count
                #:nested-pointer-event-count
                #:nested-parent-keymap-size
                #:nested-closing-p
                #:nested-mapped-p)
  (:import-from #:cf.render.pixman
                #:make-target
                #:make-target-over-pointer
                #:destroy-target
                #:fill-target
                #:fill-rect
                #:composite-buffer
                #:composite-bitmap
                #:pixman-format-for-shm)
  (:import-from #:cf.backend.headless.png
                #:write-png)
  (:import-from #:cf.font
                #:rasterize-text
                #:text-width
                #:text-height
                #:truncate-text)
  (:import-from #:cf.switcher
                #:start-switcher
                #:advance-switcher
                #:commit-switcher
                #:cancel-switcher
                #:switcher-open-p
                #:switcher-entries
                #:switcher-index
                #:switcher-selected)
  (:import-from #:cf.backend.libinput
                #:start-input
                #:stop-input
                #:suspend-input
                #:resume-input)
  (:import-from #:cf.backend.vt
                #:vt-output
                #:open-vt-output
                #:close-vt-output
                #:vt-output-width
                #:vt-output-height
                #:vt-output-scanout
                #:vt-output-device
                #:make-vt-frame-hooks)
  (:documentation
   "The compositor framework: everything wlroots provides, in Lisp.

Phase 2a is the first slice with code in it: `CF.RENDER.PIXMAN` is the reference
renderer (docs/memory-and-rendering.md §7) and `CF.BACKEND.HEADLESS` is the
output path that needs no privileges, no display and no hardware
(docs/memory-and-rendering.md §8.1).  The other modules named in
docs/framework.md §1 follow.")
  (:export
   ;; the headless compositor
   #:headless-compositor
   #:make-headless-compositor
   #:request-frame
   #:render-frame
   #:frame-pixel
   #:target-octets-copy
   #:compositor-display
   #:compositor-width
   #:compositor-height
   #:compositor-scale
   #:compositor-device-width
   #:compositor-device-height
   #:invalidate-output
   #:output-damage-bounds
   #:compositor-frame-change
   #:compositor-client-damage
   #:compositor-draw-ms
   #:compositor-background-bounds
   #:compositor-partial-frame-count
   #:frame-pixel-device
   #:frame-octets
   #:resize-compositor
   #:compositor-surfaces
   #:compositor-shells
   #:compositor-seat
   #:compositor-modifiers
   #:compositor-scene
   #:compositor-cursor-x
   #:compositor-cursor-y
   #:seat-pointer-cursor-image
   #:sync-cursor-image
   #:compositor-cursor-visible-p
   #:compositor-placement-x
   #:compositor-placement-y
   #:on-new-toplevel
   #:on-new-popup
   #:raise-window-with-popups
   #:sync-popup-positions
   #:popup-parent-geometry
   #:popup-compositor
   #:surface-under-cursor
   #:update-pointer
   #:on-pointer-button
   #:window-node-p
   #:surface-scene-node
   #:compositor-grab
   #:compositor-focus-stack
   #:compositor-keybindings
   #:compositor-consumed-keys
   #:start-grab
   #:end-active-grab
   #:add-keybinding
   #:remove-keybinding
   #:handle-key
   #:stop-compositor
   #:cycle-views
   #:focus-surface
   #:focus-stack-cycle
   #:focus-stack-window
   #:inject-key
   #:inject-pointer-motion
   #:inject-pointer-leave
   #:inject-pointer-button
   #:inject-pointer-axis
   #:start-input
   #:stop-input
   #:suspend-input
   #:resume-input
   #:compositor-frame-count
   #:write-png
   #:write-frame-png
   ;; the font and the switcher (D51)
   #:rasterize-text
   #:text-width
   #:text-height
   #:truncate-text
   #:window-title
   #:compositor-switcher
   #:start-switcher
   #:advance-switcher
   #:commit-switcher
   #:cancel-switcher
   #:switcher-open-p
   #:switcher-entries
   #:switcher-index
   #:switcher-selected
   ;; the nested backend
   ;; the card a seat hands out
   #:vt-output
   #:open-vt-output
   #:close-vt-output
   #:vt-output-width
   #:vt-output-height
   #:vt-output-scanout
   #:vt-output-device
   #:make-vt-frame-hooks
   #:start-nested
   #:stop-nested
   #:run-nested
   #:nested-dispatch
   #:nested-backend
   #:nested-display
   #:nested-compositor
   #:nested-frame-count
   #:nested-key-count
   #:nested-pointer-event-count
   #:nested-parent-keymap-size
   #:nested-closing-p
   #:nested-mapped-p
   ;; the renderer
   #:make-target
   #:make-target-over-pointer
   #:make-region
   #:destroy-region
   #:region-empty-p
   #:region-bounds
   #:region-rectangles
   #:destroy-target
   #:fill-target
   #:fill-rect
   #:composite-buffer
   #:composite-bitmap
   #:pixman-format-for-shm
   ;; protocol subclasses
   #:cf-surface
   #:cf-compositor))
