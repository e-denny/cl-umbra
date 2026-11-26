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
   #:+keys+
   #:key-entry
   #:keycode
   #:xkb-keycode
   #:key-name
   #:key-modifier
   #:key-modifier-mask
   #:modifier-mask
   #:make-keymap
   #:modifiers
   #:make-modifiers
   #:modifiers-depressed
   #:modifiers-latched
   #:modifiers-locked
   #:modifiers-group
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
                #:shm-buffer-format)
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
   ;; nodes
   #:scene-node
   #:node-parent
   #:node-x
   #:node-y
   #:node-position
   #:set-node-position
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

(defpackage #:cf.backend.headless
  (:use #:cl)
  (:local-nicknames (#:render #:cf.render.pixman)
                    (#:png #:cf.backend.headless.png)
                    (#:input #:cf.input)
                    (#:scene #:cf.scene)
                    (#:grab #:cf.grab)
                    (#:kb #:cf.keybindings)
                    (#:srv #:wayland.server)
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
   #:switcher-layout
   #:switcher-highlight
   #:switcher-modifier
   #:+switcher-panel-colour+
   #:+switcher-border-colour+
   #:+switcher-highlight-colour+
   #:+switcher-text-colour+
   #:+switcher-fallback-title+))

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
