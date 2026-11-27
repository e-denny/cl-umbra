# Roadmap — task-level checklists

`PLAN.md` §5 states scope and gates. This file is the working list: ordered tasks, the
demo that closes each phase, and the rules for re-planning when reality intervenes.

Effort is in focused weeks (≈30 productive hours). Treat the numbers as a hypothesis to
revise after each phase, not a promise.

---

## Principles

1. **Walking skeleton.** From phase 0 there is always something runnable: a client that
   lists globals, a server that serves a client, a compositor that shows a window.
2. **Gate before next phase.** A phase is done when its gate passes on a clean checkout,
   not when the interesting part is written.
3. **One demo per phase**, recorded, because motivation is a resource.
4. **Every bug fixed at the layer that owns it.** No protocol workarounds in `cl-umbra`.
5. **No speculative abstraction.** The framework grows because a compositor needed a
   module, not because wlroots has one.

---

## Phase 0 — Protocol core and a hello-world client (4-6 weeks)

**Skeleton** (`scripts/`): `run-tests.sh`, `capture.sh`, `purity-check.sh`; `qlfile`;
empty `.asd` per system; `protocols/` populated with pinned XML.

`wayland.wire`
- [ ] 64 KiB in/out rings with partial-message handling (partial-message handling
      and buffer growth are done in `wayland.io:pump`; the fixed-size rings and the
      out-buffer high-water mark belong with the reactor)
- [x] header encode/decode; size/opcode split; alignment assertions
- [x] encoders/decoders: int, uint, fixed, string, object, new_id, array
      (fd argument bookkeeping included)
- [x] `sendmsg`/`recvmsg` with `SCM_RIGHTS`; fd queue; 28-fd flush ceiling; `MSG_CMSG_CLOEXEC`
- [ ] `MSG_CTRUNC`, missing-fd, surplus-fd handling (all ⇒ error + close)
      (`MSG_CTRUNC` and missing-fd are done and tested; surplus-fd waits for the
      protocol layer that knows how many descriptors a message declares)
- [ ] `WAYLAND_DEBUG`-compatible trace logging
- [x] unit tests: byte-exact vectors, roundtrip property tests, boundary sizes
- [x] fuzz harness: 10^6 cases through the header decoder, real message schemas and a
      `socketpair`; no crash, hang, unbounded allocation or descriptor leak (`scripts/fuzz.sh`)

`wayland.reactor`
- [x] epoll wrapper (`epoll_create1`, `epoll_ctl`, `epoll_wait`) via CFFI; level-triggered
- [x] fd sources with read/write interest toggling; hangup and error reach the callback
- [x] timerfd timers with nearest-deadline timeout computation; repeating timers
- [x] eventfd wakeups + command queue (for threads, REPL and the control channel later)
- [x] signalfd for `SIGCHLD`/`SIGTERM`/`SIGUSR1`; `SIGPIPE` ignored
      (`SB-CHILD`-style reaping is wired up with `xwayland-satellite` in phase 6)
- [x] idle callbacks; dispatch-order tests
- [ ] re-entrancy guard is tested; the 50 ms watchdog log and the per-cycle dispatch
      budget arrive with the connection layer that can attribute a slow cycle

`wayland.protocol`
- [x] XML → CLOS schema (protocol, interface, request, event, arg, enum, entry)
- [x] interface registry, version/since metadata, opcode assignment, libwayland signatures
- [x] parse every vendored XML file (69); compare opcodes, signatures and object types
      against `wayland-scanner private-code` as an oracle
- [x] `define-interface`, `define-request`, `define-event`, `define-enum` macros
- [x] ASDF component `:wayland-protocol` generating those forms from XML at build time
      (`cl-wayland-asdf`), used by `cl-wayland-protocols`
- [x] a change to the schema or the generator re-generates every declared protocol
      (`input-files` includes `schema.lisp`/`codegen.lisp`, D16)

`cl-wayland-client` (minimal)
- [x] connect (`WAYLAND_DISPLAY`, absolute paths, `$XDG_RUNTIME_DIR` default)
- [x] proxy table, ids, `wl_display.get_registry`, `sync`/roundtrip
- [x] `demo-globals` that prints the live session's globals
      (system `cl-wayland-client/demo`; output is byte-identical to `wayland-info`
      on a live session, verified 2026-11-25: 55 globals)

- [x] `scripts/gate.sh`: runs the Rove suite, compiles every vendored protocol,
      diffs `demo-globals` against `wayland-info`, runs the fuzzer for 10^6 cases
      and reports purity; exit 0 pass, 1 fail, 2 clauses unmet. All five clauses
      pass (2026-11-25).

**Gate:** unit + fuzz suites green; all protocols compile; `demo-globals` output equals
`wayland-info`; fuzz 10⁶ iterations with no crash/hang/leak.

**Demo:** globals of the running session, dumped from a Lisp REPL.

---

## Phase 1 — Server core (4-6 weeks)

- [x] socket creation: `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, lock file, perms, `accept4`
      (`flock` on `<socket>.lock`, socket 0700, lock 0600, stale socket removed under the lock;
      D20)
- [x] `SO_PEERCRED` capture and validation; structured client log
      (uid checked at accept; pid/uid/gid kept and logged per client)
- [x] `wl_display` object, id 1; client id allocation; server id range
      (one table per connection in `wayland.object`, lowest free id, both ranges; D19)
- [x] per-client object table; `new_id` validation
      (range, unused, and only in a request that declares one)
- [x] `wl_global` add/remove; `bind` with version negotiation; initial-event ordering vs
      `sync` (globals in registration order; `done` queued when the batch ends)
- [x] resource lifecycle: destroy request, destructor events, `delete_id`, id reuse
- [x] `wl_display.sync` → `wl_callback.done` after batch
- [x] `wl_display.error` + disconnect policy; all error codes
      (0 invalid_object, 1 invalid_method, 2 no_memory, 3 implementation; never a debugger)
- [x] flush batching, backpressure, `EPOLLIN` gating
      (one `sendmsg` per flush over the whole buffer; above a 64 KiB watermark interest drops
      to write-only until it drains.  `writev` proper is not needed for one contiguous buffer)
- [x] `teardown-client`, idempotent, reverse-order destruction
- [x] fd hygiene: everything `CLOEXEC`, nothing leaked on teardown
- [x] tests: dummy globals + `wayland-info`; bind/destroy/rebind across versions; kill-mid-request;
      10k connect/disconnect with flat RSS and fd count
      (`wayland.test.server`, 27 tests; `scripts/soak.sh`)
- [x] an independent C client that binds, destroys and re-binds
      (`tests/c-client/wayland-probe.c`, `scripts/c-probe.sh`: libwayland-client, version
      gating, and `delete_id` proven by the released id coming back)
- [x] a fuzz *client* against the server: random and adversarial messages over 10^6
      connections, asserting the server never crashes, wedges, leaks or answers malformed
      (`tests/fuzz/client-fuzz.lisp`, `scripts/fuzz-client.sh`, 42 s for 10^6)

**Gate:** `wayland-info` exits 0 against our server; soak test flat; fuzz client cannot
crash or wedge the server.  All three are `gate.sh` clauses (6, 7, 8) and pass, plus an
independent C client as clause 9.

**Demo:** `wayland-info` talking to a Lisp server.  Done: `./scripts/wayland-info-server.sh`,
or `(wayland.server:make-demo-display)` from the REPL plus
`(wayland.server:run display)`.

---

## Phase 2 — Core globals, shm, headless, pixman (6-8 weeks)

**Status: phases 2a and 2b landed.** `wl_shm`, the `wl_compositor`/`wl_surface` core state
machine, the headless compositor, the pixman renderer, readback, regions, transform and buffer
scale, damage tracking with buffer age and opaque culling are in, as is the scene graph (PHASE
3c landed it early). Gate clause 10: a libwayland shm client draws through our compositor and
the captured frame matches, pixel for pixel; gate clause 19: the same client at buffer scale 1
and 2, with 90- and 180-degree transforms, and an incremental frame that equals a full repaint.
The ticks below say which is which.

`cf.types.compositor`
- [x] `wl_compositor.create_surface`; the surface state machine's core
- [x] `create_region` and `wl_region` ops (phase 3b: real clients create regions before they
      map; the set arithmetic is in `wayland.server` and tested)
- [x] surface pending/current state: attach, damage, commit, frame callbacks
- [x] input regions acted on: hit testing honours them, and an empty region makes a surface
      click-through (phase 3c, D31.4)
- [x] opaque regions acted on: an opaque surface culls what is under it (phase 2b, D48)
- [x] transform, scale, buffer scale (phase 2b, D49)
- [x] `commit`: apply, release the replaced buffer, hand damage to the compositor
- [x] `wl_surface.frame` → `done` after presentation, never at commit
- [ ] error cases: no role, invalid scale, invalid transform, bad size (2b)

`cf.types.shm`
- [x] pool fd → `mmap` (`PROT_READ`), descriptor closed with the pool object; buffers keep the
      mapping alive, the last buffer unmaps it
- [x] `wl_shm_pool.resize` (phase 3b)
- [x] `create_buffer` with the §3 validation (stride, offset, 64-bit bounds, dimensions)
- [x] format table + `wl_shm.format` ordering (`argb8888`, `xrgb8888`)
- [x] `wl_buffer.destroy` / `release` exactly-once
- [ ] truncation/SIGBUS study + opportunistic `F_SEAL_SHRINK` (phase 6)
- [x] the first real client found two of our bugs here: the fd wire format (zero octets, not
      four) and the pool/buffer lifetime rule

`cf.backend.headless`, `cf.render.pixman`, `cf.render.damage`, `cf.scene` v0
- [x] headless output at configured size; frames driven by commit (an idle per reactor cycle)
- [x] pixman target, `OVER`/`SRC` chosen by format, premultiplied ARGB, buffers read in place
- [ ] clip regions, scaling, transforms (2b)
- [ ] damage region per output, buffer age, partial repaint (2b)
- [x] scene v0: `buffer`, `rect` and `image` nodes, a root per output, stacking order and hit
      test (phase 3c, D31); damage and culling stay 2b
- [x] window placement: a cascade by default, `cf:on-new-toplevel` to replace it (D31.2)
- [x] a drawn cursor: an arrow as an `image` node composited last, moved by injected motion,
      never hit-tested (D31.6)
- [x] `read-pixels` (`frame-pixel`, the target's octets) → PNG writer

`cl-wayland-client` (complete)
- [ ] all argument types incl. fd receive; event dispatch; hooks
- [ ] connect to a real compositor; bind `wl_compositor`/`wl_shm`; allocate a pool; draw

**Gate:** `weston-simple-shm` renders into the headless backend and the PNG matches the
reference within tolerance; surface-state trace tests pass; malicious-pool tests pass.
Done in phase 3a for the first half (a real client draws through us; the pixel assertions are
structural rather than hashes, which is still the choice after 2b -- clause 19 asserts the
quadrants each scale and transform implies), and completed by clause 10's frame and clause 19's
scale/transform/damage checks; surface-state trace tests and the malicious-pool cases are in
`wayland.test.server`.

**Demo:** a client's pixels in a PNG, produced with no libwayland in the process.

---

## Phase 3 — `cl-tinywl`, nested (3-4 weeks)

**Status: phase 3a landed (xdg-shell toplevels), 3b landed (seats and input), 3c landed (the
scene: placement, hit testing, click-to-focus, a drawn cursor), 3d landed (grabs and
keybindings), 3e landed (the client library completed, and a nested session that draws and
takes input), and the exit slice landed (`cl-tinywl` itself: the parity script runs it headless
and nested).** The v1 state machine is in
`cl-wayland-server/src/xdg-shell.lisp` and the policy seam is `cf:on-new-toplevel`. Gates:
clause 11 `./scripts/xdg-shell-gate.sh`, clause 12 `./scripts/seat-gate.sh`, clause 13
`./scripts/scene-gate.sh`, clause 14 `./scripts/grab-gate.sh`, clause 15
`./scripts/nested-gate.sh`, clause 16 `./scripts/tinywl-parity.sh`, clause 17
`./scripts/popup-gate.sh`, clause 18 `./scripts/focus-gate.sh`. A nested window on a foreign
compositor is open below.

`cf.types.xdg-shell` (core)
- [x] `xdg_wm_base` ping/pong; error conditions (`role`, `defunct_surfaces`)
- [x] `xdg_surface.get_toplevel`, initial configure after initial commit, `ack_configure`
      (serial bookkeeping, `invalid_serial`, `unconfigured_buffer`, `already_constructed`,
      `defunct_role_object`)
- [x] `xdg_toplevel` configure size/states, title, app_id, min/max, close
      (`configure_bounds`/`wm_capabilities` wait for a version bump; the global is v1)
- [x] `move`/`resize` requests with serial validation, and grabs behind them (phase 3d, D33)
- [x] `set_activated` driving a configure with the `activated` state (focus and click-to-focus
      call `set-toplevel-activated`, and the gate asserts the state array either way)
- [x] `xdg_popup` + `xdg_positioner` at v1 (phase 3f, D44): placement by the positioner's
      rules against a compositor-supplied box, `popup_done`, topmost-popup ordering, and an
      explicit grab dismissed by a click outside or by Escape. `reposition`/reactive positioning
      and v3+ wait for a version bump (phase 6)
- [ ] `cf.types.xdg-shell`: map/unmap events, layout placement, activation policy

`cf.types.seat`
- [x] capabilities; keyboard/pointer objects; enter/leave (`wl_seat` v4, D27)
- [x] keymap memfd + `repeat_info`; modifiers; key events (D28)
- [x] pointer motion/button/axis; `set_cursor` accepted and recorded
- [x] a cursor actually drawn (phase 3c: the built-in arrow; client cursor *surfaces* and
      theme shapes are phase 5)
- [x] focus, and `set_activated` on focus change (`cf:focus-surface` → `seat-focus-changed`)
- [x] click-to-focus, and pointer focus that follows the pointer (phase 3c, D32)
- [x] interactive move and resize grabs, started from a validated serial (phase 3d, D33)
- [x] a keybinding table consulted before the client; Alt+Esc and Alt+F1 as defaults (D33)
- [x] focus stack (phase 3g, D45): `cf:compositor-focus-stack` is history in
      most-recently-focused order, Alt+Tab rotates it (and raises), a closing window hands the
      keys to the next in it, and popups push the window they belong to rather than entering
- [x] a *visible* switcher (phase 3i, D51): the scene's overlay root plus a text node in a
      built-in 5x7 font (`cf.font`), `cf.switcher` listing the focus stack from its tail, Tab
      walking it, and the release making the one focus-and-raise call the cycle makes
- [x] a thumbnail in a switcher row (D52): a snapshot of the window taken once, at the
      resolution the row shows it at, so a repainting client cannot repaint the panel
- [ ] `xdg_activation`-style "demands attention", and a live preview rather than a snapshot
- [x] clamping: a resize stops with the dragged edge at the output's border and the opposite
      edge anchored, and every window is re-clamped when the output shrinks (D46)
- [x] edge-anchored resizing (D53): the dragged edge is placed from the size the drag asked for
      on every motion, so a top/left drag follows the pointer, and the anchor is made exact again
      when the client answers; Escape-to-cancel bound by default is still open
- [x] popup grabs: owner-events, dismissed by a press outside the stack or by Escape (phase 3f)
- [x] grabs: `begin-move`/`begin-resize` from `move`/`resize`, serial validation (phase 3d, D33)
- [ ] `wl_pointer.frame` and `wl_seat.release` (a version bump, not a rewrite)
- [x] the key table covers the keys a session needs, and `tests/unit/input.lisp` asserts it: TLDE
      (between Escape and 1) was missing, so `` ` `` and `~` could not be typed at all until 3h
- [ ] F5–F12 and the numeric keypad are not in the table either (no terminal needs them, and a
      key that is absent cannot be bound either)

`cl-wayland-client` (phase 3e, D34)
- [x] event classes for surfaces, regions, buffers, seats, devices and xdg-shell, chosen by
      wire interface name on `bind` and on server-chosen ids
- [x] `wl_compositor.create_surface`/`.create_region`; `attach`/`damage`/`frame`/commit/
      `set_*_region`/`set_buffer_scale`/`set_buffer_transform`/`destroy`; `wl_region`; `wl_buffer`
- [x] `wl_shm.create_pool` with a descriptor (D23), `wl_shm_pool.create_buffer`/`.resize`,
      a client pool (memfd, mapping) and buffer records with bounds-checked pixel access
- [x] `wl_seat.get_pointer`/`.get_keyboard`/`.get_touch`/`.release`;
      `wl_pointer.set_cursor`/`.release`; `wl_keyboard.release`; `wl_touch.release`
- [x] `xdg_wm_base.get_xdg_surface`/`.pong`/`.destroy`; `xdg_surface.get_toplevel`/
      `.set_window_geometry`/`.ack_configure`/`.destroy`; `xdg_toplevel.set_title`/`.set_app_id`/
      `.destroy`; `ping` answered with `pong` by the library
- [ ] a client-side cursor surface and theme shapes (phase 5)
- [ ] an event-driven nested demo binary (needs a window on a live session, so it needs its own
      authorization)

`cf.backend.nested` (phase 3e, D34)
- [x] output = parent `wl_surface` (xdg_toplevel when the parent offers xdg-shell) + two shm
      buffers, rendered into directly and attached with a full damage
- [x] input = parent `wl_seat` pointer/keyboard events → the same `cf:inject-*` calls a test uses;
      evdev codes translated through our key table, modifiers recomputed from our keymap
- [x] parent `wl_surface.frame` → our frame clock; a frame with no free buffer is deferred, not
      queued; `wl_buffer.release` re-arms
- [x] teardown: destroy the parent's window, unmap, close both displays, no descriptor leak
- [x] resize when the parent configures (D37: output, scene and buffers follow it)
- [ ] scale from the parent output; more than two buffers; a merged reactor wait

`cl-tinywl` (the exit slice, D36)
- [x] the parity table in `PLAN.md` §7, as built — the table now records the real names
- [x] policy: `on-new-toplevel` (origin placement), `focus-toplevel`, `desktop-toplevel-at`,
      `begin-interactive` + `edges-at`, `on-pointer-button` (Alt+left moves, Alt+right resizes)
- [x] keybindings: `Alt+Esc` (closes the clients, then quits), `Alt+F1`
- [x] a session in either mode (`tinywl:start`/`advance`/`run`/`stop`) and `(tinywl:main)` with
      `--headless`/`--nested`/`--parent`/`--size`/`--display`
- [x] a client's `set_cursor` surface is not drawn as a window (phase 5 draws it properly)
- [ ] a `save-lisp-and-die` binary and an `sbcl --script` launcher (packaging, not behaviour)
- [ ] kitty as the demo client: it needs the EGL/GLES path, so it arrives with phase 4; the
      parity gate uses weston's clients, which draw through shm

**Gate:** clause 16, `./scripts/tinywl-parity.sh` — the parity script run twice, headless with
injected input and nested inside another compositor, with two real clients and the clauses
PLAN §5 lists (placement, click-to-focus, typing to the focused window only, drag, edge resize,
Alt+F1, Alt+Esc, an ordered `WAYLAND_DEBUG` stream).

**Demo:** `cl-tinywl` in a window, with a client inside, moved/resized with the mouse. The
parity gate does exactly this in one image. Running it on a live session is a separate,
explicitly authorized step (it maps a window on the user's desktop).

---

## Phase 4 — DRM dumb buffers, libinput, sessions (6-8 weeks)

`cf.session`, `cf.backend.drm`
- [x] libseat: `open_seat`, `open_device`, `close_device`, `disable_seat` acknowledgement,
      enable/disable state machine; seatd and logind both compiled in (D56)
- [ ] switch callbacks exercised live: VT away/back from a compositor that owns one (4d)
- [ ] fallback direct VT path (`VT_GETSTATE`/`VT_ACTIVATE`, `KDGKBMODE`)
- [x] resources/connectors/encoders/CRTCs; preferred mode; each CRTC's current scanout (D54)
- [x] `SETCRTC`, `SET MASTER`, and the saved state put back on close (D55)
- [x] dumb buffers: create/map/addfb (D54)
- [x] double buffering: two buffers, present waits for the flip that retires the frame (D55)
- [ ] triple buffering
- [x] `PAGE_FLIP` + `read()` of the kernel's completion event; monotonic sequences and
      timestamps checked (D55)
- [ ] frame callbacks with the kernel's real timestamps
- [ ] VT switch away/back; teardown and restore
- [ ] hotplug add/remove; output re-layout (4d; the libinput udev context is implemented)
- [ ] suspend/resume hooks

`cf.backend.libinput`, `cf.input` (xkbcommon)
- [x] libinput context: udev (assign seat, hotplug) and path (add by name) (D56)
- [x] keyboard and pointer decoding; per-device settings (tap-to-click, natural scrolling) (D56)
- [ ] touch, tablet, pad, switch and gesture decoding
- [x] xkb keymap compile, state, mods, keysyms, repeat (D57)
- [x] keymap memfd to clients: the rules-compiled map, parsed back and by a real client (D57)
- [ ] device-specific keymaps (one layout per seat today)
- [ ] software cursor in the scanout buffer

**Gate:** the PLAN §5 phase 4 list — TTY session, VT switch, hotplug, 8-hour soak, resume.

**Demo:** a real session on a real TTY with no X, no Wayland, no EGL.

---

## Phase 5 — GPU (5-8 weeks)

- [ ] EGL context via GBM/surfaceless; GLES2 bindings generated from the Khronos registry
- [ ] texture upload from shm; FBO targets; damage scissor
- [ ] `wl_shm` → texture cache with eviction
- [ ] atomic KMS: property enumeration, test/commit, rollback
- [ ] planes: primary, cursor, overlay (cursor plane first)
- [ ] `linux-dmabuf`: params, modifiers, `EGL_EXT_image_dma_buf_import(_modifiers)`,
      format/modifier feedback, fallback
- [ ] direct scanout for fullscreen single-surface frames
- [ ] golden-image equivalence: pixman vs GL within tolerance

**Gate:** phase 4 session on the GL renderer with measured frame/CPU/GPU times; dmabuf
client renders and falls back correctly; direct scanout engages/disengages.

**Demo:** 4K session with the CPU near idle.

---

## Phase 6 — `cl-umbra` v1 (14-20 weeks)

Core
- [ ] compositor object, backend/output/seat wiring, crash-safe shutdown, state file
- [ ] config: safe reader (`*read-eval*` nil, dedicated package, size cap, line index),
      per-section schema with suggestions, referential checks
- [ ] config reload: inotify watcher + SIGHUP + `(umbra:reload-config)`, diff-then-apply,
      atomic rollback
- [ ] config tooling: `--check-config`, `(current-config)`, `(config-schema)`, migration table
      from Umbriel's TOML keys
- [ ] package `umbra`: exported command/query functions with docstrings and lambda lists;
      one path shared by keybindings, scripts and the REPL (D14)
- [ ] control channel: opt-in SLYNK server, 0600 eval socket with peer check, safe-point
      execution under a deadline, errors as values (never the debugger), read-only flag,
      peer/form logging
- [ ] `umbra-cmd` wrapper plus `socat` examples for shell scripts

Layouts
- [ ] master/stack with configurable ratios and counts
- [ ] scrolling/column model (niri semantics: column widths, focus follows, consume/expel)
- [ ] floating/manual layer; move/resize/swap/focus bindings; mouse resize
- [ ] per-workspace layout; workspace names and switching; per-output workspaces
- [ ] hotplug restore of workspace→output mapping

Window management
- [ ] window rules (app-id/title → workspace/layout/float/size/output)
- [ ] layer rules (bar/notification placement, exclusive zones)
- [ ] focus policy: follow-mouse vs click-to-focus, raise-on-focus, urgent hints
- [ ] fullscreen/maximize, close, kill, scratchpad (cheap; add if time allows)

Protocols (PLAN §6 "phase 6" rows)
- [ ] `wl_data_device_manager` (clipboard, primary, DnD with serial validation)
- [ ] `wlr-layer-shell`, `xdg-decoration`, `xdg-output`, `fractional-scale`, `viewporter`
- [ ] `cursor-shape-v1`, `idle-inhibit`, `keyboard-shortcuts-inhibit`
- [ ] `primary-selection`, `data-control`
- [ ] `presentation-time`, `wlr-screencopy`, `wlr-output-management` (basic)
- [ ] `xdg-activation`, `wlr-foreign-toplevel`
- [ ] `ext-session-lock`
- [ ] `wl_touch` if a touch device is available

Session
- [ ] lock screen flow; idle timeouts; logind sleep/lid; child process supervision
- [ ] screenshot tool; screencopy path for the portal

**Gate:** the daily-driver checklist in PLAN §5, phase 6 — a full week of real use.

**Demo:** the author's desktop for a week, with `cl-umbra` in the process list.

---

## Phase 7 — Parity and polish (open-ended, ordered by pain)

- [ ] scene effects: offscreen passes, blur (GLES), shadows, rounded corners, borders
- [ ] animation framework: curves, per-node transforms, workspace transitions
- [ ] HDR: colour management protocol, output metadata, tone mapping
- [ ] VRR / adaptive sync, tearing control
- [ ] explicit sync (`linux-drm-syncobj-v1`) — likely the first Rust shim (D4)
- [ ] Xwayland: supervise `xwayland-satellite` (needs `xdg-shell` + `wp-viewporter`, both
      above), `-listenfd` on-demand activation, `DISPLAY` for children, crash restart
- [ ] input methods (`text-input`, `input-method`), tablet, gestures, pointer constraints
- [ ] multi-GPU, output leasing, virtual outputs, DRM leasing
- [ ] overview/exposé, tab groups, title bars, drop zones
- [ ] sandboxed client sockets, per-client logging, crash reporting

---

## First two weeks (do this next)

1. [x] `git init`, six system dirs, `.asd` skeletons, SPDX headers (the GPL-3.0 `LICENSE`
   is already in place), `qlfile`, `Makefile`.
2. [x] Vendor `wayland.xml`, `wayland-protocols`, `wlr-protocols`; pin versions in
   `protocols/README.md`.
3. [x] `wayland.wire` + tests: header, ints, strings, arrays, fixed, objects, fds
   (queued, not yet sent). No sockets yet.
4. Record fixtures: `WAYLAND_DEBUG=1 kitty` capture, plus a `wayland-info` capture.
5. [x] `sendmsg`/`recvmsg` fd path with `socketpair` + `memfd_create`; test the 28-fd
   boundary and `MSG_CTRUNC`.
6. [x] Reactor + epoll + timerfd; a test that sleeps exactly as long as asked.
7. [x] XML schema parser; assert opcodes match `wayland-scanner` (all 69 files).
8. `demo-globals` against the live session.
9. [x] `scripts/purity-check.sh` (fails if `libwayland*` or `libwlroots*` appears in
   `ldd`); `scripts/check-loads.sh` probes the loaded image's `/proc/self/maps`.
10. Write the phase-0 gate as a script, even though it fails at first.

## Re-planning rules

- After each phase, re-estimate the remaining phases by the ratio of actual to estimated
  weeks. Update `PLAN.md` §5 rather than carrying stale numbers.
- If a phase exceeds 1.5× its estimate, stop and ask whether the phase's scope was wrong
  (split it) or the design was wrong (fix it) — do not just extend.
- If a gate fails for reasons outside its phase (e.g. an interop bug found in phase 5 that
  belongs to phase 2), fix it at the owning layer before continuing.
- Cut from the *bottom* of the feature list, never from the gates.
