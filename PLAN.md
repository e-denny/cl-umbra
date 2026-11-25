# PLAN — a Wayland compositor stack in Common Lisp

Status: **planning, no code written**. This document is the master plan; the design
documents in `docs/` go deeper on each layer, and `DECISIONS.md` records the choices that
constrain them.

---

## 1. Goal

Build, from the socket up and entirely in Common Lisp:

1. a Wayland **protocol implementation** (wire, objects, event loop) that is not a
   libwayland binding;
2. a **server** library that is not a libwayland-server binding;
3. a **compositor framework** that does wlroots' job — backends, renderer, scene graph,
   seat, output and shell protocol state machines — without wlroots;
4. **`cl-tinywl`**, a working port of tinywl, to prove the framework;
5. **`cl-umbra`**, a compositor usable as a daily driver, functionally in Umbriel's
   territory.

The stretch goal is a compositor whose behaviour can be changed by editing a running
Lisp image: layouts, focus policy, keybindings, effects, all live.

## 2. Stages and definitions of done

| Stage | Done when… |
|---|---|
| Protocol layer | Our client lists the globals of a real compositor; our server serves a real client; wire codec passes byte-exact tests and a fuzz harness. |
| Framework | Headless and nested backends render a scene with pixman and drive input from libinput and from a nested parent; DRM/KMS drives a real TTY with dumb buffers and page flips. |
| `cl-tinywl` | Behaviourally 1:1 with `tinywl.c`: click to focus, drag to move, Alt+drag to resize, Alt+F1 cycle, Alt+Esc quit, running nested under an existing session and on a TTY. |
| `cl-umbra` v1 | You can use it as your desktop for a week: kitty/foot, a browser, clipboard, screenshots, session lock, two outputs, hotplug, suspend/resume, no crashes. |

The through-line: **always have something runnable.** Every phase ends with a demo, not
with a refactor.

## 3. Architecture

### 3.1 Layers

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │ cl-umbra            layouts, workspaces, rules, config, control      │
  │ cl-tinywl           the 900-line reference compositor                │
  ├──────────────────────────────────────────────────────────────────────┤
  │ cl-compositor-framework                                              │
  │   backend/   drm · libinput · headless · nested · multi · session     │
  │   render/    pixman (reference) · gles2 (later) · swapchain · damage  │
  │   scene/     node tree · output layers · hit testing · damage         │
  │   types/     surface · output · seat · cursor · xdg-shell · layer-    │
  │              shell · data-device · decoration · screencopy · …        │
  │   util/      box · region · matrix · output-layout · xcursor · log    │
  ├──────────────────────────────────────────────────────────────────────┤
  │ cl-wayland-server         display · global · resource · client ·      │
  │                           serial · error · socket · teardown          │
  │ cl-wayland-client         display · proxy · registry · roundtrip      │
  ├──────────────────────────────────────────────────────────────────────┤
  │ cl-wayland-core           wire codec · fd passing · XML schema ·      │
  │                           codegen · object tables · reactor           │
  ├──────────────────────────────────────────────────────────────────────┤
  │ CFFI → kernel/driver APIs only                                        │
  │   libdrm · libinput · libxkbcommon · libpixman · libseat · libudev     │
  │   EGL/GLES · GBM · (Rust shim: only where documented, never Wayland)   │
  └──────────────────────────────────────────────────────────────────────┘
```

Note the horizontal line above CFFI. Everything above it is Lisp and owns the Wayland
protocol. Below it are hardware and session APIs that a compositor cannot avoid; none of
them speak Wayland.

### 3.2 Data flow, one frame

```
 input device ─► libinput fd ─► libinput event ─► xkb state ─► seat ─┬─► wl_keyboard.key  ─► client
                                                                     └─► keybinding table
 client ─► socket ─► reactor ─► wire decode ─► wl_surface.attach/commit
                                            └─► shm pool: mmap window of pixels
                                                       │
                                        scene graph + damage region
                                                       │
                                          renderer (pixman) into scanout buffer
                                                       │
                     headless: write PNG     nested: wl_surface.attach on parent
                     drm: DRM_IOCTL_MODE_PAGE_FLIP + vblank
                                                       │
                                            wl_surface.frame callbacks ─► clients
```

### 3.3 Systems

| System | Depends on | Contents |
|---|---|---|
| `cl-wayland-core` | cffi, alexandria, closer-mop, plump | `wayland.wire` (buffers, cmsg, codec), `wayland.protocol` (schema, codegen, interface registry), `wayland.object` (object tables, ids, destruction), `wayland.reactor` (epoll, timerfd, eventfd, signalfd), `wayland.log` |
| `cl-wayland-client` | core | `wayland.client`: display, proxies, registry binding, roundtrip, event dispatch (wayflan-compatible usage) |
| `cl-wayland-server` | core | `wayland.server`: display, socket + lock file, accept, `global`, `resource`, `client` (SO_PEERCRED), versioning, serials, `wl_display`/`wl_registry`/`wl_callback`, error + teardown |
| `cl-compositor-framework` | server (and client for the nested backend) | `cf.*` modules listed in §3.1; owns every policy-bearing `wl_*` global |
| `cl-tinywl` | framework | one file of compositor policy, deliberately close to `tinywl.c`'s shape |
| `cl-umbra` | framework | layouts, workspaces, rules, config, live control, session |

**Layering rule:** `cl-wayland-server` implements only globals that carry no policy
(`wl_display`, `wl_registry`, `wl_callback`). Everything a user could disagree about —
`wl_compositor`, `wl_shm`, `wl_seat`, `wl_output`, `xdg-shell` — is in the framework.
This mirrors the libwayland/wlroots split and keeps the transport reusable (an
application that is a *server* but not a compositor, e.g. a protocol bridge, needs none
of the framework).

## 4. Decisions that shape everything

Full rationale in `DECISIONS.md`; the ones that constrain phases 0-6:

- **D1** From-scratch protocol. No libwayland linkage, ever.
- **D2** Framework is Lisp reimplementation of wlroots' *role*, not CFFI over wlroots.
- **D3** shm-first: `wl_shm` + mmap + **pixman** as the reference renderer; DRM dumb
  buffers before EGL; GPU is an optimization.
- **D4** CFFI first, Rust shim only as a documented leaf.
- **D6** Protocols generated from XML by an ASDF component; static fast paths + runtime
  fallback marshaller.
- **D7** CLOS subclassing instead of vtables; generic functions instead of
  `wl_signal`/`wl_listener`.
- **D9** One thread owns the display; other threads post commands through `eventfd`.
- **D10** `cl-umbra` v1 is daily-driver scope, no eye candy.
- **D14** The REPL is the control surface: exported functions, SLYNK for humans, a local eval
  channel for scripts. No command registry, no IPC protocol, no event bus.

## 5. Phases

Effort is in **focused weeks** (≈30 productive hours each), excluding the ramp-up of
learning DRM/libinput/EGL. Hobby pace divides by 2-3. Every phase has an exit gate; do not
start the next phase to escape a gate.

### Phase 0 — Protocol core, and a client that proves it (4-6 weeks)

**Build**

- `wayland.wire`: circular in/out buffers; message header `(object-id, size<<16|opcode)`;
  encoders/decoders for int, uint, fixed (24.8), string, object, new_id, array, fd; 4-byte
  alignment; `SCM_RIGHTS` fd passing with `sendmsg`/`recvmsg`, the 28-fd flush ceiling, and
  `MSG_CTRUNC` handling; native-endianness assumption asserted, not assumed silently.
- `wayland.reactor`: epoll wrapper, fd sources, timerfd timers, eventfd wakeups, signalfd,
  idle callbacks, the dispatch order `read → dispatch → flush → idle → poll`.
- `wayland.protocol`: XML → CLOS metadata (protocol, interface, request, event, arg, enum,
  entry); `define-interface`/`define-request`/`define-event`/`define-enum` compile that
  metadata into classes, opcode constants, signature tables, docs.
- ASDF component type: `(:wayland-protocol "protocols/wayland.xml" :export t)`.
- `cl-wayland-client`: enough to connect, get the registry, bind nothing, and print globals
  (wayflan's hello-world, our way): display, proxies, client-side ids, `sync` roundtrip,
  hook and generic-function event dispatch, `demo-globals`.

**Exit gate**

- All of `wayland.xml`, `wayland-protocols/*` and `wlr-protocols/*` parse and compile.
- Byte-exact roundtrip tests on recorded message vectors, including fd-carrying messages.
- A fuzz harness feeds random buffers to the decoder for 10⁶ iterations: no crash, no
  unbounded allocation, no fd leak.
- The `cl-wayland-client/demo` system (`wayland.client.demo:run`, or the built
  `demo-globals` binary) prints the global list of the session you are already running in,
  and the output matches `wayland-info`.

Every clause above is checked by `scripts/gate.sh`, which exits 0 when they all pass, 1 when
one fails, and 2 when a clause has nothing behind it yet. The phase-0 gate is met when that
script exits 0.

**Demo:** a REPL session dumping the live session's globals from Lisp.

### Phase 1 — Server core (4-6 weeks)

**Build**

- Socket: `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` (default `wayland-0`), lock file,
  `accept4`, `SO_PEERCRED`, configurable socket name for nesting.
- `wl_display`: object id 1, client id namespace (client-allocated `1..0xFEFFFFFF`,
  server-allocated `0xFF000000..`), `delete_id` recycling, serial counter.
- `wl_global` + `bind`: version negotiation, interface-name validation, per-client
  `resource` creation, global add/remove events with correct ordering against
  `wl_display.sync`.
- `wl_resource`: destruction, `wl_resource.destroy` bookkeeping, idempotent teardown,
  per-client resource map, cleanup on disconnect (pools unmapped, fds closed, children
  killed).
- `wl_display.sync` → `wl_callback.done`; `wl_display.get_registry`.
- Error policy: malformed message or bad request → `wl_display.error(object, code, msg)`,
  flush, disconnect. Never a debugger entry.
- Flush discipline and partial-write handling; output-buffer backpressure per client.

**Exit gate**

- `wayland-info` connects to a server that exposes two dummy globals and exits 0.
- A C test client binds, destroys, and re-binds across versions; no leaked ids.
- Killing clients mid-request, mid-write, and mid-fd-transfer leaves the server healthy.
- 10k connect/disconnect cycles: flat RSS, flat fd count.

**Demo:** `wayland-info` against `(wayland.server:make-demo-display)`.

**Status (phase 1 slice):** built as specified, in `cl-wayland-server`, with two honest gaps.
The gate's `wayland-info` and soak clauses pass (`scripts/gate.sh` clauses 6 and 7), the
socket/lock/`SO_PEERCRED`/ids/globals/`bind`/`sync`/error/teardown behaviour is covered by
`wayland.test.server`, and three decisions were recorded on the way (D19 one object table for
both ends, D20 `flock` for the socket lock, D21 termination signals as posted commands rather
than `signalfd`).  Not done: an independent C client that destroys and re-binds (only
`wayland-info` is a C peer), and a fuzz *client* against the server — so the gate's third
clause is deferred rather than claimed.  Fixed 64 KiB rings remain the phase-0 leftover;
backpressure is enforced by a watermark instead.

### Phase 2 — Core globals, shm, headless output, pixman (6-8 weeks)

**Build**

- `wl_compositor` + `wl_surface` + `wl_region`: the double-buffered surface state machine
  (pending/current: attach, damage, frame callbacks, opaque and input regions, transform,
  scale, buffer scale, `wl_surface.commit`). This is the hardest state machine in the core
  protocol; do it once, thoroughly, with trace tests.
- `wl_shm` + `wl_shm_pool` + `wl_buffer`: `memfd`/pool fd → `mmap`, format table
  (`ARGB8888`, `XRGB8888` mandatory; more later), overflow-safe size/stride validation,
  buffer release, truncation/SIGBUS safety.
- `cl-wayland-client` completed: proxies, registry, fd receive, event dispatch. Needed by
  the nested backend later and by the test suite now.
- `cf.backend.headless`: fake output at a configured size, frame timer.
- `cf.render.pixman`: target from shm or dumb buffer, `pixman_image_composite32`, damage
  regions, buffer-age partial repaint.
- `cf.scene` v0: a retained tree of `buffer` and `rect` nodes per output; attach surfaces.
- `wl_output` v4 (geometry, mode, scale, name, description).
- Frame callbacks: `wl_surface.frame` → `done` with the presentation timestamp.

**Exit gate**

- `weston-simple-shm` renders into the headless backend; the captured PNG matches the
  reference within a small pixel tolerance.
- Surface-state trace tests: commit-without-buffer, attach-null, damage-only commit,
  scale changes, early buffer reuse (must not be released before the frame that uses it).
- A malicious client cannot make us allocate more than the pool it actually sent, cannot
  make us read out of bounds, and cannot SIGBUS us with a truncated pool file.

**Demo:** a client's pixels in a PNG, produced by our compositor, with no C library
speaking Wayland.

### Phase 3 — `cl-tinywl`, nested (3-4 weeks)

**Build**

- `xdg-shell` core: `xdg_wm_base` (ping/pong), `xdg_surface` (configure/ack_configure
  ordering, initial configure), `xdg_toplevel` (configure with size and state array,
  `set_title`, `set_app_id`, `move`/`resize` requests, `set_activated`,
  `set_maximized`/`set_fullscreen` minimal), `xdg_popup` + `xdg_positioner` (basic).
- `wl_seat` + `wl_pointer` + `wl_keyboard`: capabilities, focus enter/leave, button,
  axis, frame, key, modifiers, repeat_info, keymap fd (xkb keymap string in a memfd).
- `cf.backend.nested`: our compositor as a Wayland *client* of the parent, using
  `cl-wayland-client` — its own shm buffers as outputs, its `wl_seat` as input source.
- `cf.seat`, `cf.cursor` (software cursor), `cf.util.output-layout`, `cf.util.xcursor`.
- `cl-tinywl`: `focus-view`, `desktop-view-at`, `process-cursor-*`, `begin-interactive`,
  `output-frame`, keybindings — a 1:1 map of `tinywl.c`'s functions.

**Exit gate** (the tinywl parity script, run twice: nested and headless+fake input)

1. kitty starts and is visible.
2. Click focuses; typing goes to the focused window only.
3. Drag moves; `Alt`+right-drag resizes from the requested edge.
4. `Alt+F1` cycles views, moving the old one to the back.
5. `Alt+Esc` exits cleanly, closing clients without them seeing a protocol error.
6. `WAYLAND_DEBUG=1` on the client shows a valid, ordered event stream.

**Demo:** `cl-tinywl` running as a window inside the current desktop, with kitty inside
it, moved and resized by mouse.

### Phase 4 — Real hardware: DRM dumb buffers + libinput (6-8 weeks)

**Build**

- `cf.backend.drm` (dumb-buffer path, no EGL): `GETRESOURCES`, connector/encoder/CRTC
  enumeration, mode selection, `CREATE_DUMB`/`MAP_DUMB`/`ADDFB`/`SETCRTC`, double/triple
  buffering, `PAGE_FLIP` with `DRM_MODE_PAGE_FLIP_EVENT`, `read()` on the DRM fd for vblank,
  teardown on VT switch.
- Session: `libseat` CFFI (`open_seat`, `open_device`, `switch_session`) with seatd or
  logind; fallback: direct VT handoff (`VT_GETSTATE`/`VT_ACTIVATE`, `KDGKBMODE`).
- `cf.backend.libinput`: udev context, device hotplug, keyboard/pointer/touch/tablet/pad/
  switch events, tap-to-click and natural scrolling defaults, per-device config hooks.
- `libxkbcommon` CFFI: keymap compile, state, `key_get_syms`, mods serialization, keymap
  fd for `wl_keyboard.keymap`, repeat handling.
- Multi-output: `cf.util.output-layout` positioning, hotplug add/remove, `wl_output`
  lifecycle per output.
- Software cursor rendered into the scanout buffer.

**Exit gate**

1. Switch to a free VT, run `cl-tinywl`, get a working desktop on the real display.
2. VT switch away and back: display restored, no leaked fds, clients intact.
3. Unplug and replug an HDMI output: it appears, gets a mode, can host windows, and is
   removed cleanly.
4. 8-hour soak with a client animating at 60 fps: flat RSS, no page-flip stalls, no
   underruns logged.
5. Suspend/resume returns to a working display.

**Demo:** a real TTY session, no X, no Wayland, no EGL — dumb buffers and pixman.

### Phase 5 — GPU acceleration, only where it earns its place (5-8 weeks)

**Build**

- `cf.render.gles2`: EGL context on GBM (`EGL_PLATFORM_GBM_KHR`) or surfaceless; texture
  upload from shm; FBO render targets; damage-scissored redraw; shader stubs for later
  effects.
- `cf.backend.drm` gains the atomic path: property enumeration, `ATOMIC` commits with
  `ALLOW_MODESET`/`NONBLOCK`, plane assignment (primary, cursor, overlay), test commits
  for mode changes, rollback on failure.
- `zwp_linux_dmabuf_v1`: params, plane fds and modifiers, `EGL_EXT_image_dma_buf_import`
  (+`_modifiers`), format/modifier feedback, fallback to shm when import fails.
- Hardware cursor plane with software fallback; direct scanout for fullscreen buffers
  when the format/modifier allows.
- `wl_shm` gains the remaining formats and `wl_shm.release`.

**Exit gate**

- Same session as phase 4 but with the GL renderer, measured: frame time, CPU time,
  GPU time, and no visual difference in golden-image tests (within tolerance).
- A dmabuf client (a GL app) renders correctly, and falls back cleanly when we reject its
  modifiers.
- Direct scanout engages for a fullscreen 1080p client and disengages on popup.

**Demo:** the same desktop, now with the CPU near idle at 4K.

### Phase 6 — `cl-umbra` v1: daily driver (12-17 weeks)

Reduced from 14-20 by D14: the IPC message layer, its schemas and its conformance tests are
gone; the control surface is exported functions plus a small eval channel.

**Build**

- **Layouts:** master/stack, scrolling (niri-style column model), and a manual/floating
  mode; per-workspace layout; mouse-driven move/resize; focus and swap bindings.
- **Workspaces:** independent per output, named, with hotplug restore.
- **Rules:** app-id/title matching → workspace, layout, floating, size, output; layer-shell
  rules for bars/notifications.
- **Config:** `~/.config/umbra/init.lisp` (D11), schema-validated sections, atomic reload
  with rollback, line-numbered diagnostics, `--check-config`, keybind table, per-device
  input settings, output settings. Design in [`docs/config-and-control.md`](docs/config-and-control.md).
- **Control surface:** package `umbra` of command and query functions, SLYNK for the human
  REPL, and a local eval channel (0600 socket, forms in and printed values out, deadline, no
  debugger) for scripts, bars and tests. No command registry, no JSON protocol, no event bus
  (D14).
- **Protocols needed by a real desktop:** `wlr-layer-shell`, `xdg-decoration`,
  `xdg-output`, `fractional-scale-v1`, `viewporter`, `cursor-shape-v1`,
  `keyboard-shortcuts-inhibit`, `idle-inhibit`, `primary-selection`, `data-control`,
  `wlr-screencopy`, `xdg-activation`, `ext-session-lock`, `wlr-foreign-toplevel`,
  `presentation-time`, `wlr-output-management` (basic). `wp-viewporter` is also what
  `xwayland-satellite` needs, so X support becomes almost free once it lands (D12).
- **Data device:** clipboard, primary selection, drag and drop with serial validation.
- **Session:** lock screen path, idle handling, child process supervision, logind
  integration (sleep/lid), output hotplug with re-layout.

**Exit gate — the daily-driver checklist** (a week of real use)

1. kitty/foot, Firefox or Chromium, a GTK4 app, a Qt app: all work, all day.
2. Clipboard both ways, primary selection, drag and drop between apps.
3. Two outputs at different scales; windows move between them; fractional scaling is
   correct (no blurry text where the client supports it).
4. Screenshots and screen sharing via `xdg-desktop-portal` + screencopy.
5. Session lock works and survives a lid close.
6. Hotplug, suspend/resume, VT switch: no crash, no lost clients.
7. Restart the compositor config 20 times live: no crash, bindings actually change, a
   broken config leaves the previous one running.
8. A scripted control check: forms over the eval channel (`(umbra:workspaces)`,
   `(umbra:dispatch :focus :direction :down)`) agree with what is on screen and behave
   exactly like the same keybinding; a runaway form is aborted by the deadline.
9. A full working week without a compositor crash.

**Demo:** the author's own desktop, for a week, with `cl-umbra` in the process list.

### Phase 7 — Parity and polish (open-ended)

Effects and animation (scene-graph render passes, blur via GLES, shadows, rounded corners,
GLSL effect presets), HDR and colour management, VRR/adaptive sync, tearing control,
explicit sync (`linux-drm-syncobj-v1`), tablet/touch/gestures, input methods
(`text-input`/`input-method`), Xwayland polish (on-demand `-listenfd` activation, crash
supervision, X settings), multi-GPU and output leasing, sandboxed client sockets, and the
“overview”/exposé class of features.

## 6. Protocol coverage matrix

Versions are the ones shipped by `wayland.xml` and `wayland-protocols` on this machine
(`wl_compositor` v7, `wl_seat` v11, `wl_surface` v7, `xdg-shell` v7).

| Protocol | Phase | Notes |
|---|---|---|
| `wl_display`, `wl_registry`, `wl_callback` | 1 | server core |
| `wl_compositor`, `wl_surface`, `wl_region` | 2 | state machine is the risk |
| `wl_shm`, `wl_shm_pool`, `wl_buffer` | 2 | primary buffer path |
| `wl_output` | 2 | v4 |
| `wl_subcompositor`, `wl_subsurface` | 3 | needed by toolkits |
| `wl_seat`, `wl_pointer`, `wl_keyboard` | 3 | v11, incl. frame events |
| `wl_touch` | 4 | with touch input |
| `xdg-shell` | 3 | v7; popups/grab polish in 6 |
| `wl_data_device_manager` | 6 | clipboard/DnD |
| `wl_fixes` | 6 | optional |
| `xdg-decoration` | 6 | server-side decorations for sane clients |
| `wlr-layer-shell` | 6 | bars, panels, notifications |
| `xdg-output`, `fractional-scale`, `viewporter` | 6 | scaling correctness; `viewporter` also required by `xwayland-satellite` |
| `cursor-shape-v1` | 6 | modern cursor API |
| `idle-inhibit`, `keyboard-shortcuts-inhibit` | 6 | |
| `primary-selection`, `data-control` | 6 | |
| `presentation-time` | 6 | also useful for frame timing |
| `wlr-screencopy` | 6 | screenshots, portals |
| `xdg-activation`, `wlr-foreign-toplevel` | 6 | launchers, taskbars |
| `ext-session-lock` | 6 | lock screens |
| `wlr-output-management` | 6 | display config tools |
| `linux-dmabuf` | 5 | with GL renderer |
| `linux-drm-syncobj-v1` | 7 | explicit sync |
| `pointer-constraints`, `relative-pointer` | 7 | games |
| `tablet`, `pointer-gestures` | 7 | |
| `text-input`, `input-method` | 7 | IME |
| `tearing-control`, `wp-color-management` | 7 | |
| `wlr-virtual-pointer`, `virtual-keyboard` | 7 | testing/automation |
| `input-capture`, `drm-lease` | 7 | screen share, VR |
| `xwayland-shell` | 7 | only if D12 is revisited |

Rule: **advertise a global only when its implementation is complete.** A globals list is a
promise; half-implemented protocols are the main source of “works in sway, crashes here”.

## 7. `cl-tinywl` parity checklist (`tinywl.c` → Lisp)

| `tinywl.c` | `cl-tinywl` |
|---|---|
| `struct tinywl_server` | `tinywl` class, framework slots instead of listeners |
| `wl_display_create` | `wayland.server:make-display` |
| `wlr_backend_autocreate` | `cf:make-backend` (nested/headless/drm by env) |
| `wlr_renderer_init_wl_display` | `cf.render:init-wl-display` → `wl_shm` formats |
| `wlr_compositor_create` | `cf.types.compositor` global from the registry table |
| `wlr_data_device_manager_create` | phase 6 (clipboard), stubbed in `cl-tinywl` |
| `wlr_output_layout_create` | `cf.util.output-layout` |
| `server_new_output` / `output_frame` | `on-new-output`, `on-output-frame` methods |
| `render_surface` | `cf.scene:for-each-surface` + `cf.render:render-buffer` |
| `server_new_xdg_surface` | `on-new-toplevel` |
| `xdg_surface_map/unmap/destroy` | `on-map`, `on-unmap`, `on-destroy` |
| `xdg_toplevel_request_move/resize` | `on-request-move`, `on-request-resize` |
| `focus_view` | `focus-toplevel` (seat policy) |
| `desktop_view_at`, `view_at` | `cf.scene:surface-at` |
| `begin_interactive`, `process_cursor_*` | `cf.seat:begin-move`/`begin-resize` + grab |
| `server_cursor_*` | `cf.seat` pointer handlers |
| `server_new_keyboard` (xkb keymap) | `cf.input:keyboard-from-device` |
| `handle_keybinding` | `cf.seat:keybinding` table lookup |
| `seat_request_cursor`, `seat_request_set_selection` | `on-request-cursor`, `on-request-selection` |
| `main` | `(tinywl:main)` + `save-lisp-and-die` binary |

## 8. `cl-umbra` v1 scope (from Umbriel's feature list)

| Umbriel feature | v1 | Phase | Note |
|---|---|---|---|
| scrolling / dwindle / master layouts | master + scrolling | 6 | dwindle and stacking in 7 |
| tab groups, scratchpads | no | 7 | scratchpad is cheap, tab groups are not |
| per-output workspaces, hotplug restore | yes | 6 | |
| window rules, layer rules | yes | 6 | |
| title bars, drop zones, overview | no | 7 | |
| blur, shadows, rounded corners, animations | no | 7 | scene graph designed for it (D10) |
| GLSL effect presets | no | 7 | requires GL renderer + shader loading |
| HDR, VRR, tearing, direct scanout, explicit sync | no | 7 | |
| keyboard, touchpad gestures, touch, tablets | keyboard/pointer | 6 | touch 4, gestures/tablets 7 |
| input methods | no | 7 | |
| pointer lock/confinement | no | 7 | |
| Xwayland (on demand) | yes, once `viewporter` lands | 6 tail | `xwayland-satellite` needs only `xdg-shell` + `wp-viewporter` (D12); rest is process supervision |
| layer shell, session lock, screencopy | yes | 6 | |
| screen sharing via portal | yes (screencopy) | 6 | |
| live-reloaded config with diagnostics | yes | 6 | s-expressions (D11), see `docs/config-and-control.md` |
| runtime control and inspection | yes | 6 | exported functions + REPL + eval channel (D14); no message layer |
| fractional scaling, virtual outputs | fractional yes, virtual no | 6 | virtual outputs = headless backend reuse, cheap in 7 |

## 9. Risks

| Risk | Why it bites | Mitigation |
|---|---|---|
| **Scope** — wlroots is ~50k lines of “you were going to write it anyway” | The project can absorb years before anything is usable | Phases with hard gates; walking skeleton from phase 0; phase 3 delivers a real compositor in ~15 focused weeks |
| **Protocol conformance subtleties** (xdg-shell ordering, popup grabs, serials) | Real clients break in ways that look like our crashes | Interop matrix + trace diffing + advertise-nothing-unfinished rule |
| **DRM/KMS diversity** | One machine, one driver (AMD Renoir); works here, black screen elsewhere | Dumb-buffer path first; atomic last; testers with NVIDIA/Intel; fall back to pixman/shm on any import failure |
| **pixman ceiling at 4K/blur** | CPU compositing costs 2-4 ms/frame at 4K with overlap | Damage regions, buffer age, damage-scissored GL upgrade path; effects wait for phase 7 |
| **GC pauses in the hot path** | A 30 ms GC at 60 Hz is a visible hitch | No consing on input/frame/render paths; foreign memory never GC-managed; allocation benchmarks in CI |
| **FFI friction** (EGL extension loading, dmabuf modifiers, ioctl structs) | Slow, opaque debugging | cffi-grovel for ioctls/structs; Rust shim escape hatch with a strict contract (D4) |
| **Debugger in the main loop** | Clients freeze, session appears hung | D9: protocol errors never enter the debugger; watchdog + safe-interrupt protocol |
| **Modern-client expectations** (fractional scale, cursor-shape, activation, data-control) | Apps feel broken even when the core works | Those protocols are in the v1 gate, not “later” |
| **Motivation / bus factor** | Multi-year solo project | Every phase has a demo; publish the demos; keep the framework reusable by others so contributors have a reason to show up |
| **SBCL lock-in** | Library users on CCL/ECL are excluded | Core avoids SBCL-specifics; portability work only after phase 6 |
| **Licensing/originality** | Copyleft raises the stakes on copied code | GPL-3.0-or-later; no code copied; consult, do not transcribe; GPL-3 sources are compatible with attribution, GPL-2.0-only sources are not; wayflan's BSD-3 notice preserved if adapted (D13) |

## 10. Open questions

1. **SDK/extensibility**: should `cl-compositor-framework` be pitched at “other Lisp
   compositor authors” (documented API, stable) or kept as `cl-umbra`'s internal engine?
   The former roughly doubles documentation effort and constrains refactoring.
2. **Layouts as external programs**: with D14, layouts are objects in the image. Is an
   out-of-tree generator protocol (river-style) ever wanted, or is that compatibility we
   decline?
3. **Where does `cl-umbra`'s line sit** between compositor and shell? Panels, notifiers and
   lockers stay separate Wayland clients for crash isolation and reach state over the eval
   channel; the open part is whether a Lisp panel ships in-tree.
4. **Testing hardware**: is a second machine (Intel/NVIDIA) available as a test target?

Decided elsewhere: config language = s-expressions (**D11**), Xwayland =
`xwayland-satellite` (**D12**), license = GPL-3.0-or-later everywhere (**D13**), control
surface = REPL and eval channel with no IPC message layer (**D14**), framework name and
system family (**D5**).

## 11. Next actions (first two weeks)

1. Create the repo skeleton: six system directories, `.asd` files with empty packages,
   `protocols/` with vendored XML, `qlfile`, `scripts/`.
2. Write `wayland.wire` + its test suite first — no sockets, just bytes. Record real
   message traces with `WAYLAND_DEBUG=1` from the running session and use them as fixtures.
3. Write the reactor, and the fd-passing send/recv path; test with `socketpair` +
   `memfd_create`, including the 28-fd boundary.
4. Port the XML schema parser; assert all protocol files parse and that opcodes and
   signatures match `wayland-scanner`'s generated C headers (a cheap oracle).
5. Build the hello-world client and print the live session's globals. This is the first
   end-to-end proof; it should happen inside two weeks.

## 12. Reading list

- Wayland book (wayland-book.com) — protocol, surfaces, shells.
- `wayland.xml` and `wayland-protocols` XML in `protocols/` — the actual spec, including
  the parts prose omits.
- wayflan `src/wire.lisp`, `src/protocol.lisp`, `src/client/scanner.lisp` — the closest
  prior art to phase 0-1; BSD-3.
- `tinywl/tinywl.c` — the reference shape of a compositor; our phase 3 target.
- wlroots `include/wlr/` headers — the module decomposition we are reimplementing
  conceptually (types/, backend/, render/, scene/).
- `libdrm` `drm_mode.h`, `drm.h` — ioctls and structs; `drmModeAtomicCommit` docs.
- pixman API docs — `pixman_image_composite32`, regions, transforms.
- libinput event API docs — event types and getters.
- Umbriel `docs/user/*` and `SCOPE.md` — the feature target and its boundaries.
