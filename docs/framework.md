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
| `cf.types.xdg-shell` | `wlr_xdg_shell` | 3 | toplevel/popup state machines |
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
globals, a pixman target, and a surface list in commit order. The split becomes real when
there is a second backend to abstract (nested, phase 3; DRM, phase 4) — a `backend` class with
one implementation is the speculative abstraction the roadmap forbids.

Contracts:

- A backend only ever *reports*; it never calls into the scene, seat or shell. A compositor
  that ignores an event must still behave sanely.
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

```
scene (root)
└── output (node)
    ├── background
    ├── bottom        ← layer-shell background layer
    ├── content       ← toplevels, in stacking order
    ├── top           ← layer-shell top layer
    ├── overlay       ← layer-shell overlay, notifications
    └── cursor
```

Node types: `tree`, `buffer` (a mapped surface), `rect` (solid colour; backgrounds, borders,
letterboxing), plus `offscreen` (phase 7 effects). Every node has a position, an optional
clip, a visibility flag, a damage region, and a parent.

- **Coordinates**: node position is in parent space; output space is the parent of layers;
  layout space is the output arrangement. Helpers convert and test containment; the renderer
  only ever sees output-local pixels.
- **Hit testing**: front-to-back walk with input-region clipping and popup awareness, returning
  `(values surface local-x local-y)` — the same contract tinywl's `desktop_view_at` provides,
  but layer-aware.
- **Damage propagation**: a node's damage unions into its ancestors' damage, which unions
  into the output's damage region. Moving a node damages old and new bounds.
- **Retained, not immediate**: the tree survives frames, which is what makes rules,
  workspaces, animations and overview possible without a rewrite (D10).
- **Culling**: nodes fully covered by an opaque node above them are not composited. Cheap,
  and the main reason the pixman path stays viable.

`cl-tinywl` uses three node types. `cl-umbra` uses all of them plus per-workspace subtrees and
animated transforms (phase 7).

## 5. Seat, focus and grabs

```lisp
(defclass seat ()
  ((capabilities …) (keyboard-focus …) (pointer-focus …)
   (grab nil) (serials …) (keymap …) (repeat …)))
```

- **Focus** is explicit: `(set-keyboard-focus seat surface serial)`,
  `(set-pointer-focus seat surface x y)`. Enter/leave, `set_activated` on the toplevel, and
  keyboard `enter`/`leave` events all follow from one call, so they cannot drift apart.
- **Serials** are validated: `(valid-serial-p seat serial)` for selections, popup grabs,
  move/resize requests. Unvalidated serials are the classic way a malicious client moves
  another client's window.
- **Grabs** are objects, not modal flags: `interactive-move`, `interactive-resize`,
  `popup-grab`, `dnd-grab`. A grab gets motion/button/key/axis callbacks and ends exactly
  once, on button release, Escape, or client destruction.
- **Capabilities** are recomputed from actual devices and re-advertised on change.
- **Keymap**: one compiled xkb keymap per seat (device-specific keymaps come from libinput
  devices; a mismatch recompiles), serialized into a memfd and sent via
  `wl_keyboard.keymap`, with `repeat_info` after it.
- **Cursor**: shape selection (client-provided surface or a theme image), hotspot, hardware
  plane when available, software composite otherwise. `wp_cursor_shape_v1` clients name a
  shape and the framework resolves it from the theme.

## 6. Shell state machines

These are the modules where "looks done" and "correct" diverge most, so the contracts are
written down and tested:

**xdg-shell**
- `xdg_surface.configure` is sent only after the initial commit; a toplevel that commits a
  buffer before acking its initial configure is a protocol error.
- `xdg_toplevel.configure` carries the size the client should use (0×0 = "you choose") and a
  *complete* state array; states are recomputed, never patched.
- `ack_configure` must match the most recent configure serial; stale acks are ignored per spec.
- `set_activated`, `set_maximized`, `set_fullscreen`, `set_tiled`, `set_suspended` are driven
  by compositor policy, not by the client's request alone.
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

The whole of `cl-tinywl` should look like this — policy only:

```lisp
(defclass tinywl (cf:compositor) ())

(defmethod cf:on-new-toplevel ((c tinywl) (toplevel cf:toplevel))
  (let ((node (cf.scene:buffer-node (cf:scene c) toplevel)))
    (cf.scene:set-position node 100 100)
    (push toplevel (views c))
    (cf:focus-toplevel (cf:seat c) toplevel)))

(defmethod cf:on-key ((c tinywl) (kb cf:keyboard) key state mods)
  (when (and (eq state :pressed) (member :alt mods))
    (eswitch ((cf:key-name key) :test #'string=)
      ("Escape" (cf:stop c))
      ("F1"     (cycle-views c)))))

(defmethod cf:on-frame ((c tinywl) (output cf:output))
  (cf:render c output))
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
