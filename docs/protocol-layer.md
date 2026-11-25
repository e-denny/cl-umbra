# The protocol layer

`cl-wayland-core`, `cl-wayland-client`, `cl-wayland-server`. This is the layer that replaces
libwayland, so it has to be right in the boring ways: byte-exact framing, exact semantics for
object lifetime, exact ordering of events.

---

## 1. Wire format

A connection is a Unix stream socket carrying a sequence of messages:

```
 offset 0            u32   object id
 offset 4            u32   (size << 16) | opcode
 offset 8            …     arguments, in the order the interface declares them
```

- `size` includes the 8-byte header, is a multiple of 4, and is at least 8.
- `opcode` is the index of the request/event within its interface, from 0.
- **Byte order is the host's.** Wayland is local-only, so libwayland writes native
  endianness; we do the same and assert at build time that both ends agree (which they do
  by construction). No byte swapping anywhere.
- The object id determines the interface (via the object table), which determines whether
  the opcode means a request or an event and what its signature is.
- A message larger than 4 KiB is legal (arrays can be large). We cap inbound messages at
  a configurable 64 KiB and treat larger as a protocol error.
- That cap is a policy limit, not the format's: the size field is 16 bits and sizes are
  multiples of 4, so **65532 octets is the largest message that can exist at all**. The
  cap stays configurable so a server can tighten it per connection.

### Argument encoding

| Type | Lisp | Encoding | Size |
|---|---|---|---|
| `int` | `(signed-byte 32)` | i32 | 4 |
| `uint` | `(unsigned-byte 32)` | u32 | 4 |
| `fixed` | `rational` (or exact `double` at the API edge) | i32, signed 24.8 | 4 |
| `string` | `string` or `nil` | u32 length **including** the NUL, bytes, NUL, pad to 4 | 4 + pad4(len+1) |
| `object` | protocol object or `nil` | u32 id, 0 = null | 4 |
| `new_id` | protocol object | u32 id | 4 |
| `array` | `(simple-array (unsigned-byte 8))` | u32 byte length, bytes, pad to 4 | 4 + pad4(len) |
| `fd` | fd (fixnum) or `nil` | u32 placeholder (0), fd in `SCM_RIGHTS` ancillary data | 4 |

Signatures (`"o?n"`, `"2a"`) are generated and kept, but only for debug dumps and for
validating our own tables against `wayland-scanner` output. The runtime uses typed slots and
generated readers, never signature-string parsing.

### File descriptors

fds do not live in the byte stream. Each `fd` argument occupies a 4-byte slot in the message
body (for alignment and size accounting) and is delivered as one `int` of `SCM_RIGHTS`
ancillary data, in argument order across all messages in the same `sendmsg`.

Constraints that shape the implementation:

- **28 fds per flush.** libwayland reserves a 128-byte cmsg buffer, which holds at most 28
  `int`s, and flushes whenever the fd queue is full. We use the same ceiling so our batching
  behaviour matches, and so a client that assumes one-fd-per-message keeps working.
- `MSG_CMSG_CLOEXEC` on receive, so client fds never leak into compositor children.
- `MSG_CTRUNC` means we lost fds we can no longer clean up: log loudly and drop the client.
- An fd arriving when the message we decoded declares none, or a declared fd missing, is a
  protocol error. Leaked fds are closed; surplus fds are closed.
- Our own fds for shm (memfd) and keymaps are created with `MFD_CLOEXEC`.

## 2. Buffers and I/O

Per connection (implementation: `wayland.io`, with `wayland.wire` holding the
octets and `wayland.ffi` making the syscalls):

- **In buffer**: a 64 KiB ring. `recvmsg` fills it; the decoder walks complete messages;
  partial tails stay. If a message does not fit, the buffer grows once, then errors.
- **Out buffer**: a 64 KiB ring plus an fd queue. Messages are appended without flushing;
  flush happens once per reactor cycle per client, using `writev` over the ring's
  contiguous segments.
- **Backpressure**: if a client's out buffer passes a high watermark, we (a) stop the
  compositor from queueing new non-critical events to it, and (b) if it is still full after
  draining, disable its `EPOLLIN` interest until flush succeeds. libwayland behaves
  similarly; clients that never read must not be able to make us grow memory.
- Writes are non-blocking. `EAGAIN` re-arms `EPOLLOUT`; `EPIPE`/`ECONNRESET` disconnects.

## 3. Identifiers

- Object id 1 is always `wl_display`, on both ends, in every connection.
- Client-allocated ids: `2 .. 0xFEFFFFFF`. The client picks them; the server only records.
- Server-allocated ids: `0xFF000000 .. 0xFFFFFFFF`. Used for objects the server creates
  without a client-supplied `new_id` (`wl_data_offer`, `wl_callback` for some paths,
  keyboard/pointer/touch objects — those *are* server-created).
- **Freeing**: when a client-owned object is destroyed, the server sends
  `wl_display.delete_id(id)`; the id becomes reusable. Server-owned objects are destroyed by
  the server emitting their destructor event (or handling their destructor request) and no
  `delete_id` follows, because the id was never the client's to reuse.
- Allocation strategy mimics libwayland: lowest free id, so traces look familiar.
- `delete_id` must be emitted before any event that reuses the id, and after the destructor
  request has been fully processed.
- Serials are a per-display monotonic u32, bumped for every serial-bearing action
  (selection, pointer enter/button, xdg_popup grab, activation token). Clients echo them
  back; we validate them against per-client/per-surface rings, not a global set.

## 4. Schema and code generation

### 4.1 Schema

`wayland.protocol` parses XML into CLOS metadata, closely following wayflan's model (which
is well-tested): `wl-protocol` → `wl-interface` → `wl-request`/`wl-event` → `wl-arg`, plus
`wl-enum`/`wl-entry`. Descriptions are kept and attached as docstrings — free documentation
in the REPL.

### 4.2 Generated forms

One package per protocol (`WAYLAND`, `XDG-SHELL`, `WLR-LAYER-SHELL-UNSTABLE-V1`), holding
every symbol the protocol defines:

```lisp
(define-interface wl-surface
    (:version 7)
    (:wire-name "wl_surface")
    (:documentation "An onscreen surface…"))

(define-enum wl-surface.error ()
  (invalid-scale 0 :summary "buffer scale must be positive")
  (invalid-transform 1 :summary "…"))

(define-request (wl-surface.attach wl-surface 1)
    ((buffer :object :interface "wl_buffer" :allow-null t)
     (x :int)
     (y :int))
  (:documentation "…"))

(define-event (wl-surface.enter wl-surface 0)
    ((output :object :interface "wl_output")))
```

Each form defines names, not just metadata:

| Form | Defines |
|---|---|
| `define-interface` | `+wl-surface-version+` |
| `define-request` / `define-event` | `+wl-surface-attach+` (opcode) and the generic function `wl-surface.attach` |
| `define-enum` | one constant per entry, `+wl-surface-error-invalid-scale+` |

The generic function is the single handler for both directions: a compositor specialises it
as `(surface buffer x y)`, a client calls it the same way.  Argument types are explicit
(`:int`, `:object :interface "wl_buffer"`) rather than inferred from the interface
position, so a generated line says exactly what the wire says.

A message whose `since` exceeds 1 carries the version as a prefix in its signature
(`"3?oii"`), matching `wayland-scanner`;
`tests/unit/schema.lisp` checks every signature against it.

### 4.3 Two dispatch models, one schema

The generator emits both ends from the same metadata:

```
                     ┌──────────── schema (CLOS) ────────────┐
   define-interface  │  interface, version, requests, events │
   define-enum       │  arg types, allow-null, since, docs   │
                     └────────────┬──────────────┬───────────┘
                                  │              │
             server codegen ──────┘              └────── client codegen
             • resource class                     • proxy class
             • opcode table + handler fns          • build-message fns
             • event emitters (send)               • event dispatch table
             • version gating                      • new_id allocation
```

### 4.4 ASDF component

```lisp
(defsystem "umbra"
  :defsystem-depends-on ("cl-wayland-asdf")
  :depends-on ("cl-wayland-core")
  :components ((:module "protocols"
                :pathname "../protocols/"
                :components ((:wayland-protocol "wayland/wayland" :export t)
                             (:wayland-protocol "wlr-protocols/unstable/…")))))
```

The component is a `CL-SOURCE-FILE` whose source is XML: `source-file-type` says `xml`, and
`perform` on `compile-op` parses the file, writes `<name>.lisp` into the ASDF output cache,
and compiles it to exactly the fasl ASDF expects.  `load-op` is inherited.  Rebuild happens
when the XML changes, and only then.

Generated code is ordinary Lisp compiled into the system: no runtime XML parsing in the
deployed binary, no reflection on the hot path.  `cl-wayland-protocols` is the system that
exists purely to prove and use this: it declares `wayland.xml` and stable `xdg-shell`.

## 5. Server semantics

```
wl_display (id 1)
 ├── wl_registry (per client, on get_registry)
 ├── wl_callback (per sync)
 └── globals: wl_compositor, wl_shm, wl_seat, wl_output, xdg_wm_base, …
```

- **Global registration** happens before the socket accepts clients, or, if later, appends
  `wl_registry.global` events to every connected registry in a defined order (and the
  client's next `sync` completes after all of them).
- **bind** validates: name exists, interface string matches, requested version is between 1
  and the global's version, and the client's `new_id` is unused. It then instantiates the
  global's configured resource class, sends initial events (e.g. `wl_shm.format`,
  `wl_seat.capabilities`, `wl_output.geometry/mode/scale/name/description/done`), and
  returns.
- **Versioning** is per-resource: an event with `since > resource.version` is never sent;
  a request above the resource version is a protocol error. The generated code enforces
  both, so version bugs are compile-time visible in the interface table rather than at
  runtime.
- **`wl_display.sync`** creates a `wl_callback` and emits `done` after the current batch of
  requests is processed — not immediately, or roundtrips lose their meaning.
- **Errors**: `wl_display.error(object_id, code, message)`, flush, disconnect. Codes are the
  protocol's own where defined; `wl_display.error` has `invalid-object`, `invalid-method`,
  `no-memory`, and `implementation` (an internal error we are reporting rather than
  hiding).
- **Socket**: `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, default `wayland-0`; a `wayland-0.lock`
  file with pid holds it; `WAYLAND_DISPLAY` may be an absolute path (nested/CI use case).
  Permissions 0700 socket, 0600 lock. `SO_PEERCRED` gives pid/uid/gid, kept for policy and
  logging, and validated against the socket's owner.
- **Teardown**: EOF, protocol error, or shutdown → one idempotent path that destroys
  resources in reverse creation order, unmaps pools, closes fds, kills spawned children,
  removes the client from every seat/focus/scene, and logs with the peer pid.

## 6. Client semantics

Needed for the nested backend, for tests, and for tooling. Shaped like wayflan so existing
wayflan examples port with cosmetic changes:

```lisp
(with-open-display (display)
  (let ((registry (wl-display.get-registry display)))
    (push (lambda (event &rest args)
            (ecase event (:global (destructuring-bind (name iface version) args …))))
          (wl-proxy-hooks registry))
    (wl-display-roundtrip display)))
```

Differences from libwayland that matter: no manual proxy destruction for GC'd objects, no
toplevel-only callbacks, enums as keywords, `handler-case` instead of error codes.

A roundtrip is: send `sync`, dispatch until that callback's `done` arrives, with a deadline.
A dispatch never blocks indefinitely when a deadline is supplied.

## 7. The reactor

```
                 ┌────────────── epoll ──────────────┐
                 │ epfd                              │
                 │  display listener   (accept)       │
                 │  per-client fd      (EPOLLIN/OUT)  │
                 │  drm fd             (vblank)       │
                 │  libinput fd        (input)        │
                 │  seat fd            (VT switch)    │
                 │  timerfd            (frame/anim)   │
                 │  signalfd           (CHLD/TERM/USR1)│
                 │  eventfd            (wakeups)      │
                 └───────────────────────────────────┘
```

Cycle:

1. run queued commands (from other threads)
2. dispatch already-buffered messages, oldest client first (fairness: round-robin)
3. flush all clients (batched `writev`), then re-enable reads
4. run idle callbacks
5. compute timeout = nearest timer (frame pacing, animation, watchdog)
6. `epoll_wait`, handle events, goto 1

Steps 2 and 3 become descriptors: the connection layer registers each client's
socket as a source whose readable callback pumps and dispatches; the reactor
itself only orders commands, descriptors, timers and idles.  That order is
implemented in `wayland.reactor` (`run-once`) and is a tested contract, not a
convention.

Details that are easy to get wrong and are therefore tested explicitly:

- Level-triggered epoll; always read until `EAGAIN`, then re-arm.
- A message may arrive split across `recvmsg` calls; a message may contain several.
- Dispatch must be re-entrant-safe: a handler may send events (append to out buffer) but may
  not call back into the reactor.
- Timers never fire late because a client flooded us: the loop budget per cycle is bounded
  (e.g. 16 ms of dispatch) and the remainder is deferred with a wakeup.
- `signalfd` for `SIGTERM`/`SIGINT`/`SIGUSR1` (VT switch), `SIGCHLD` for children; `SIGPIPE`
  ignored; per-client `SIGBUS` risk is discussed in `memory-and-rendering.md` §4.
- A watchdog logs when a cycle exceeds 50 ms, with the offending client and message.

## 8. Mimicking libwayland where the spec is silent

The spec does not define: id allocation order, `delete_id` timing, seat capability update
timing, keyboard `repeat_info` placement, whether an initial `xdg_toplevel` configure is
0×0, shm format list order, output geometry strings, or how grab serials interact. Clients
(and their test suites) do depend on these. wayflan's stance — "good-faith effort to mimic
libwayland for behaviour not defined in the spec" — is adopted here without reservation:

| Undefined behaviour | Our choice |
|---|---|
| id allocation | lowest free id |
| `delete_id` | emitted when the destructor request is processed, before reuse |
| `wl_shm.format` | sent immediately on bind, all supported formats |
| `wl_seat.capabilities` | on bind, and on every device add/remove |
| `wl_keyboard.keymap` → `repeat_info` | keymap first, then repeat info |
| `wl_output` | geometry, mode, scale, then name/description (v4), then `done` last |
| `wl_registry.bind` arguments | XML says `(name, id)`; the wire carries `(name, interface-string, version, id)`, signature `"usun"`, because the server needs the interface to instantiate |
| initial `xdg_toplevel.configure` | size 0×0, states empty, before first buffer commit |
| `xdg_surface.configure` | only after the initial commit |
| `wl_pointer.frame` | one frame per input event batch, always last |

Regression protection: recorded `WAYLAND_DEBUG=1` traces from a real compositor (sway or
weston) are replayed against our decoder, and our encoder's output is diffed against a
libwayland client's trace for the same interaction.

## 9. Robustness checklist

Every item is a test, not an aspiration.

- [ ] Message size not a multiple of 4 → error, no allocation
- [ ] Message size < 8 or > cap → error
- [ ] Object id unknown / already destroyed → `invalid-object`
- [ ] Request opcode above resource version → error
- [ ] Wrong argument types (e.g. string with absurd length) → error before reading
- [ ] `new_id` already in use → error
- [ ] fd count mismatch (missing or surplus) → close fds, error
- [ ] `SCM_RIGHTS` with more than 28 fds → error, close all
- [ ] Client writes 1 byte then stalls → no blocking, no unbounded buffer
- [ ] Client never reads → out buffer capped, `EPOLLIN` disabled, no growth
- [ ] Client disconnects mid-message → resources freed, no crash, no fd leak
- [ ] 10k connect/disconnect cycles → flat RSS and fd count
- [ ] Fuzz: random buffers via `socketpair`, 10⁶ iterations, no crash/hang/leak

## 10. Performance targets

Measured with `tests/perf/`, on the development machine:

| Metric | Target |
|---|---|
| encode small message (attach, motion) | < 150 ns |
| decode + dispatch small message | < 1 µs |
| bytes consed per pointer-motion round | 0 |
| 10k messages/s sustained, one client | < 2 % CPU |
| 100 clients, idle | flat CPU, flat memory |
| roundtrip latency (`sync`) | < 200 µs within the compositor's own loop |

Techniques: typed decode straight from the ring into declared locals; `dynamic-extent` arg
vectors; no `apply`; no generic dispatch on opcode; preallocated event state per resource;
`writev` batching; avoid `format` at `:debug` level only; log level checked before argument
construction.
