# cl-umbra

A Wayland stack written in Common Lisp, from the socket up.

The repository is named for where the stack is going: `cl-umbra`, a daily-driver compositor.
Everything that makes it possible is here too — the protocol implementation, the server, the
compositor framework, and a tinywl port — as the six systems below.

**Status: phase 0 and phase 1 gates passing.** `./scripts/gate.sh` checks seven clauses.
Phase 0: the unit suite, every vendored protocol compiling, `demo-globals` against a live
compositor, 10⁶ fuzz cases. Phase 1: `wayland-info` — the system's own libwayland client —
exits 0 against *our* server, and 10k connect/disconnect cycles leave the descriptor count
and resident set flat. Purity (no libwayland, no wlroots) runs over both. The gate exits 0.

Three roadmap quality items are still open and are not gate clauses: fixed-size in/out
rings, `WAYLAND_DEBUG`-compatible tracing, and surplus-descriptor detection (which needs a
protocol layer that knows a message's descriptor count). Two phase-1 items are honestly
unticked for the same reason: an independent C client beyond `wayland-info`, and a fuzz
*client* against the server.

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
  teardown. The demo server offers two dummy globals so `wayland-info` has something true to
  print; phase 2 adds the actual protocol content.

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
./scripts/gate.sh                       # every gate clause, phase 0 and phase 1
TEST_VERBOSE=1 ./scripts/run-tests.sh   # list every assertion instead of dots
```

Each probe also runs alone: `scripts/run-tests.sh`, `scripts/check-loads.sh`,
`scripts/purity-check.sh`, `scripts/wayland-info-server.sh` (a real client against our
server) and `scripts/soak.sh` (10k connections; `SOAK_CYCLES` overrides). The runtime dependency list is SBCL plus CFFI — CFFI is for libc
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

It offers two dummy globals — `wl_compositor` and `wl_output` — and nothing else yet: phase 2
is where surfaces, shm and the rest arrive. From the REPL, the same thing without the
executable wrapper:

```lisp
(defvar *display* (wayland.server:make-demo-display :display-name "wayland-0"))
(wayland.server:run *display*)          ; Ctrl-C or (wayland.reactor:request-stop ...)
(wayland.server:close-display *display*)
```

## License

GPL-3.0-or-later. See [`DECISIONS.md`](DECISIONS.md) D13 for what that does and does not
cover: the framework and compositors are copyleft, Wayland clients that connect to them are
not derived works, and vendored protocol XML retains its MIT/HPND license.
