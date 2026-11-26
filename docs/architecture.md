# Architecture

How the pieces fit, what owns what, and where the sharp edges are. Companion to
`PLAN.md` §3 and to `protocol-layer.md`, `memory-and-rendering.md`, `framework.md`.

---

## 1. Repository layout

```
cl-wayland-project/
├── README.md  PLAN.md  DECISIONS.md
├── docs/                        this documentation
├── protocols/                   vendored XML, pinned by commit
│   ├── wayland/                 wayland.xml (core)
│   ├── wayland-protocols/       stable/, unstable/, staging/
│   ├── wlr-protocols/           layer-shell, screencopy, foreign-toplevel, …
│   └── umbra/                   our own protocols, if any (none planned: control is Lisp, D14)
├── cl-wayland-core/
│   ├── cl-wayland-core.asd
│   └── src/  packages.lisp  ffi-util.lisp  wire.lisp  object.lisp  io.lisp
│             epoll.lisp  reactor.lisp  schema.lisp  codegen.lisp
├── cl-wayland-client/
│   ├── cl-wayland-client.asd        (also the demo system)
│   ├── src/  package.lisp  proxy.lisp  display.lisp  registry.lisp
│   └── demo/ demo-globals.lisp
├── cl-wayland-server/
│   ├── cl-wayland-server.asd        (also the demo system)
│   ├── src/  package.lisp  conditions.lisp  objects.lisp  socket.lisp
│   │         resource.lisp  messages.lisp  client.lisp  display.lisp
│   │         global.lisp  events.lisp  registry.lisp  dispatch.lisp
│   │         surface.lisp  xdg-shell.lisp  demo.lisp
│   └── demo/ server-demo.lisp
├── cl-compositor-framework/
│   ├── cl-compositor-framework.asd
│   └── src/  package.lisp  render-pixman.lisp  png.lisp  headless.lisp
│       ├── backend/   (phase 3+) protocol.lisp headless.lisp nested.lisp drm.lisp
│       │              libinput.lisp multi.lisp session.lisp
│       ├── render/    protocol.lisp pixman.lisp gles2.lisp target.lisp
│       │              damage.lisp swapchain.lisp allocator.lisp dmabuf.lisp
│       ├── scene/     node.lisp tree.lisp buffer.lisp rect.lisp output.lisp
│       │              layers.lisp hit-test.lisp
│       ├── types/     compositor.lisp surface.lisp output.lisp seat.lisp
│       │              cursor.lisp xdg-shell.lisp layer-shell.lisp
│       │              data-device.lisp decoration.lisp screencopy.lisp …
│       ├── util/      box.lisp region.lisp matrix.lisp output-layout.lisp
│       │              xcursor.lisp edges.lisp time.lisp log.lisp
│       └── session/   seat.lisp vt.lisp
├── cl-wayland-asdf/              the :wayland-protocol ASDF component (build time)
├── cl-wayland-protocols/         generated metadata, one component per XML file
├── cl-tinywl/       tinywl.lisp  main.lisp
├── cl-umbra/        compositor.lisp  layouts/  workspaces.lisp  rules.lisp
│                    config/  control/  session.lisp
├── tests/           cl-wayland-tests.asd  runner.lisp  unit/  fuzz/  interop/
│                    golden/  perf/  scripts/
├── scripts/         gate.sh  gate-protocols.lisp  wayland-info-server.sh  soak.sh
│                    soak.lisp  run-tests.sh  fuzz.sh  fuzz-client.sh
│                    c-probe.sh  headless-frame.sh  headless-gate.lisp
│                    xdg-shell-gate.sh  xdg-shell-gate.lisp  check-loads.sh
│                    purity-check.sh  lib.sh  capture.sh  run-nested.sh  run-tty.sh
└── qlfile           local Quicklisp/qlot project set
```

One ASDF system per directory; each system declares the protocols it needs, so a build
does not compile the world.

The framework's phase-2a files are flat (`render-pixman.lisp`, `png.lisp`, `headless.lisp`)
and will move into `render/` and `backend/` when there is more than one of each; the module
tree drawn below the core is the plan for phases 2b-5.

What is built, so a reader can tell the shape from the plan: the core (`wayland.wire`,
`wayland.ffi`, `wayland.object`, `wayland.io`, `wayland.reactor`, `wayland.protocol`,
`wayland.codegen`), the ASDF component, `wayland.client` — connect, proxies and ids,
`get_registry`, `bind`, `sync` roundtrip, hooks and generic-function event dispatch, plus
`demo-globals` — and `wayland.server` in its phase-1 form: socket and lock, accept with
`SO_PEERCRED`, object tables and both id ranges, globals and `bind`, `sync` and callbacks,
the error policy, flush batching with backpressure, and teardown, plus a demo server that
`wayland-info` can talk to. In phase 2a the server gained `wl_shm` (pools, buffers, formats,
validation, the pool/buffer lifetime rule) and the `wl_compositor`/`wl_surface` state machine
(attach, damage, frame, commit, destroy, regions stored and ignored), and the framework gained
its first code: a pixman renderer, a headless compositor that draws committed surfaces into an
in-memory target, `read-pixels`/`frame-pixel`, and a PNG writer. Phase 3a added `xdg-shell` v1
(`xdg_wm_base`, `xdg_surface`, `xdg_toplevel`) and the three `wl_surface` commit hooks a shell
role needs, so a real client can open a window; seats, input, the nested backend, tinywl and
`cl-umbra` are still their plan.

## 2. Packages

| Package | Nickname | Contents |
|---|---|---|
| `wayland.wire` | — | buffers, message codec, fd queue (pure: no sockets) |
| `wayland.ffi` | — | libc: socket pairs, `sendmsg`/`recvmsg` with `SCM_RIGHTS`, errno, `FD_CLOEXEC` |
| `wayland.io` | — | transport: flush an out buffer with its descriptors, pump a socket into whole messages |
| `wayland.protocol` | — | XML reader, schema objects (interfaces, messages, args, enums), signatures, interface registry, `define-*` forms |
| `wayland.codegen` | — | schema → Lisp source, one package per protocol |
| `wayland.asdf` | — | the `:wayland-protocol` component type (build time only) |
| `wayland.object` | — | object tables and the two id namespaces, shared by both ends (D19); destruction stays in each dispatch layer |
| `wayland.reactor` | — | epoll sources (level-triggered), timers, idles, posted commands, signalfd; `epoll.lisp` holds the packed-event syscall wrapper |
| `wayland.client` | `wl.client` | display, proxies, client ids, registry, roundtrip, event dispatch |
| `wayland.server` | `wl.server` | display, globals, resources, clients |
| `cl-compositor-framework` | `cf` | framework, one sub-package per module (`cf.backend`, `cf.scene`, …) |
| `tinywl` | — | the tutorial compositor |
| `umbra` | — | the daily-driver compositor |

Generated protocol symbols (`wl-surface`, `xdg-toplevel`, `+wl-surface-error-invalid-scale+`,
`wl-surface.attach`) live in a package named after the protocol (`WAYLAND`, `XDG-SHELL`),
created by the generated file, re-exported by the system that implements it.  Generated
sources are written to the ASDF output cache, never next to the XML. No package ever shadows a protocol name with a framework name:
framework objects carry their own prefix (`cf-surface`, `cf-output`).

## 3. Two kinds of object

This is the central design decision (D7), so it is worth being precise.

**Protocol objects** are generated classes, one per interface, holding exactly the state
the protocol defines:

```lisp
(defclass wl-surface (wl-resource)
  ((pending :initform (make-surface-state) :accessor pending)
   (current :initform (make-surface-state) :accessor current)
   (role     :initform nil :accessor role)
   (buffer-scale :initform 1 :accessor buffer-scale)
   ...))
```

**Framework objects** subclass them and add what the compositor needs to know:

```lisp
(defclass cf-surface (wl-surface)
  ((texture :initform nil :accessor texture)
   (mapped-p :initform nil :accessor mapped-p)
   (outputs  :initform ()  :accessor outputs)     ; which outputs it damaged
   (scene-node :initform nil :accessor scene-node)
   (frame-callbacks :initform '() :accessor frame-callbacks)))
```

When a client binds `wl_compositor` and calls `create_surface`, the server instantiates the
*resource class configured on the global* — `cf-surface` here, `wl-surface` in a transport-
only server. No vtable, no `void *impl`, no `wl_resource_set_implementation`. Overriding
behaviour for one surface is a class or a method, not a struct copy:

```lisp
(defclass my-video-surface (cf-surface) ((always-on-top :initform t)))
```

Roles are mixins rather than a `union` in `wlr_surface`:

```lisp
(defclass cf-toplevel (cf-surface) ((title ...) (app-id ...) (states ...)))
(defclass cf-popup    (cf-surface) ((parent ...) (positioner ...) (grab ...)))
(defclass cf-subsurface (cf-surface) ((parent ...) (synchronized-p ...) (sublayer ...)))
```

A role change (xdg-surface → toplevel) was planned as a class change (`change-class`), which
preserves the object identity that the client's object id refers to; in C, that same transition
is the source of a whole category of "role not yet set" crashes. Phase 3a did something
simpler and less clever (D26): the role is its own *resource* — `xdg_surface` owns the
configure handshake, `xdg_toplevel` owns the window state — and the `wl_surface` holds one link
(`surface-shell-surface`) that the commit path consults through three generic hooks with
do-nothing defaults. The `wl_surface` object never changes class, the client's id never moves,
and a bare surface (every phase-2a client) runs none of the role code. `change-class` stays on
the shelf until two roles genuinely share a class hierarchy worth changing into.

## 4. Dispatch

Three layers, from cheapest to most flexible:

1. **Opcode table** per interface class: a simple-vector of `(function . info)` built at
   class-finalization time. The decoder pulls `(object-id, opcode, args)` off the wire and
   jumps straight to the function.
2. **Generated handler functions**: `(defun wl-surface-attach (resource buffer x y) …)` with
   typed, declared arguments — no keyword parsing, no `apply`, no per-message consing.
3. **Generic functions** for extension: `cf:surface-committed`, `cf:on-new-toplevel`,
   `cf:on-key`. These are called *by* the generated handlers and are where user code and
   per-role mixins attach.

Hot path (pointer motion, key events, commits, frame callbacks) uses (1)+(2) only. Cold
paths (registry binds, output configuration, DnD) may use (3) freely.

Phase 1 dispatches through the generated generic function directly: look up the request by
opcode, decode the arguments, check that a method applies, apply it. That is layer 3's
mechanism on every message, which is fine at this phase's message volume (registry, bind,
sync and a handful of events) and is the honest starting point — the opcode table and typed
handler functions are phase-2 optimisations, to be added when there is a pointer-motion path
to measure. Both ends use the same shape, so a compositor's request method and a client's
event method are the same kind of thing.

Unknown opcode, opcode above the negotiated version, or a wrong argument count is a
protocol error, not a Lisp error.

## 5. Threading

```
┌──────────────────────── main thread ────────────────────────┐
│ reactor: epoll_wait → dispatch → flush → idle → timers      │
│ owns: display, clients, resources, scene, renderer, backends│
└───────────────────────────────▲─────────────────────────────┘
                                │ command queue (mutex) + eventfd wakeup
        ┌───────────────────────┴───────────────────┐
        │ control channel    │ child reaper        │  (any number)
        │ eval socket        │ waitpid loop        │
        └─────────────────────┴─────────────────────┘
```

Rules:

- Only the main thread touches protocol objects, the scene, or backends.
- Other threads submit closures with `(cf:enqueue (lambda () …))`; they run at the top of
  the next dispatch cycle, i.e. between messages, never inside one.
- `SIGCHLD` is handled via `signalfd` in the reactor; `waitpid(-1, WNOHANG)` in a loop.
- No thread is ever joined from the main loop; shutdown posts a stop command and drains.
- Rendering is synchronous with the main loop in phases 2-6. A dedicated render thread is
  explicitly *out of scope* until there is a measured reason (deferred decision).

## 6. Conditions and the debugger

Client-caused failures must never stop the compositor, and never open a debugger:

| Condition | Cause | Policy |
|---|---|---|
| `wl-protocol-error` | malformed message, bad id, version violation, invalid state | send `wl_display.error(object, code, text)`, flush, disconnect, log at `:warn` |
| `wl-connection-error` | EOF, EPIPE, ECONNRESET, failed fd transfer | drop the client, clean up resources, log at `:info` |
| `wl-resource-error` | invalid request for a resource's role/state | same as `wl-protocol-error` with a specific code |
| `cf-internal-error` | bug in our code | log full backtrace + display state dump; continue if the invariant permits, else clean shutdown with state written to disk |

Implemented with `handler-bind` around `dispatch-message` (so the stack is still available
for logging, and no unwinding crosses live protocol state) and `handler-case` at the reactor
boundary. `*debug-on-error*` defaults to `nil` in the dumped binary and `t` in the REPL.

Interactivity is preserved differently: attaching a REPL does **not** interrupt the main
thread. `(umbra:defer (lambda () …))` enqueues work; `(umbra:inspect-surface id)` reads a
consistent snapshot. A watchdog timer logs when a dispatch takes longer than 50 ms, which
is the diagnostic you actually want when a client "hangs".

## 7. Lifecycle and the GC

- **Protocol objects are not GC-managed.** They are reachable from the client's object
  table; destruction is explicit and reference-counted by the protocol, not by Lisp.
- **Foreign memory is never GC-managed.** mmap'd pools, dumb buffers, keymaps, textures:
  each has an owner object with an explicit `release`, plus a *safety-net* finalizer that
  logs loudly when it fires (because that means a leak path exists).
- `finalize` is used only as a leak detector, never for correctness: SBCL finalizers run on
  an arbitrary thread at an arbitrary time, which is exactly wrong for fds and GL objects.
- Client disconnect is a single code path: `(teardown-client client)`, idempotent, used by
  EOF, protocol error, and shutdown. It is the only thing allowed to free per-client state.
- `wl_display` shutdown order: stop accepting → disconnect clients → destroy globals →
  close backend → unmap all pools → release session → close sockets.

## 8. Hot reload

The point of writing this in Lisp. Constraints:

- Redefining a *method* or a *function* is always safe between dispatches.
- Redefining a *class* is safe only if the instance layout is compatible; SBCL will update
  instances lazily via `update-instance-for-redefined-class`. Convention: framework classes
  keep new slots at the end, with initforms, and protocol-generated classes are never
  redefined at runtime.
- Adding a global (protocol) at runtime is supported — `(cf:enable-protocol 'cf:layer-shell)`
  — and must send `wl_registry.global` to every client.
- Changing a backend's configuration (mode, scale, layout) goes through the same commit path
  as a normal reconfigure, so a bad reload cannot leave a half-applied output state.

## 9. Dependencies

| Dependency | Why | Notes |
|---|---|---|
| `cffi`, `cffi-grovel` | FFI to kernel/driver APIs | grovel extracts ioctl numbers and struct layouts from headers at build time |
| `alexandria` | the usual | |
| `closer-mop` | metaclass work in the codegen | |
| `plump` | XML parsing of protocol files | build time only |
| `static-vectors` | pinned, GC-safe byte vectors | optional; `sb-posix:mmap` covers most needs |
| `bordeaux-threads` | not used initially | revisit if threads spread |

Explicitly *not* dependencies: anything that wraps `libwayland`, any compositor toolkit,
any GUI framework, any JSON library or IPC framework (there is no IPC layer to feed — D14).

## 10. Naming conventions

- Protocol types: `wl-surface`, `xdg-toplevel`, `zwp-linux-dmabuf-v1` (interface name,
  lispified).
- Opcode constants: `+wl-surface.attach+`; enum values: `:buffer`, `:axis-vertical`.
- Request functions: `wl-surface.attach` (client side sends, server side handles).
- Events: keyword `:configure`, dispatched through `on-configure` generic functions.
- Framework: `cf-surface`, `cf-output`, `cf:render-frame`.
- Compositor policy: `umbra.layout:master`, `umbra.workspace:switch`.
- Predicates end in `-p`; `p`/`mapped-p` written out (`mapped-p`, not `mapped?`).

## 11. What is deliberately absent

| wlroots/libwayland concept | Why we do not have it |
|---|---|
| `struct wl_interface` + signature strings at runtime | schema is compiled into classes and tables; signature strings kept only for debug/parity dumps |
| `wl_list` intrusive lists | ordinary Lisp lists/vectors; ordering is explicit in the container |
| `wl_signal` + `wl_listener` | generic functions with `:before`/`:after`, `call-next-method` |
| implementation vtables | CLOS methods |
| `wl_resource_set_user_data` | slots on the subclass |
| `wlr_scene_node` opaque handles | classes you can subclass and inspect |
| a C ABI | not a goal; the API is Lisp-shaped (keyword args, conditions, multiple values) |
