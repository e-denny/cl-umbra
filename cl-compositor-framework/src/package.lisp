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
   #:fill-target
   #:fill-rect
   #:composite-buffer
   #:composite-bitmap
   #:render-surface
   #:pixman-format-for-shm
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

(defpackage #:cf.scene
  (:use #:cl)
  (:local-nicknames (#:render #:cf.render.pixman))
  (:import-from #:wayland.server
                #:surface-current-buffer
                #:surface-current-x
                #:surface-current-y
                #:surface-input-region
                #:surface-mapped-p
                #:shm-buffer-width
                #:shm-buffer-height)
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
   #:scene-cursor
   #:scene-cursor-visible-p
   #:scene-add-node
   #:scene-remove-node
   #:scene-hit-test
   #:scene-render
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
   ;; the built-in cursor
   #:+cursor-width+
   #:+cursor-height+
   #:make-cursor-image))

(defpackage #:cf.grab
  (:use #:cl)
  (:local-nicknames (#:scene #:cf.scene))
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
  (:documentation
   "The headless backend: an in-memory target of a configured size, an idle-driven
frame clock, and `read-pixels' for golden tests (docs/memory-and-rendering.md §8.1).")
  (:export
   #:make-headless-compositor
   #:render-frame
   #:frame-pixel
   #:target-octets
   #:compositor-display
   #:compositor-width
   #:compositor-height
   #:compositor-surfaces
   #:compositor-shells
   #:compositor-seat
   #:compositor-modifiers
   #:compositor-scene
   #:compositor-cursor-x
   #:compositor-cursor-y
   #:compositor-cursor-visible-p
   #:compositor-placement-x
   #:compositor-placement-y
   #:on-new-toplevel
   #:surface-under-cursor
   #:update-pointer
   #:surface-scene-node
   #:compositor-grab
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
   #:inject-key
   #:inject-pointer-motion
   #:inject-pointer-button
   #:inject-pointer-axis
   #:compositor-target
   #:compositor-frame-count
   #:write-frame-png
   #:cf-surface
   #:cf-compositor))

(defpackage #:cf
  (:use #:cl)
  (:nicknames #:cl-compositor-framework)
  (:import-from #:cf.backend.headless
                #:make-headless-compositor
                #:write-frame-png
                #:render-frame
                #:frame-pixel
                #:compositor-display
                #:compositor-width
                #:compositor-height
                #:compositor-surfaces
                #:compositor-shells
                #:compositor-seat
                #:compositor-modifiers
                #:compositor-scene
                #:compositor-cursor-x
                #:compositor-cursor-y
                #:compositor-cursor-visible-p
                #:compositor-placement-x
                #:compositor-placement-y
                #:on-new-toplevel
                #:surface-under-cursor
                #:update-pointer
                #:surface-scene-node
                #:compositor-grab
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
                #:inject-key
                #:inject-pointer-motion
                #:inject-pointer-button
                #:inject-pointer-axis
                #:compositor-frame-count
                #:cf-surface
                #:cf-compositor)
  (:import-from #:cf.render.pixman
                #:make-target
                #:fill-target
                #:fill-rect
                #:composite-buffer
                #:composite-bitmap
                #:render-surface
                #:pixman-format-for-shm)
  (:import-from #:cf.backend.headless.png
                #:write-png)
  (:documentation
   "The compositor framework: everything wlroots provides, in Lisp.

Phase 2a is the first slice with code in it: `CF.RENDER.PIXMAN` is the reference
renderer (docs/memory-and-rendering.md §7) and `CF.BACKEND.HEADLESS` is the
output path that needs no privileges, no display and no hardware
(docs/memory-and-rendering.md §8.1).  The other modules named in
docs/framework.md §1 follow.")
  (:export
   ;; the headless compositor
   #:make-headless-compositor
   #:render-frame
   #:frame-pixel
   #:compositor-display
   #:compositor-width
   #:compositor-height
   #:compositor-surfaces
   #:compositor-shells
   #:compositor-seat
   #:compositor-modifiers
   #:compositor-scene
   #:compositor-cursor-x
   #:compositor-cursor-y
   #:compositor-cursor-visible-p
   #:compositor-placement-x
   #:compositor-placement-y
   #:on-new-toplevel
   #:surface-under-cursor
   #:update-pointer
   #:surface-scene-node
   #:compositor-grab
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
   #:inject-key
   #:inject-pointer-motion
   #:inject-pointer-button
   #:inject-pointer-axis
   #:compositor-frame-count
   #:write-png
   #:write-frame-png
   ;; the renderer
   #:make-target
   #:fill-target
   #:fill-rect
   #:composite-buffer
   #:composite-bitmap
   #:render-surface
   #:pixman-format-for-shm
   ;; protocol subclasses
   #:cf-surface
   #:cf-compositor))
