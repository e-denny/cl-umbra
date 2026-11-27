# `cl-compositor-framework`

A Lisp framework that does what wlroots does for C compositors: it owns the boring,
error-prone, hardware-and-protocol plumbing so that a compositor is a few hundred lines of
policy. It is **not** a binding to wlroots and it does not link it (D2).

This document defines what the framework provides, the contracts each module upholds, and
what a compositor author actually writes.

---

## 1. Module map

Names are ours; the right-hand column states the correspondence openly, because the
decomposition is the part worth copying.

| Module | Corresponds to | Phase | Responsibility |
|---|---|---|---|
| `cf.backend` | `wlr_backend` + autocreate | 2 | one interface over headless, nested, DRM; outputs and input device events |
| `cf.backend.headless` | `wlr_backend_headless` | 2 | fake output(s), frame timer, deterministic pixels |
| `cf.backend.nested` | `wlr_backend_wayland` | 3 | our compositor as a client of a parent compositor |
| `cf.backend.drm` | `wlr_backend_drm` (dumb path) | 4 | the card, connectors, encoders, CRTCs, mode choice and dumb buffers (D54); modeset, page flips and VT handover next |
| `cf.backend.libinput` | `wlr_backend_libinput` | 4 | device enumeration, hotplug, event decoding |
| `cf.backend.multi` | `wlr_backend_multi` | 4 | several backends in one session (DRM + nested for debugging) |
| `cf.session` | `wlr_session` (libseat) | 4 | seat/VT ownership, device open, switch away/back |
| `cf.render` | `wlr_renderer` | 2 | renderer protocol, format tables, `init-wl-display` |
| `cf.render.pixman` | `wlr_renderer_pixman` | 2 | CPU reference renderer |
| `cf.render.gles2` | `wlr_renderer_gles2` | 5 | GPU renderer, EGL/GBM, shaders |
| `cf.render.damage` | `wlr_damage_ring` | 2 | damage regions, buffer age — landed inside `cf.scene` and `cf.backend.*` (D48, D50) rather than as a module of its own: a region wrapper in the renderer, the diff in the scene, the buffer ring in the backend |
| `cf.render.allocator`, `cf.render.swapchain`, `cf.render.dmabuf` | same names | 5 | GPU buffer lifecycle |
| `cf.scene` | `wlr_scene` | 2, 5, 7 | retained node tree, output layers, hit testing, damage |
| `cf.font` | (none) | 3i | a 5x7 bitmap font and its rasteriser: wlroots draws no text, so every compositor brings its own (D51) |
| `cf.switcher` | (none) | 3i | the visible Alt+Tab overlay over the focus stack, a picture and a title per row (D51, D52) |
| `cf.output` | `wlr_output` | 2 | mode/scale/transform state, commit, frame scheduling |
| `cf.util.output-layout` | `wlr_output_layout` | 2 | arrangement in layout coordinates |
| `cf.types.compositor`, `.surface`, `.region` | `wlr_compositor`, `wlr_surface` | 2 | core protocol objects + surface state machine |
| `cf.types.output` | `wlr_output` protocol side | 2 | `wl_output`, `zxdg_output_v1` |
| `cf.types.seat`, `.cursor` | `wlr_seat`, `wlr_cursor` | 3 | focus, capabilities, pointer/keyboard/touch, cursor |
| `cf.types.xdg-shell` | `wlr_xdg_shell` | 3 | policy over the v1 state machine in `cl-wayland-server`; popups and positioners in 3f (D44) |
| `cf.types.subcompositor` | `wlr_subcompositor` | 3 | subsurfaces, sync/desync, sublayers |
| `cf.types.layer-shell` | `wlr_layer_shell_v1` | 6 | panels, notifications, exclusive zones |
| `cf.types.data-device` | `wlr_data_device_manager` | 6 | clipboard, primary selection, DnD |
| `cf.types.decoration` | `wlr_xdg_decoration` | 6 | server-side decoration negotiation |
| `cf.types.screencopy` | `wlr_screencopy` | 6 | capture, portals |
| `cf.types.session-lock` | `wlr_session_lock` | 6 | lock screens |
| `cf.types.activation`, `.foreign-toplevel`, `.output-management`, `.idle-inhibit`, `.shortcuts-inhibit` | same | 6 | desktop integration |
| `cf.types.pointer-constraints`, `.relative-pointer`, `.tablet`, `.gestures`, `.ime`, `.syncobj`, `.color` | same | 7 | |
| `cf.util` | `wlr_util` | 2 | box, region, matrix, edges, time, log, xcursor |
| (none) | `wlr_xwayland` | 6 tail | deliberately absent: `xwayland-satellite` needs only `xdg-shell` + `wp-viewporter` (D12) |

## 2. Backends

```lisp
(defclass backend () ())

(defgeneric start (backend display)   "Attach to DISPLAY, create globals, begin emitting events.")
(defgeneric stop (backend))
(defgeneric fds (backend)             "Alist of (fd . kind) for the reactor to poll.")
(defgeneric outputs (backend))
(defgeneric name (backend))
```

Events are generic functions on the compositor object:

```lisp
(defgeneric on-new-output (compositor backend output))
(defgeneric on-output-removed (compositor backend output))
(defgeneric on-new-input (compositor backend device))
(defgeneric on-input-event (compositor backend device event))
(defgeneric on-session-switch (compositor backend active-p))
```

Phase 2a implements the headless case as one object rather than a backend/compositor pair:
`cf:make-headless-compositor` creates a display with `wl_compositor`, `wl_shm` and `wl_output`
globals, a pixman target, and a scene (§4). Phase 3e added the second backend, and the seam it
needed turned out to be two function slots rather than a class hierarchy — the compositor owns
everything except *where the frame goes* and *what presenting it means*:

```lisp
(setf (cf.backend.headless:compositor-frame-preparer c)
      (lambda (compositor) ...))   ; -> the target to draw into, and its minimum damage
                                   ;    (:full, a region, or NIL), or NIL to defer
(setf (cf.backend.headless:compositor-frame-presenter c)
      (lambda (compositor target damage) ...))  ; after the draw, before frame callbacks
```

The presenter is handed a target that already holds the frame it is presenting: fill (clipped to
the damage), prune, draw, present, then release the clients' buffers and fire their callbacks.
`damage` is `:full` or a region in device pixels — what the frame actually painted — and a
nested presenter turns exactly that into `wl_surface.damage`, so a nested frame costs its damage
rather than its size (D48, D50). A nested target is the parent's `wl_shm` mapping and the parent
reads it when it likes, so presenting before the draw commits the background paint and nothing
else — a flickering, half-drawn window in the parent (D38). An empty frame is presented too, with
an empty region: the backend decides that there is nothing to send, and returns the buffer it was
holding.

`cf.backend.nested` is a `nested-backend` object that *owns* a headless compositor and sets
those two slots:

```lisp
(cf:start-nested :parent-path "/run/user/1000/wayland-0"   ; the parent's socket
                 :width 256 :height 256
                 :display-name "wayland-1")                 ; the nested socket
```

It connects to the parent as a client (`cl-wayland-client`), maps an `xdg_toplevel` (or a
roleless surface when the parent has no xdg-shell), allocates two `wl_shm` buffers, and makes
each buffer's mapping a pixman target — so the nested compositor draws **straight into the
parent's buffer** and presenting is attach + damage + commit. The parent's frame callback is
the frame clock: at most one frame is in flight, and a frame that finds both buffers owned by
the parent is deferred until a `wl_buffer.release` arrives. Input goes the other way: the
parent's pointer and keyboard events become the same `cf:inject-pointer-motion`,
`cf:inject-pointer-button` and `cf:inject-key` calls a test makes, with evdev key codes
translated through our key table and modifier state recomputed from our keymap.

Standalone, `cf:run-nested` polls the parent connection and the nested compositor's reactor;
in one image (the gate, a test), `cf:nested-dispatch` advances both once. The two reactors are
not merged into a single epoll wait in v0 — that is phase-4 work, when a third backend makes it
worth doing. The nested output's size follows the parent's `xdg_toplevel.configure`: the output,
its scene and its shm buffers become the size the parent offers, and a configure of 0x0 (or none
at all) leaves the size we chose (D37). Inner clients are not resized -- a client's size is its
own statement -- so a window can be larger than the output, exactly as on a small screen.

The pointer's *image* is the parent's: it already draws its cursor over our surface, so the
nested session sets `compositor-cursor-visible-p` to NIL rather than drawing a second arrow in
the same place (D39). `render-frame` projects that flag onto the scene immediately before
drawing, so a compositor states the fact once and the renderer obeys it. A client's own cursor
surface (`wl_pointer.set_cursor`) is recorded by the seat and still not drawn — phase 5.

`cf.backend.drm` is the third backend, and its first half is the part of KMS that can run while
another session owns the screen. It is deliberately not a `backend` object yet: it has no output
and presents nothing, because presenting needs `SETCRTC` and `PAGE_FLIP`, which need DRM master,
which means taking the display away from whoever has it (D54).

```lisp
(let ((device (cf.backend.drm:open-drm-device "/dev/dri/card1")))
  (unwind-protect
       (let* ((inventory (cf.backend.drm:drm-inventory device))
              (connector (cf.backend.drm:drm-inventory-connector inventory "HDMI-A-1"))
              (mode (cf.backend.drm:drm-pick-mode connector))
              (buffer (cf.backend.drm:drm-create-dumb
                       device
                       (cf.backend.drm:drm-mode-hdisplay mode)
                       (cf.backend.drm:drm-mode-vdisplay mode))))
         (cf.backend.drm:drm-map-dumb device buffer)
         ;; a pixman target over the mapping, at the driver's pitch, is a frame
         (let ((target (cf:make-target-over-pointer
                        (cf.backend.drm:dumb-buffer-mapping buffer)
                        (cf.backend.drm:dumb-buffer-width buffer)
                        (cf.backend.drm:dumb-buffer-height buffer)
                        :stride (cf.backend.drm:dumb-buffer-pitch buffer))))
           (cf:fill-target target #xFF101820)
           (cf:destroy-target target))
         (cf.backend.drm:drm-add-framebuffer device buffer)
         (cf.backend.drm:drm-destroy-dumb device buffer))
    (cf.backend.drm:close-drm-device device)))
```

What it provides: a device with its driver name, version, whether it is master and its
capabilities; an inventory of CRTCs, connectors, encoders and framebuffers as Lisp structs with
no C memory behind them; `drm-pick-mode` (exact size, then the monitor's preferred mode, then the
largest, then the fastest) and integer millihertz refresh rates; dumb buffers with the driver's
own pitch and size, mapped read-write, given a framebuffer id, and released in the order KMS
requires. Every release is one call, `drm-destroy-dumb`, because the order is the contract
(framebuffer, mapping, memory).

Two things the module does on purpose. The kernel's six calls are generic functions
(`drm-claim-dumb`, `drm-map-dumb-memory`, `drm-unmap-dumb-memory`, `drm-allocate-framebuffer`,
`drm-release-framebuffer`, `drm-release-dumb`) and everything above them is plain functions over
those, so a test can hand in a recording device and check the arguments and the release order
with no card. And the structs are transcribed from the headers with their sizes asserted at load
time, so a build needs libdrm's library and not its headers or a C compiler.

Contracts:

- A backend only ever *reports*; it never calls into the scene, seat or shell. A compositor
  that ignores an event must still behave sanely. (The nested backend reports by calling the
  compositor's own public reporting functions — `inject-*`, `request-frame` — which is the
  same path a test and a future libinput backend take.)
- `outputs` is stable within a call; outputs are destroyed only after
  `on-output-removed` returns.
- Nested and headless backends must be usable with no privileges and no hardware, because
  they are the entire test strategy.
- The DRM backend must survive: no connected outputs, a connector with no modes, a CRTC
  already in use, a page-flip `EINVAL`, and a VT switch at any point.

Autocreation for `cl-tinywl`/`cl-umbra` follows wlroots' spirit: `WAYLAND_DISPLAY` set and
`--nested` requested → nested; a DRM device openable → DRM; otherwise headless. Explicit is
better than magic, so the default is a flag, and autocreate is a convenience wrapper.

## 3. Outputs and frame pacing

```lisp
(defclass output ()
  ((backend :reader backend)
   (width 0 :accessor width) (height 0 :accessor height)
   (physical-width-mm …) (physical-height-mm …)
   (mode …) (scale 1 :accessor scale) (transform :normal :accessor transform)
   (enabled-p t) (adaptive-sync-p nil)
   (damage :initform (make-region) :reader damage)
   (frame-clock …)                 ; vblank or timer driven
   (pending-state …) (current-state …)))   ; phase 5: atomic commit
```

- **Commit is all-or-nothing.** `(commit-output output &key mode scale transform enable)`
  validates, applies, and on failure leaves the previous configuration intact. Clients see
  one `wl_output` update sequence, never a half-applied state.
- **`on-frame` is driven by the display.** DRM: page-flip completion (`read()` on the DRM
  fd). Headless: timer, or — phase 2a — an idle that runs once per reactor cycle when a
  surface committed, which is the zero-latency degenerate case of the same rule. A compositor must not
  render "as fast as possible": the output's clock is the only producer of frames.
- **Frame callbacks** for a surface are sent after the frame containing it is presented, with
  the presentation timestamp. Never at commit time, never for surfaces that were not
  rendered.
- **Damage** is accumulated per output, scanned out once, then cleared. Buffer age is tracked
  per swapchain slot.
- **Scheduling policy** in the framework: if nothing is damaged and no client requested a
  frame callback, skip the frame entirely (and do not spin). This one rule is worth a lot of
  battery.

## 4. Scene graph

*Phase 3c implemented v0, in `cl-compositor-framework/src/scene.lisp` (D31): nodes, positions,
stacking, hit testing and the cursor. Phase 2b added damage, clipping, opaque culling and the
scale between layout coordinates and device pixels (D48, D49). The Alt+Tab switcher added the
overlay root and a text node (`cf.font`, D51), and the picture in each of its rows (a
`snapshot-node`, D52). Layers and per-output layout are still ahead.*

*One frame is one list.* `scene-draw-list` turns the tree into draw items in device pixels, back
to front, with the cursor last; `scene-render-items` draws them, each through a clip that is its
rectangle minus everything opaque above it and minus everything undamaged; and the compositor
diffs this frame's list against the last one to get the damage, so a moved node, a moved popup
and a moved pointer need no bookkeeping of their own. A surface's damage from its commits is the
*content* half of the damage, carried on its item.

```
scene
├── root (tree-node)
│   ├── buffer-node   ← a mapped toplevel, placed by the compositor
│   └── rect-node     ← background, border, letterboxing
├── overlay (tree-node)        ← the switcher: above every window, never hit-tested
│   ├── rect-node              ← the panel, the outline, the selection bar
│   ├── snapshot-node          ← one picture per row: the window, taken once (D52)
│   └── text-node              ← one row per window, in the built-in font
└── cursor (image-node)   ← drawn after the root, never hit-tested
```

Node types: `tree` (a group; the root and the overlay are two), `buffer` (a mapped surface, sized
by its buffer), `rect` (solid premultiplied colour), `bitmap` (pixels we own: `image`, today the
cursor, and `snapshot`, a window's picture taken once, D52), and `text` (a string in the 5x7 font,
D51), with `offscreen` arriving with phase 7's effects. Every node has a position in its parent's
space, a visibility flag and a parent.

- **Coordinates**: a node's position is in its parent's space; a root child's is therefore
  output-local, which is the space every policy, the renderer and hit testing use. That space is
  *layout* space: the target's pixels are layout times the output's scale, and the conversion
  happens once per frame in `scene-draw-list`. A node's width is the *layout* size of its
  surface — its buffer divided by the client's buffer scale, axes swapped for a quarter turn —
  so hit testing, configure sizes and grabs are all in the same units the client was told about
  (D49). A node's own position
  and its surface's `attach` offset are *different* things and are added at draw time: the
  compositor says where the window is, the client says where its content sits inside it. A
  surface with no shell role keeps the origin of the scene and is drawn at its attach offset —
  the phase-2a behaviour, unchanged — **except** a surface a client has named as the pointer's
  image (`wl_pointer.set_cursor`), which is never drawn: it is a cursor picture, not a window,
  and a roleless surface given a node puts it at the output's origin for good (D40).
- **Stacking** is the order nodes were placed in, not the order they committed in: committing
  is not raising (D31.3). `scene:node-raised` is the call a click-to-raise policy makes.
- **Placement** is a policy hook, not a framework rule:
  `(defmethod cf:on-new-toplevel ((c my-compositor) surface) ...)`. The default is a cascade
  at 32-pixel steps from the origin, which is enough to make two windows two windows.
- **The cursor is drawn last** — literally last in the draw list, after every window, because a
  pointer drawn under a window is a pointer nobody can see (a bug this slice had, and the scene
  gate's cursor check found it). At output scale 2 it is drawn 32x32 device pixels rather than
  resampled from a 16x16 theme image; a themed, per-size cursor is phase 5.
- **Hit testing**: `(cf.scene:scene-hit-test scene x y)` walks front to back and returns
  `(values node local-x local-y)`; a `buffer-node` is hit only where it is mapped, inside its
  buffer, and inside its committed **input region** (an empty region makes it click-through).
  `cf:surface-under-cursor` is the framework's `desktop_view_at`: it turns the node into a
  surface. A popup is hit-testable like any other node, and its node is placed from its
  *parent's* node plus the configure the protocol layer computed (`sync-popup-node`), asked for
  every frame because the parent can move (D44); it is not a window (`window-node-p` demands
  the toplevel role), and a raise takes a window's popups with it.
- **The cursor is drawn last, and it is whoever's picture it is**: the client's cursor image
  (`wl_pointer.set_cursor`) at pointer minus hotspot when the client has installed one, otherwise
  the session's own arrow. A client's image is never a scene node (D40) but is drawn from the
  recording the seat keeps, and a nested session owns the picture inside its own window: it blanks
  its parent and draws the client's image, or its own arrow when there is none (D41).
- **A resize moves the edge it grabbed, and the dragged edge leads**: `cf.grab` records the edge
  opposite the dragged one and puts the node back so that edge stays still. The placement happens
  twice, on purpose: on every motion at *the size the drag asked for* (`place-anchored`), so the
  edge under the hand is under the hand now rather than one configure round trip later (D53), and
  when the client's answer arrives at *the size the client chose* (`grab-anchored`), which keeps the
  anchored edge exact however a client answers (D42). What is inside the window is the client's, so
  during that round trip the content is either short of the far edge or overlapping it — the hand
  leads and the pixels follow. An edge is where the pointer can reach: a client-side decoration's
  input region, not its surface's bounding box (D42, `tinywl:pointer-reach`).
- **Resize arithmetic speaks window geometry, and both directions have bounds**: `node-geometry`
  reads `xdg_surface.set_window_geometry`, so a configure asks for the size a client means rather
  than its buffer (a decorated window is otherwise off by its decoration). `clamp-to-output` keeps
  a window of a given size inside an output of a given size — fully inside if it fits, always
  covering it if it does not; `clamp-node-to-output` applies that to a node *by its geometry*, and
  a pointer that leaves the output ends the grab rather than dragging unseen (D43). A **move** is
  clamped on every motion; a **resize** is clamped by `resize-grab-max-size`, which is the
  distance from the anchored edge to the output's border on the axis being dragged, so the edge
  under the pointer stops at the border with the opposite edge still (D46); and when the *output*
  changes size — a nested session following its parent (D37) — `reclamp-windows` applies the same
  rule to every window, because a window left outside a shrunken output cannot be seen or clicked.
- **A grab clamps the pointer; a leave ends it** (D47). A pointer position outside the output is
  clamped for the grab, so a corner drag past the bottom edge keeps resizing the width, while the
  drawn cursor stays where the device says (D43). `cf:inject-pointer-leave` is the *statement*
  that the pointer is gone — a nested session's parent `leave` is exactly that, and it ends the
  grab, which is what stops a nested session swallowing the mouse. In a nested session leaving
  the window therefore still stops the drag: the parent sends no coordinates afterwards.
- **Retained, not immediate**: the tree survives frames, which is what makes rules,
  workspaces, animations and overview possible without a rewrite (D10).
- **Damage, clipping and culling** are per frame and per item: the diff of two draw lists plus
  the damage clients reported, painted through a pixman region; an item that is opaque hides
  what is under it; a translucent one hides nothing (D48).
- **The overlay is a second root** (D51): `scene-overlay` is drawn after the tree and before the
  cursor, and `scene-add-overlay-node` puts a node in it. Nothing that hit-tests, raises, cycles
  or clamps walks it, so an overlay node cannot be clicked, focused or moved by accident — the
  rule the cursor already followed (D31), applied to the second thing that must be visible and
  untouchable. It is not a layer: a layer is layer-shell's namespace owned by another client
  (phase 6); an overlay has no owner and no protocol. Opening or closing one changes the draw
  list's *order*, which the damage diff rightly reads as a full repaint; moving one selection
  bar damages two rectangles.
- **Text is a node kind, and the font is a table** (D51): `cf.font` holds printable ASCII as 95
  glyphs of seven rows of five, validated at load; `text-node` measures itself in layout pixels
  (five cells per glyph plus one of gap) and is rasterised at the output's scale, so a glyph at
  scale 2 is 10x14 device pixels *drawn* rather than a small picture upscaled. The raster is
  cached on the text, the colour and the scale, so a frame that redraws the same title allocates
  nothing for it. No shaping, no kerning, no BiDi, one size, and a character outside ASCII draws
  as `?`; a real font arrives when something needs one.
- **A row's picture is a snapshot, taken once** (D52). `scene:snapshot-surface` reads a
  surface's current buffer into premultiplied ARGB8888 at *the resolution it will be drawn at*
  (the layout box times the output scale), and `make-snapshot-node` draws those octets as a box.
  Drawing is then a 1:1 copy -- no filter, no per-frame resample -- and the picture is a constant,
  which is what makes it honest with the damage diff: the item's signature carries the octets,
  and a vector we allocated does not change, so a client that keeps repainting its window does
  not keep repainting its thumbnail. It is a `bitmap-node`, not a `buffer-node`, for exactly that
  reason: a buffer node's size and content are the client's, a snapshot's are ours. The single
  downscale happens at open, bilinear -- pictures, unlike glyphs, do not want nearest. A window
  with no buffer gets no picture rather than a placeholder.
- **`set-node-size` resizes what the compositor owns**: a rectangle (a selection bar is as tall as
  the row it selects, D52) and a bitmap's drawn size. A buffer node's size is the client's answer,
  a text node's is its font's, and a snapshot's is the box it was taken for; setting those would
  be a second truth about the same pixels (D10).

`cl-tinywl` uses every node type: a buffer, the rectangles of the switcher's panel, outline and
bar, one snapshot per row, one title per row, and the cursor's image. `cl-umbra` adds
per-workspace subtrees and animated transforms (phase 7).

## 5. Seat, focus and grabs

```lisp
(defclass seat ()                       ; lives in cl-wayland-server: it is the
  ((capabilities …) (keyboard-focus …)  ; protocol state machine, not policy
   (pointer-focus …) (keymap …) (repeat …)))
```

*Phase 3b implements the seat, the keymap, focus and the pointer/keyboard events. Phase 3c adds
pointer focus that follows the pointer, click-to-focus and a drawn cursor (D32). Grabs, the
focus stack, cursor shapes and touch are still ahead.*

- **Focus** is explicit: `(set-keyboard-focus seat surface serial)`,
  `(set-pointer-focus seat surface x y serial)`. Enter/leave, `set_activated` on the toplevel,
  and keyboard `enter`/`leave` events all follow from one call, so they cannot drift apart.
  `cf:focus-surface` is that call for a compositor, and the headless backend makes it **once per
  map** — the condition is "this surface's node was just created", not "this surface is not
  focused", because the second rule hands the keyboard to whichever of two redrawing clients
  committed last (D32.3).
- **Two focus questions, two answers.** Pointer focus follows the *pointer*: motion hit-tests
  through the scene, enters the surface under it, leaves the one that had it, or sends motion if
  it is the same surface, in surface-local coordinates. Keyboard focus moves on a **press**:
  `cf:inject-pointer-button :pressed` focuses the window under the pointer before the button
  event goes out, so the click lands on an already-activated window. A hover never steals the
  keys and a press on the bare output changes nothing (D32.1–2).
- **Coordinates**: the cursor node's position is output space; `seat-pointer-x/y` is
  surface-local. `cf:compositor-cursor-x/y` read the node, so there is no second copy to drift.
- **Injection** moves the pointer and marks the output dirty, because the frame changed even if
  no client did. That is why `cf:inject-pointer-motion` produces a new frame with no commit
  behind it.
- **Serials** are validated: `(valid-serial-p seat serial)` is true only for a serial this
  display issued recently (the last 64), so a client cannot move another client's window by
  inventing a number or replaying one from a previous interaction (D33). `move`/`resize` are
  checked for the serial *and* for the focus, and refused silently when they fail: xdg-shell
  defines no error for this, and silence is the honest answer.
- **Grabs** are objects, not modal flags (`cf.grab`): `grab-motion`, `grab-button`, `grab-key`,
  and `grab-end`, which is idempotent — a release racing a cancel ends the grab once. Three
  exist: `move-grab` (the node follows the pointer's delta from a remembered origin),
  `resize-grab` (the size an edge implies is computed by the pure `resize-target-size` and
  *configured*, because a compositor cannot resize a buffer it does not own) and `popup-grab`
  (owner-events: it decides who *ends* the interaction — a press outside the menu, or Escape —
  not who hears it). A grab holds the button that was physically down when it started, and the
  compositor learns about frames and configures through two hooks, `grab-changed` and
  `grab-resize`. DnD arrives with its protocol.
- **Focus is history, not draw order** (D45). `cf:compositor-focus-stack` is the list of windows
  in most-recently-focused order; the scene's children stay *draw* order, which is a different
  claim (D31). Every focus goes through `cf:focus-surface`, which is where the stack is updated,
  so keyboard `enter`/`leave`, the toplevel's `activated` configure and the history cannot drift
  apart. Windows only: a popup takes the keyboard while it is up but pushes the window it belongs
  to, and a roleless surface is nobody's window. When the focused window is destroyed or
  unmapped it leaves both the scene and the stack, and the keys go to the most recently focused
  window that is left — "the window that mapped last" cannot answer that.
- **Alt+Tab rotates the stack** (D45): `cf:focus-stack-cycle` takes the least recently focused
  window, focuses it, rotates it to the front and raises it, so a full cycle visits every window
  once and two windows toggle. Focus and raise stay separate calls: the framework's
  click-to-focus does not raise, because a framework cannot know whether its compositor wants
  click-to-raise.
- **The switcher is that cycle, drawn** (D51, `cf.switcher`). `cf:start-switcher` opens an
  overlay listing the focus stack from its *tail* -- so row 0 is what one tap of the cycle would
  choose -- and `cf:advance-switcher` walks it, wrapping; releasing Alt calls the same
  focus-and-raise the cycle calls, and `cf:cancel-switcher` takes the overlay down without
  touching anything. A row is a picture of the window and its title (D52): the picture is taken
  once, when the overlay opens, at the size the row will show it, which is why a client that
  repaints while a person is choosing cannot make the panel repaint. Nothing is decided while it
  is open: not the stack, not the keyboard, not the stacking order. A window that closed while it
  was up is not chosen. The modal part is two
  generic functions with no-op defaults -- `switcher-key`, asked before grabs and bindings, and
  `switcher-pointer-press` -- so a compositor with no switcher pays one dispatch per key. The
  *rules* are the key list below: Tab walks (Shift walks backwards), a modifier press cancels
  nothing, Escape cancels and is consumed (Alt is down and Alt+Escape quits), any other press
  cancels and is not consumed, and the release that commits is not consumed either -- a client
  that saw Alt go down must see it come up.
- **Keybindings** come before the client (D33): the key path is grab, then table, then focused
  window. `(add-keybinding compositor key function :modifiers mask)` — exact mask match, so
  Alt+Escape does not fire with Alt+Shift held. A consumed press never reaches the client and its
  release is swallowed; an unbound modifier is still forwarded, which is a v0 simplification
  (there is no device to suppress it from). The framework's defaults are Alt+Esc (stop the loop),
  Alt+Tab (cycle the focus stack) and Alt+F1 (the bottom window in draw order to the top, and
  focus it); the default Alt+Tab deliberately keeps the invisible cycle, because an overlay is a
  compositor's statement about its own screen (D51). cl-tinywl binds five: Alt+Esc, Alt+Tab
  (`start-switcher`), Alt+Shift+Tab (`start-switcher :step -1`), Alt+F1 and Alt+Shift+Return.
- **Capabilities** are recomputed from actual devices and re-advertised on change. Today the
  headless backend advertises `pointer|keyboard`; touch is not advertised and `get_touch` is
  refused with `missing_capability`, which is what the protocol asks for.
- **Keymap**: one keymap per seat, serialized into a memfd and sent via `wl_keyboard.keymap`,
  with `repeat_info` after it (D28). `cf.input` generates the text from a table of keys — evdev
  code, keysyms, the modifier each key sets — so nothing links libxkbcommon yet. The table covers
  what a terminal session needs (Escape, F1–F4, the main block with its shifted keysyms,
  modifiers, Return/BackSpace/Tab, the arrows and the editing keys), and a key that is *not* in
  the table cannot be typed or bound at all: TLDE — the key between Escape and 1 — was missing
  until it was found while looking for a binding, which is why `tests/unit/input.lisp` now
  asserts every row's keycode, that the names are unique, and that the generated text declares
  each key. A key is looked up by its base keysym (`"Escape"`, `"grave"`), its shifted keysym
  (`"asciitilde"`) or its XKB name (`"ESC"`, `"TLDE"`). Phase 4 replaces the *generator* with
  libxkbcommon's keymaps from libinput devices; the protocol path and the modifier bookkeeping do
  not change.
- **Input without a device**: `send-key-event` and `send-pointer-motion`/`-button`/`-axis` are
  the seam a backend calls; the headless backend wraps them as `cf:inject-*` so a test can type
  at a real client, and a libinput backend will call the same four functions.
- **Version**: `wl_seat` is offered at 4 (D27), so `wl_pointer.frame` (v5), `wl_seat.release`
  (v5), `axis_source` (v6) and high-resolution scroll (v8) are unavailable, and a client that
  asks for one is told `invalid_method`.
- **Flushing**: the display's `run-once` flushes every client at the end of each cycle, because
  input is produced outside any client's readable event (D27).
- **Cursor**: v0 draws a built-in 16x16 arrow (`cf.scene:make-cursor-image`) as the scene's
  `image-node`, composited **last** and after everything else, at the pointer's position, with
  `PIXMAN_OP_OVER` so its transparent pixels do not erase what is under it. It is a sibling of
  the root, not a child, so it can never be hit-tested: the pointer cannot stand on the pointer.
  Client-provided cursor *surfaces* (`wl_pointer.set_cursor`, accepted and recorded since
  phase 3b), hotspots, theme lookup via `wp_cursor_shape_v1` and a hardware plane are phase 5;
  the node, the position and the composite-last rule do not change.

## 6. Shell state machines

These are the modules where "looks done" and "correct" diverge most, so the contracts are
written down and tested:

**xdg-shell** — *v1 implemented in phase 3, in `cl-wayland-server/src/xdg-shell.lisp`.* The
protocol state machine lives with the protocol, next to `wl_surface` and `wl_shm`, because it is
wire semantics and every compositor built on the server needs it; `cf.types.xdg-shell` is the
part still to come, and it will hold *policy* (map/unmap events, layout, activation) as a
subclass that specialises the same hooks. What is implemented:

- `xdg_surface.configure` is sent only after the initial commit; a toplevel that commits a
  buffer before acking its initial configure is a protocol error (`unconfigured_buffer`).
- `xdg_toplevel.configure` carries the size the client should use (0×0 = "you choose") and a
  *complete* state array; states are recomputed, never patched.
- `ack_configure` consumes the serial it names and every older one; a serial we never sent, or
  one already consumed, is `invalid_serial` (the XML says this is an error, so we do not ignore
  it — see D26).
- Role and object destruction are ordered and enforced: `defunct_role_object` for an
  `xdg_surface` destroyed before its role, `defunct_surfaces` for an `xdg_wm_base` destroyed
  with surfaces alive, `already_constructed` for a second role, `role` for a second
  `xdg_surface` on one `wl_surface`.
- `set_activated`, `set_maximized`, `set_fullscreen`, `set_tiled`, `set_suspended` are driven
  by compositor policy, not by the client's request alone — and today the policy is "record the
  request, send nothing": there is no seat and no layout. `close-toplevel` and
  `set-toplevel-activated` are the hooks a window manager will call.
- Titles, app ids, parents and min/max size hints are stored and validated (`invalid_size`,
  `invalid_parent`, `invalid_resize_edge`), so a rule engine or taskbar has something true to
  read.
- **Popups and positioners** are implemented at version 1, which is what the global
  advertises. `get_popup` copies the positioner's rules (so the client may reuse or destroy the
  positioner at once), refuses an incomplete one (`invalid_positioner`), a parent with no role
  or the popup's own surface (`invalid_popup_parent`), and a second role
  (`already_constructed`). The placement arithmetic is pure (`positioner-place`): anchor point,
  gravity, then the constraint adjustment in the order the spec fixes — flip (kept only if the
  flipped position is inside), slide, resize — against a box the *compositor* supplies
  (`popup-constraint-box`, expressed in the parent's window-geometry space, because that is the
  space `xdg_popup.configure`'s x and y are in). A v1 popup is configured once.
- **Popup stacking and lifetime**: creation order is stacking order (`xdg-toplevel-popups`),
  which is what makes "the client may only destroy the topmost popup"
  (`not_the_topmost_popup`) answerable. A popup that is taken off the screen gets
  `popup_done` and its surface is unmapped by the compositor; `destroy-popup-chain` dismisses a
  stack topmost first, which is the only order a client can answer.
- **Popup grabs** are owner-events grabs (`cf.grab:popup-grab`): the popup's client hears the
  pointer as usual, a press inside any popup of the same toplevel is delivered, and a press
  outside dismisses the stack and is swallowed — including its release, so a client never sees
  the release of a press it was not sent. Escape dismisses (the keyboard half of the dialog in
  `xdg_popup.grab`), and a grab is refused — and therefore the popup dismissed — when its serial
  is not one this display issued.
- **Not yet**: `reposition` and reactive positioning (v3+, so the global stays at v1),
  decoration negotiation, configure bounds and `wm_capabilities` (v4/v5), and popups parented by
  "some other protocol" (a null parent is created but never mapped: no layer-shell exists yet to
  give it one).
- `move`/`resize` requests start grabs only if the serial is valid and the surface has focus.

**layer-shell**: anchors, margins, exclusive zones (reserve space before placing content),
keyboard interactivity (none/on-demand/exclusive), popup parenting, per-output layers.

**data-device**: sources/offers with mime types, `set_selection`/`set_primary_selection`
serial validation, DnD with `enter`/`motion`/`drop`/`leave` and cursor surfaces, and the
awkward part — offers must be created on the target client's connection, not the source's.

**decoration**: negotiate server-side vs client-side per toplevel, and if server-side, draw
borders in a scene node (not in the renderer).

**session-lock**: while locked, only the lock surface receives input; outputs are covered;
a crashed locker must not leave the session unlocked or wedged (ext-session-lock has specific
rules for this).

## 7. Declaring globals

A compositor declares what it speaks, once, and the framework derives binds, version
ranges, initial events and the protocol set to compile:

```lisp
(cf:define-compositor umbra (cf:compositor)
  (:globals
   (wl-compositor   :version 6)
   (wl-subcompositor)
   (wl-shm          :formats '(:argb8888 :xrgb8888 :abgr8888 :xbgr8888))
   (wl-seat         :version 9)
   (wl-output       :version 4)
   (xdg-wm-base     :version 6)
   (wlr-layer-shell :version 4)
   (xdg-decoration  :version 1)
   …))
```

Rule from the plan: a global is declared only when complete. The declaration list is also the
input to a test that asserts every declared global's requests are implemented and every
advertised version is exercised.

## 8. Utilities

| Utility | What it is |
|---|---|
| `box`, `edges` | integer rectangles and edge bitfields; no float geometry in layout |
| `region` | pixman regions, wrapped; union/intersect/subtract/translate |
| `matrix` | 3×3 affine for pixman and GL projections |
| `output-layout` | arrangement, nearest-output queries, scale-aware geometry |
| `xcursor` | theme loading (`libxcursor` via CFFI), image at scale, hotspot |
| `time` | monotonic clock in µs, vblank timestamps, deadline arithmetic |
| `log` | structured, levelled, per-object prefixes; `WAYLAND_DEBUG`-compatible mode |

## 9. What a compositor author writes

This is the sketch this document was written around, and `cl-tinywl` now exists in that shape
(D36). The real thing is `cl-tinywl/src/tinywl.lisp`; what it comes down to is a class and two
methods — the framework owns everything else:

```lisp
(defclass tinywl-compositor (cf:headless-compositor) ())

;; Placement: tinywl.c puts every window at the origin, so the stack is the layout.
(defmethod cf:on-new-toplevel ((tinywl tinywl-compositor) surface)
  (let ((node (call-next-method)))          ; the framework made the node
    (scene:set-node-position node 0 0)      ; the compositor decides where it goes
    node))

;; A press: Alt+left moves, Alt+right resizes, anything else focuses and is a click.
(defmethod cf:on-pointer-button ((tinywl tinywl-compositor) button state)
  (if (and (eq state :pressed) (member button '(:left :right)) (alt-held-p tinywl))
      (multiple-value-bind (surface) (desktop-toplevel-at tinywl (cursor-x tinywl) (cursor-y tinywl))
        (when surface
          (focus-toplevel tinywl surface)
          (begin-interactive tinywl surface (if (eq button :left) :move :resize))))
      (call-next-method)))                  ; the framework's rule, unchanged
```

Keys are a table, not a method:

```lisp
(cf:add-keybinding tinywl "Escape" (lambda () (quit tinywl))
                   :modifiers cf.input:+modifier-mod1+ :description "quit")

;; The visible switcher is one binding and no code: the overlay, the keys held down
;; and the decision on release are the framework's (D51).
(cf:add-keybinding tinywl "Tab" (lambda () (cf:start-switcher tinywl))
                   :modifiers cf.input:+modifier-mod1+ :description "switcher")
```

A compositor that wants a switcher of its own shape calls `cf:advance-switcher` from its own
policy instead of binding `start-switcher`: the state machine does not care who moves the
selection, and the overlay is drawn from the state, not from the keys.

And a session — a display of its own, in memory or as a window in another compositor:

```lisp
(tinywl:main '("--nested" "--size" "1024x768"))
```

`cl-umbra` adds layouts, workspaces, rules, config and control on top of the same surface
area; it does not reimplement protocol plumbing.

## 10. Extensibility model

| Need | Mechanism |
|---|---|
| React to an event | specialize a generic function (`defmethod cf:on-…`) |
| React to *every* event of a kind | `:before`/`:after` methods |
| Veto or modify an action | `:around` method + `call-next-method` |
| New surface role | subclass `cf-surface`, register the role with the shell module |
| New protocol | generate it, implement its requests on a resource subclass, declare the global |
| Per-object override | change the resource class on a global, or `change-class` a surface |
| Live behaviour change | redefine methods in the running image (safe between dispatches) |
| External control | eval channel / REPL → the same functions keybindings call |

The last two matter: because a script, a keybinding and the REPL make the same function
call, anything the compositor can do interactively is scriptable, and vice versa.

## 11. Contracts worth stating twice

1. A surface has at most one role, forever. `change-class` at role assignment, error on
   reassignment.
2. A buffer is released exactly once, after the frame that used it is presented.
3. `configure` serials are acked in order; unacked configures do not accumulate.
4. Focus changes are serial-bearing, and serials are validated before acting on client
   requests.
5. Output commits are atomic; failure leaves the previous state.
6. An output resize/mode change invalidates buffer age and forces one full repaint.
7. Client disconnect removes the client from every seat, scene node, grab and selection, in
   that order, before its resources are freed.
8. No module calls `wl_display.flush` directly; flushing is the reactor's job.

## 12. What is deliberately *not* copied from wlroots

- Opaque structs and `void *` user data → subclasses and slots.
- `wl_list` intrusive lists → Lisp sequences, with ordering explicit.
- `wl_signal`/`wl_listener` → generic functions.
- Function-pointer vtables → methods.
- Type-tagged scene nodes (`enum wlr_scene_node_type`) → classes.
- Stringly-typed configuration and `wlr_output_layout`'s global singleton → explicit
  compositor-owned objects, so two compositors (or a test and a session) can coexist in one
  image.
- `wlr_xwayland`'s XWM → an external, well-scoped process that needs two protocols we
  implement anyway (D12).
