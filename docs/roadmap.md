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
- [ ] fuzz harness feeding a `socketpair` (needs the I/O path below)

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

**Gate:** unit + fuzz suites green; all protocols compile; `demo-globals` output equals
`wayland-info`; fuzz 10⁶ iterations with no crash/hang/leak.

**Demo:** globals of the running session, dumped from a Lisp REPL.

---

## Phase 1 — Server core (4-6 weeks)

- [ ] socket creation: `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, lock file, perms, `accept4`
- [ ] `SO_PEERCRED` capture and validation; structured client log
- [ ] `wl_display` object, id 1; client id allocation; server id range
- [ ] per-client object table; `new_id` validation
- [ ] `wl_global` add/remove; `bind` with version negotiation; initial-event ordering vs `sync`
- [ ] resource lifecycle: destroy request, destructor events, `delete_id`, id reuse
- [ ] `wl_display.sync` → `wl_callback.done` after batch
- [ ] `wl_display.error` + disconnect policy; all error codes
- [ ] flush batching (`writev`), backpressure, `EPOLLIN` gating
- [ ] `teardown-client`, idempotent, reverse-order destruction
- [ ] fd hygiene: everything `CLOEXEC`, nothing leaked on teardown
- [ ] tests: dummy globals + `wayland-info`; C client bind/destroy/rebind; kill-mid-request;
      10k connect/disconnect with flat RSS and fd count

**Gate:** `wayland-info` exits 0 against our server; soak test flat; fuzz client cannot
crash or wedge the server.

**Demo:** `wayland-info` talking to a Lisp server.

---

## Phase 2 — Core globals, shm, headless, pixman (6-8 weeks)

`cf.types.compositor`
- [ ] `wl_compositor.create_surface/create_region`; `wl_region` ops
- [ ] surface pending/current state: attach, damage, opaque, input, transform, scale,
      buffer scale, frame callbacks
- [ ] `commit`: apply, validate, release old buffer, queue frame if needed
- [ ] `wl_surface.frame` → `done` on presentation
- [ ] error cases: no role, invalid scale, invalid transform, bad size

`cf.types.shm`
- [ ] pool fd → dup → `mmap` (`PROT_READ`), `resize`, refcount
- [ ] `create_buffer` with §3 validation (64-bit arithmetic)
- [ ] format table + `wl_shm.format` ordering
- [ ] `wl_buffer.destroy` / `release` exactly-once
- [ ] truncation/SIGBUS study + `F_SEAL_SHRINK` opportunistic sealing

`cf.backend.headless`, `cf.render.pixman`, `cf.render.damage`, `cf.scene` v0
- [ ] headless output at configured size/scale/transform; timer-driven frames
- [ ] pixman target, clip regions, `OVER`/`SRC`, scaling, transforms
- [ ] damage region per output, buffer age, partial repaint
- [ ] scene: `buffer` and `rect` nodes, per-output root, stacking order, hit test v0
- [ ] `read-pixels` → PNG writer (for tests and screenshots)

`cl-wayland-client` (complete)
- [ ] all argument types incl. fd receive; event dispatch; hooks
- [ ] connect to a real compositor; bind `wl_compositor`/`wl_shm`; allocate a pool; draw

**Gate:** `weston-simple-shm` renders into the headless backend and the PNG matches the
reference within tolerance; surface-state trace tests pass; malicious-pool tests pass.

**Demo:** a client's pixels in a PNG, produced with no libwayland in the process.

---

## Phase 3 — `cl-tinywl`, nested (3-4 weeks)

`cf.types.xdg-shell` (core)
- [ ] `xdg_wm_base` ping/pong; error conditions
- [ ] `xdg_surface.get_toplevel`, initial configure after initial commit, `ack_configure`
- [ ] `xdg_toplevel` configure size/states, title, app_id, min/max, activated, close
- [ ] `move`/`resize` requests with serial validation
- [ ] basic `xdg_popup` + `xdg_positioner` (needed by menus; polish in phase 6)

`cf.types.seat`
- [ ] capabilities; keyboard/pointer objects; enter/leave; frame events
- [ ] keymap memfd + `repeat_info`; modifiers; key events
- [ ] pointer motion/button/axis; cursor surface with hotspot
- [ ] focus stack, `set_activated` on focus change

`cf.backend.nested`
- [ ] output = parent `wl_surface` + shm buffers; attach/commit with damage
- [ ] input = parent `wl_seat` → our seat events
- [ ] parent `wl_surface.frame` → our frame clock
- [ ] resize when parent configures; scale from parent output

`cl-tinywl`
- [ ] the parity table in `PLAN.md` §7
- [ ] keybindings: `Alt+Esc`, `Alt+F1`
- [ ] `save-lisp-and-die` binary + `--nested`/`--headless` flags

**Gate:** the tinywl parity script (PLAN §5, phase 3) passes nested, and headless with
synthetic input.

**Demo:** `cl-tinywl` in a window, kitty inside, moved/resized with the mouse.

---

## Phase 4 — DRM dumb buffers, libinput, sessions (6-8 weeks)

`cf.session`, `cf.backend.drm`
- [ ] libseat: `open_seat`, `open_device`, `close_device`, switch callbacks; seatd and
      logind; fallback direct VT path
- [ ] resources/connectors/encoders/CRTCs; preferred mode; `SETCRTC`
- [ ] dumb buffers: create/map/addfb; double + triple buffering
- [ ] `PAGE_FLIP` + `read()` vblank; frame callbacks with real timestamps
- [ ] VT switch away/back; teardown and restore
- [ ] hotplug add/remove; output re-layout
- [ ] suspend/resume hooks

`cf.backend.libinput`, `cf.input` (xkbcommon)
- [ ] udev + libinput context, assign seat, hotplug
- [ ] keyboard/pointer/touch/tablet/switch decoding; per-device settings
- [ ] xkb keymap compile, state, mods, keysyms, repeat
- [ ] keymap memfd to clients; device-specific keymaps
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
