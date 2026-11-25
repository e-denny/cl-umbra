# cl-wayland-project

A Wayland stack written in Common Lisp, from the socket up.

**Status: phase 0 in progress.** Planning is complete — [`PLAN.md`](PLAN.md), the design
documents in [`docs/`](docs/), and the decision log [`DECISIONS.md`](DECISIONS.md) — and
the first slice of `cl-wayland-core` exists: `wayland.wire` (framing and argument
codec), `wayland.ffi` (sockets, `sendmsg`/`recvmsg` with `SCM_RIGHTS`, errno) and
`wayland.io` (flush and pump, descriptor passing, partial-message handling) and
`wayland.reactor` (epoll, timerfd, eventfd wakeups, signalfd, idles) and
`wayland.protocol` (the 69-file protocol XML corpus, parsed and checked against
`wayland-scanner`) and `wayland.codegen` (schema to Lisp, generated at build time by
the `:wayland-protocol` ASDF component). `cl-wayland-client` is now a working client:
it connects to the compositor named by `WAYLAND_DISPLAY`, reads the registry, completes a
`sync` roundtrip, and dispatches events to hooks or methods on the generated functions.
`wayland.client.demo:run` prints the live session's globals in `wayland-info`'s format;
on a running session the two outputs are byte-identical.

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
make check     # test suite (Rove), every system loads, purity scan
./scripts/gate.sh                       # the phase-0 gate, clause by clause
TEST_VERBOSE=1 ./scripts/run-tests.sh   # list every assertion instead of dots
```

Each probe also runs alone: `scripts/run-tests.sh`, `scripts/check-loads.sh`,
`scripts/purity-check.sh`. The runtime dependency list is SBCL plus CFFI — CFFI is for libc
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

## License

GPL-3.0-or-later. See [`DECISIONS.md`](DECISIONS.md) D13 for what that does and does not
cover: the framework and compositors are copyleft, Wayland clients that connect to them are
not derived works, and vendored protocol XML retains its MIT/HPND license.
