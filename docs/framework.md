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
| `cf.backend.drm` | `wlr_backend_drm` (dumb path) | 4 | KMS modes, dumb buffers, page flips |
| `cf.backend.libinput` | `wlr_backend_libinput` | 4 | device enumeration, hotplug, event decoding |
| `cf.backend.multi` | `wlr_backend_multi` | 4 | several backends in one session (DRM + nested for debugging) |
| `cf.session` | `wlr_session` (libseat) | 4 | seat/VT ownership, device open, switch away/back |
| `cf.render` | `wlr_renderer` | 2 | renderer protocol, format tables, `init-wl-display` |
| `cf.render.pixman` | `wlr_renderer_pixman` | 2 | CPU reference renderer |
| `cf.render.gles2` | `wlr_renderer_gles2` | 5 | GPU renderer, EGL/GBM, shaders |
| `cf.render.damage` | `wlr_damage_ring` | 2 | damage regions, buffer age |
| `cf.render.allocator`, `cf.render.swapchain`, `cf.render.dmabuf` | same names | 5 | GPU buffer lifecycle |
| `cf.scene` | `wlr_scene` | 2, 5, 7 | retained node tree, output layers, hit testing, damage |
| `cf.output` | `wlr_output` | 2 | mode/scale/transform state, commit, frame scheduling |
| `cf.util.output-layout` | `wlr_output_layout` | 2 | arrangement in layout coordinates |
| `cf.types.compositor`, `.surface`, `.region` | `wlr_compositor`, `wlr_surface` | 2 | core protocol objects + surface state machine |
| `cf.types.output` | `wlr_output` protocol side | 2 | `wl_output`, `zxdg_output_v1` |
| `cf.types.seat`, `.cursor` | `wlr_seat`, `wlr_cursor` | 3 | focus, capabilities, pointer/keyboard/touch, cursor |
| `cf.types.xdg-shell` | `wlr_xdg_shell` | 3 | policy over the v1 state machine in `cl-wayland-server`; popups in 6 |
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
      (lambda (compositor) ...))   ; -> the target to draw into, or NIL to defer
(setf (cf.backend.headless:compositor-frame-presenter c)
      (lambda (compositor target) ...))  ; after the draw, before frame callbacks
```

The presenter is handed a target that already holds the frame it is presenting: fill, prune,
draw, present, then release the clients' buffers and fire their callbacks. A nested target is
the parent's `wl_shm` mapping and the parent reads it when it likes, so presenting before the
draw commits the background paint and nothing else — a flickering, half-drawn window in the
parent (D38).

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

*Phase 3c implements v0, in `cl-compositor-framework/src/scene.lisp` (D31): nodes, positions,
stacking, hit testing and the cursor. Damage, clipping, culling, layers and per-output layout
are still ahead, and the ticks below say which.*

```
scene
├── root (tree-node)
│   ├── buffer-node   ← a mapped toplevel, placed by the compositor
│   └── rect-node     ← background, border, letterboxing
└── cursor (image-node)   ← drawn after the root, never hit-tested
```

Node types: `tree` (a group; the root is one), `buffer` (a mapped surface, sized by its
buffer), `rect` (solid premultiplied colour) and `image` (pixels we own — today the cursor),
with `offscreen` arriving with phase 7's effects. Every node has a position in its parent's
space, a visibility flag and a parent.

- **Coordinates**: a node's position is in its parent's space; a root child's is therefore
  output-local, which is the space the renderer and hit testing both use. A node's own position
  and its surface's `attach` offset are *different* things and are added at draw time: the
  compositor says where the window is, the client says where its content sits inside it. A
  surface with no shell role keeps the origin of the scene and is drawn at its attach offset —
  the phase-2a behaviour, unchanged.
- **Stacking** is the order nodes were placed in, not the order they committed in: committing
  is not raising (D31.3). `scene:node-raised` is the call a click-to-raise policy makes.
- **Placement** is a policy hook, not a framework rule:
  `(defmethod cf:on-new-toplevel ((c my-compositor) surface) ...)`. The default is a cascade
  at 32-pixel steps from the origin, which is enough to make two windows two windows.
- **Hit testing**: `(cf.scene:scene-hit-test scene x y)` walks front to back and returns
  `(values node local-x local-y)`; a `buffer-node` is hit only where it is mapped, inside its
  buffer, and inside its committed **input region** (an empty region makes it click-through).
  `cf:surface-under-cursor` is the framework's `desktop_view_at`: it turns the node into a
  surface. Popups and their own coordinates arrive with `xdg_popup`.
- **Retained, not immediate**: the tree survives frames, which is what makes rules,
  workspaces, animations and overview possible without a rewrite (D10).
- **Damage propagation**, clip rectangles and **culling** are open (2b): v0 repaints the whole
  target and lets pixman clip to it, and nothing is culled by an opaque node above it.

`cl-tinywl` uses three node types. `cl-umbra` uses all of them plus per-workspace subtrees and
animated transforms (phase 7).

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
  and `grab-end`, which is idempotent — a release racing a cancel ends the grab once. Two exist:
  `move-grab` (the node follows the pointer's delta from a remembered origin) and `resize-grab`
  (the size an edge implies is computed by the pure `resize-target-size` and *configured*, because
  a compositor cannot resize a buffer it does not own). A grab holds the button that was
  physically down when it started, and the compositor learns about frames and configures through
  two hooks, `grab-changed` and `grab-resize`. Popup grabs and DnD arrive with their protocols.
- **Keybindings** come before the client (D33): the key path is grab, then table, then focused
  window. `(add-keybinding compositor key function :modifiers mask)` — exact mask match, so
  Alt+Escape does not fire with Alt+Shift held. A consumed press never reaches the client and its
  release is swallowed; an unbound modifier is still forwarded, which is a v0 simplification
  (there is no device to suppress it from). The defaults are tinywl's: Alt+Esc stops the loop,
  Alt+F1 cycles the bottom window to the top and focuses it.
- **Capabilities** are recomputed from actual devices and re-advertised on change. Today the
  headless backend advertises `pointer|keyboard`; touch is not advertised and `get_touch` is
  refused with `missing_capability`, which is what the protocol asks for.
- **Keymap**: one keymap per seat, serialized into a memfd and sent via `wl_keyboard.keymap`,
  with `repeat_info` after it (D28). `cf.input` generates the text from a table of keys — evdev
  code, keysyms, the modifier each key sets — so nothing links libxkbcommon yet. Phase 4
  replaces the *generator* with libxkbcommon's keymaps from libinput devices; the protocol path
  and the modifier bookkeeping do not change.
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
- **Not yet**: popups and positioners (no method → `implementation`), decorations, grabs
  (`move`/`resize` are accepted and ignored until there is a seat), configure bounds and
  `wm_capabilities` (v4/v5, so the global advertises v1).
- Popups: parent-relative positioning via the positioner, `reposition` (v3+), grab semantics
  (dismiss on outside click, honour `popup_done`), and **nested popup stacks**.
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
```

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
