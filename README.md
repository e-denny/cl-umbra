# cl-umbra

A Wayland stack written in Common Lisp, from the socket up.

The repository is named for where the stack is going: `cl-umbra`, a daily-driver compositor.
Everything that makes it possible is here too — the protocol implementation, the server, the
compositor framework, and a tinywl port — as the six systems below.

**Status: phase 0, phase 1, phase 2a, phase 3a, phase 3b and phase 3c gates passing.**
`./scripts/gate.sh` checks thirteen clauses. Phase 0: the unit suite (184 tests), every vendored protocol compiling,
`demo-globals` against a live compositor, 10⁶ decoder fuzz cases. Phase 1: `wayland-info` —
the system's own libwayland client — exits 0 against *our* server; 10k connect/disconnect
cycles leave the descriptor count and resident set flat; 10⁶ adversarial client connections
neither crash, wedge, leak nor get a malformed reply; and an independent libwayland C client
binds, destroys and re-binds across versions. Phase 2a: a libwayland shared-memory client
draws a known pattern through our headless compositor, gets its frame callback, and the
captured frame matches pixel for pixel (with a PNG screenshot to prove it). Phase 3:
`weston-simple-shm` — a real xdg-shell client — binds `xdg_wm_base`, is configured, acks our
serial, commits a buffer and draws a window through us; the gate checks the frame's pixels,
answers our ping, and confirms the client never sees a protocol error. Phase 3b:
`weston-eventdemo` is focused, sent a keymap and typed at — the gate requires the *client's own
output* to show our injected motion, button, scroll and keys, including keycode 16 translated
to "Q" with the shift mask, and a libxkbcommon probe parses the keymap we actually sent.
Phase 3c: two real windows are placed at (0,0) and (32,32); hovering one moves the pointer
without moving the keys, clicking moves the keyboard and the `activated` configure, both
windows are drawn where they were placed, and the cursor's own pixels are composited last at
the pointer's position. Purity (no libwayland, no wlroots) runs over all of it. The gate exits
0.

Three roadmap quality items are still open and are not gate clauses: fixed-size in/out
rings, `WAYLAND_DEBUG`-compatible tracing, and surplus-descriptor detection (which needs a
protocol layer that knows a message's descriptor count).

What exists:

- `cl-wayland-core` — `wayland.wire` (framing and argument codec), `wayland.ffi` (sockets,
  `sendmsg`/`recvmsg` with `SCM_RIGHTS`, lock files, `SO_PEERCRED`), `wayland.object` (one
  object table and both id namespaces, shared by both ends), `wayland.io` (flush and pump,
  descriptors, partial messages), `wayland.reactor` (epoll, timers, idles, posted commands,
  signals), `wayland.protocol` (the 69-file XML corpus, checked against `wayland-scanner`)
  and `wayland.codegen` (schema to Lisp, generated at build time).
- `cl-wayland-client` — connect, proxies and ids, `get_registry`, `bind`, `sync` roundtrip,
  hooks or methods on the generated event functions. `demo-globals` prints the live session's
  globals in `wayland-info`'s format, byte-identical.
- `cl-wayland-server` — the socket with its lock file and permissions, accept with peer
  credentials, `wl_display` and both id ranges, globals and version-negotiated `bind`,
  `wl_display.sync`, the error policy, flush batching with backpressure, and idempotent
  teardown. Phase 2a added `wl_shm` (pools, buffers, two formats, the validation a malicious
  client would otherwise turn into a read of our memory) and the `wl_compositor`/`wl_surface`
  state machine (attach, damage, frame, commit, destroy). Phase 3 added `xdg-shell` v1 —
  `xdg_wm_base` with ping/pong, the `xdg_surface` configure/ack handshake with real serial
  bookkeeping, and `xdg_toplevel` with title, app id, size hints and a configure carrying a
  complete state array. Popups, positioners and decoration negotiation are deliberately absent
  and answer `implementation`. Phase 3b added `wl_seat` (v4) with `wl_pointer`, `wl_keyboard`
  and a generated XKB keymap, explicit focus that activates the focused toplevel, `wl_region`,
  `wl_compositor` v3, and `wl_shm_pool.resize`. Phase 3c added the scene: nodes with positions
  and stacking, hit testing that honours input regions, a cascade placement policy behind
  `cf:on-new-toplevel`, and a built-in cursor composited last. The demo server offers two dummy
  globals so `wayland-info` has something true to print.
- `cl-compositor-framework` — a pixman renderer (the reference), a headless compositor that
  draws committed surfaces into an in-memory target and offers `wl_compositor`, `wl_shm`,
  `wl_output`, `xdg_wm_base` and `wl_seat`, `read-pixels`, a PNG writer, `cf.input`
  (generated keymaps, keycodes, modifier state) and `cf.scene` (buffer/rect/image nodes, hit
  testing, a software cursor). Backends beyond headless, damage and the remaining seat work
  (grabs, a focus stack) are phases 2b-5.

## What this is

Six systems, built in order, each useful on its own:

| System | Role | Analogue it replaces | Phase |
|---|---|---|---|
| `cl-wayland-core` | Wire format, fd passing, protocol schema + code generation, object model, event loop | libwayland's guts, wayflan's wire/scanner | 0 |
| `cl-wayland-client` | Client-side display and proxies | libwayland-client | 0, 3 |
| `cl-wayland-server` | Display, globals, resources, clients, serials, error policy | libwayland-server | 1 |
| `cl-compositor-framework` | Backends, renderers, scene graph, seat/input, output, shell protocol state machines | **wlroots** | 2-5 |
| `cl-tinywl` | The tutorial compositor | tinywl | 3 |
| `cl-umbra` | A compositor for daily use | Umbriel / niri / sway | 6-7 |

Two build-time systems sit beside those six: `cl-wayland-asdf` (the
`:wayland-protocol` component type) and `cl-wayland-protocols` (its generated output).

Dependency direction is strictly one-way:

```
cl-wayland-core
   ├── cl-wayland-client
   └── cl-wayland-server
          └── cl-compositor-framework
                 ├── cl-tinywl
                 └── cl-umbra
```

## What this is not

- **Not a binding.** No `libwayland`, no `libwlroots`, no `libwayland-server` in the
  process, ever. The Wayland protocol is implemented here in Lisp. The CI purity check
  fails the build if those libraries appear in `ldd` output or in `/proc/self/maps`.
- **Not a wrapper.** `cl-compositor-framework` is not CFFI over wlroots. It is a Lisp
  framework that does wlroots' *job*: backend abstraction, output lifecycle, renderer,
  scene graph, seat and focus, shell state machines, protocol implementations. The
  vocabulary is borrowed; the code and the API are not.
- **Not a GUI toolkit.** Clients (toolkits, terminal emulators, browsers) stay C or Rust
  or whatever they are. This is the server side of the conversation, plus a Lisp client
  for testing and for the nested backend.
- **Not an IPC protocol.** Control is Lisp: attach a REPL, or send a form over a local
  socket. No command registry, no JSON message layer, no event bus (D14).

## Ground rules

1. **shm first.** `wl_shm` is the mandatory buffer path and the primary one here:
   memfd/mmap, zero-copy reads, CPU compositing with pixman. A real DRM/KMS session is
   reachable with dumb buffers and no EGL at all. GPU paths (GBM/EGL/dmabuf) are
   optimizations added later behind the same renderer interface — never prerequisites.
2. **CFFI to the kernel and drivers, not to compositor libraries.** `libdrm`,
   `libinput`, `libxkbcommon`, `libpixman`, `libseat`, `libudev` are fair game: they are
   hardware/session APIs. If a path is genuinely hostile to CFFI, a **small** Rust shim
   with a plain-C ABI is preferred over a C shim, and it must be a leaf: it talks to the
   kernel, never to Wayland.
3. **SBCL first.** Not SBCL-only by design, but no portability contortions until the
   thing works. Core code avoids SBCL-specifics where it costs nothing.
4. **The socket is the boundary.** Everything past the socket is Lisp: objects, state
   machines, dispatch, rendering, input.
5. **GPL-3.0-or-later.** Every system and these docs are copyleft: a compositor built on
   the framework stays GPL. Wayland *clients* are unaffected — talking over the socket is
   not linking. Vendored protocol XML keeps its own MIT/HPND notices.

## Reading order

1. [`PLAN.md`](PLAN.md) — stages, architecture, phases, acceptance criteria, risks.
2. [`docs/architecture.md`](docs/architecture.md) — module map, data flow, threading, conditions.
3. [`docs/protocol-layer.md`](docs/protocol-layer.md) — wire format, codegen, server semantics, event loop.
4. [`docs/memory-and-rendering.md`](docs/memory-and-rendering.md) — the shm-first memory model, pixman and DRM paths.
5. [`docs/framework.md`](docs/framework.md) — what `cl-compositor-framework` provides and why.
6. [`docs/config-and-control.md`](docs/config-and-control.md) — config language and reload model, and why control is the REPL rather than an IPC protocol.
7. [`docs/roadmap.md`](docs/roadmap.md) — task-level checklists per phase.
8. [`docs/testing.md`](docs/testing.md) — how each claim in the plan gets verified.
9. [`docs/prior-art.md`](docs/prior-art.md) — what is borrowed from wayflan, wlroots, tinywl, ulubis, river, niri, Umbriel.

## Workspace

Developed on Arch, SBCL 2.6.10, AMD Renoir (Mesa 26.3), wlroots 0.20 and libwayland
installed **only as test fixtures and to run reference compositors** — never linked by
this project. Test clients: `kitty`, `weston-simple-shm`, `wayland-info`.

## Vendored protocols

`protocols/` holds the protocol XML (wayland, wayland-protocols stable/unstable/staging,
wlr-protocols) with versions pinned in `protocols/README.md`. It is vendored, not a
submodule: a build must not need the network, and the oracle test re-derives every
opcode and signature from `wayland-scanner`.

## Building and testing

```
make check     # test suite, 10k fuzz cases, every system loads, purity, wayland-info
./scripts/gate.sh                       # every gate clause, phases 0-3
TEST_VERBOSE=1 ./scripts/run-tests.sh   # list every assertion instead of dots
```

Each probe also runs alone: `scripts/run-tests.sh`, `scripts/check-loads.sh`,
`scripts/purity-check.sh`, `scripts/wayland-info-server.sh` (a real client against our
server), `scripts/c-probe.sh` (an independent libwayland C client), `scripts/fuzz-client.sh`
(adversarial clients) and `scripts/soak.sh` (10k connections; `SOAK_CYCLES` overrides). The runtime dependency list is SBCL plus CFFI — CFFI is for libc
(sockets, `sendmsg`/`recvmsg` with `SCM_RIGHTS`, `memfd_create`), never for libwayland. The
test suite additionally uses [Rove](https://github.com/fukamachi/rove); no shipped system
loads it. The scripts find Quicklisp at the usual places or through `QUICKLISP_SETUP`, or
use `qlot` if you prefer the pinned `qlfile`.

## Hello, compositor

`demo-globals` connects to the compositor this process would draw on, reads the registry,
and prints every global: the phase-0 walking skeleton.

```
sbcl --eval '(require :asdf)' \
     --eval '(asdf:load-system "cl-wayland-client/demo")' \
     --eval '(wayland.client.demo:main)'

# or build a binary (written to cl-wayland-client/demo-globals)
sbcl --eval '(require :asdf)' --eval '(asdf:make "cl-wayland-client/demo")'
./cl-wayland-client/demo-globals
```

The output is deliberately `wayland-info`'s line format, so the check is a diff:

```
diff <(wayland-info | grep '^interface:') <(./cl-wayland-client/demo-globals)
```

## Hello, server

The other direction, and the phase-1 walking skeleton: a Lisp server that a real libwayland
client talks to. `wayland-info` against it exits 0.

```
# in one terminal: a private runtime directory, so the live session is untouched
export XDG_RUNTIME_DIR="$(mktemp -d)" WAYLAND_DISPLAY=wayland-0
chmod 700 "$XDG_RUNTIME_DIR"
sbcl --eval '(require :asdf)' \
     --eval '(asdf:load-system "cl-wayland-server/demo")' \
     --eval '(wayland.server.demo:toplevel)'

# in another, with the same two variables
wayland-info
```

## Hello, keys

The phase-3b gate, in one command: `weston-eventdemo` is focused and typed at through a real
keymap, and its printed events — coordinates, button codes, unicode code points, modifier
masks — are the assertions.

```
./scripts/seat-gate.sh
```

## Hello, windows

The phase-3 gate, in one command: `weston-simple-shm` — a real xdg-shell client with its own
libwayland — opens a window through our compositor, is configured and acknowledged, and draws.
The gate checks pixels, ping/pong and the object lifetimes.

```
./scripts/xdg-shell-gate.sh
```

## Hello, pointer

The phase-3c gate, in one command: two `weston-simple-shm` windows are placed, the pointer is
moved over one and clicked, the keyboard and the `activated` configure follow the click, and the
frame contains the cursor's own pixels at the pointer's position.

```
./scripts/scene-gate.sh
```

## Hello, pixels

The phase-2a gate, in one command: a libwayland shared-memory client draws a known pattern
through our headless compositor, and the frame is checked pixel by pixel and written out as a
PNG.

```
./scripts/headless-frame.sh
```

From the REPL, the same compositor is a few lines:

```lisp
(defvar *c* (cf:make-headless-compositor :width 512 :height 512))
(wayland.server:run (cf:compositor-display *c*))     ; serve clients
(cf:frame-pixel *c* 10 20)                           ; one pixel, 0xAARRGGBB
(cf:write-frame-png *c* "/tmp/frame.png")
```

It offers `wl_compositor`, `wl_shm`, `wl_output` and `xdg_wm_base`, so a real client can open
a window on it. From the REPL, the demo server without the compositor:

```lisp
(defvar *display* (wayland.server:make-demo-display :display-name "wayland-0"))
(wayland.server:run *display*)          ; Ctrl-C or (wayland.reactor:request-stop ...)
(wayland.server:close-display *display*)
```

## License

GPL-3.0-or-later. See [`DECISIONS.md`](DECISIONS.md) D13 for what that does and does not
cover: the framework and compositors are copyleft, Wayland clients that connect to them are
not derived works, and vendored protocol XML retains its MIT/HPND license.
