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

Implementation status (phase 1, `cl-wayland-server`): the out buffer is batched and
watermarked — once it passes `+output-high-water-mark+` (64 KiB) the client's epoll interest
drops to write-only, so requests stop arriving and the buffer stops growing; draining it below
the mark restores read interest. Buffers still grow with doubling rather than being fixed
64 KiB rings, which stays a phase-0 leftover; the watermark, not the ring size, is what bounds
a hostile client today.
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
- Allocation strategy: **lowest free id**, on both ends, through `wayland.object` (D19). This
  is deliberately *not* what libwayland does — its client keeps a free list and hands out the
  most recently freed id first, which the C probe in `tests/c-client` shows plainly: a
  released id came back two allocations later, not on the next one. Which free id a client
  picks is invisible to the peer and unconstrained by the protocol (any unused id in range is
  legal), so this is a readability choice: ascending ids make a trace easier to follow. What
  clients *do* depend on is that an id is released at all — that `wl_display.delete_id`
  arrives when the object dies — and that part is required and tested.
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
| `define-request` / `define-event` | `+wl-surface-attach+` (opcode), the generic function `wl-surface.attach`, and `message-symbol` on the metadata |
| `define-enum` | one constant per entry, `+wl-surface-error-invalid-scale+` |

The generic function is the single handler for both directions: a compositor specialises it
as `(surface buffer x y)`, a client calls it the same way.  Argument types are explicit
(`:int`, `:object :interface "wl_buffer"`) rather than inferred from the interface
position, so a generated line says exactly what the wire says.

**`new_id` arguments are not parameters** (D15). The wire carries an id the sender chooses,
but neither side takes one from its caller: the dispatch layer allocates it, so a client
call returns the created proxy and a compositor method creates the resource:

```lisp
(wl-display.get-registry display)                  ; defgeneric wl-display.get-registry (object)
(wl-registry.bind registry 5 "wl_compositor" 3)    ; defgeneric wl-registry.bind (object name interface version)
```

Events keep every argument, including `new_id`, because there the sender picked the id and
the receiver has to learn it (`wl_data_device.data_offer`).

A message whose `since` exceeds 1 carries the version as a prefix in its signature
(`"3?oii"`), matching `wayland-scanner`;
`tests/unit/schema.lisp` checks every signature against it.

Message metadata records the generic function it became (`message-symbol`), so the client's
event dispatch can find a handler without re-deriving a symbol name. Messages parsed from
XML alone have no symbol: names come from the `define-*` forms, which is what the ASDF
component emits.

### 4.3 Two dispatch models, one schema

The generator emits both ends from the same metadata:

```
                     ┌──────────── schema (CLOS) ────────────┐
   define-interface  │  interface, version, requests, events │
   define-enum       │  arg types, allow-null, since, docs   │
                     └────────────┬──────────────┬───────────┘
                                  │              │
                  one generator ──┘              │
                  (wayland.codegen)              │
                                  │              │
        ┌─────────────────────────┴──────────────┴────────────────────────┐
        │  the same generated generic functions, specialised per direction │
        ├──────────────────────────────────┬───────────────────────────────┤
        │ wayland.client                   │ wayland.server                │
        │ • proxy class + object table     │ • resource class + object table│
        │ • id allocation / delete_id      │ • new_id validation, globals   │
        │ • request methods (send)         │ • request methods (handle)     │
        │ • event hooks + event methods    │ • event emitters (send)        │
        │ • version clamping on bind       │ • version gating               │
        └──────────────────────────────────┴───────────────────────────────┘
```

The two dispatch layers are hand-written because they differ where the protocol does not
say anything: what an id means, who allocates it, what happens to a destroyed object. The
schema-derived part — opcodes, argument types, signatures, the generic functions — is
generated once and shared. Both are now implemented; the identity half of the table below is
shared code (`wayland.object`, D19), and the difference is the direction.

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
when the XML changes, or when `wayland.schema`/`wayland.codegen` change: those are declared
as input files of the component (D16), because they determine the generated text just as
much as the XML does.

Generated code is ordinary Lisp compiled into the system: no runtime XML parsing in the
deployed binary, no reflection on the hot path.  `cl-wayland-protocols` is the system that
exists purely to prove and use this: it declares `wayland.xml` and stable `xdg-shell`.

## 5. Server semantics

```
wl_display (id 1)
 ├── wl_registry (per get_registry, may be several)
 ├── wl_callback (per sync)
 └── globals: wl_compositor, wl_output, …
```

Phase 1 implements this section in `cl-wayland-server`; the phase-2 content (surfaces, shm,
seats) is what the request methods will add, not what the transport changes.

- **Global registration** happens before the socket accepts clients when the display is
  built, or, if later, appends `wl_registry.global` events to every connected registry in
  registration order. Because events are appended as they are produced and `wl_callback.done`
  is queued when the batch ends, a client's next `sync` always completes after the
  announcements it is entitled to see. `remove-global` is the mirror image.
- **bind** validates: the name exists, the interface string matches the global's, the
  requested version is between 1 and the global's version inclusive, and (before the method
  runs) the client's `new_id` is in the client range and unused. It then instantiates the
  global's configured resource class, calls the global's bind function for initial events
  (e.g. `wl_output.geometry/mode/scale/name/description/done`), and returns. Each failure is
  `invalid_object` on the registry object.
- **Versioning** is per-resource: an event with `since > resource.version` is never sent —
  `send-event` drops it, so a compositor call site does not have to ask — and a request above
  the resource's version is `invalid_method`. `wl_output.done`, for instance, is version 2,
  so a version-1 output gets geometry and mode and nothing else.
- **`wl_display.sync`** creates a `wl_callback` with the id the client chose, queues it, and
  answers at the end of the batch: `wl_callback.done(0)`, then `wl_display.delete_id`, because
  the id was the client's. Not inside the request, or roundtrips would lose their meaning.
- **Errors**: `wl_display.error(object_id, code, message)`, flush, disconnect. Codes are
  `invalid_object` 0, `invalid_method` 1, `no_memory` 2, `implementation` 3. A request with no
  method specialised on the resource (anything phase 2 has not built yet) is
  `implementation`, which is the honest answer rather than silently ignoring it.
- **Failure policy** (D9, `docs/architecture.md` §6): a client-caused failure is the error
  event and a disconnect; EOF/EPIPE/ECONNRESET is an orderly teardown; a Lisp error in our
  own code is logged with a backtrace while the stack is live, reported as `implementation`,
  and also disconnects. None of them reaches the debugger.
- **Socket**: `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, default `wayland-0`; an absolute
  `WAYLAND_DISPLAY` is used as-is (nested and CI use, and how the tests run). A
  `<socket>.lock` file holds the server's pid, mode 0600, locked with `flock` for the
  server's lifetime (D20); the socket is mode 0700, so only this user can connect. Setup
  order is: take the lock, unlink a stale socket file, bind, listen, chmod. Teardown is the
  reverse: unlink the socket, release the lock, unlink the lock file. `SO_PEERCRED` gives
  pid/uid/gid at accept time; a peer whose uid is not ours is refused and closed immediately,
  and the credentials are kept for the log line.
- **Accepting** is budgeted: one readable event accepts at most
  `display-accept-budget` (default 16) connections, so a connect storm cannot starve the
  clients that are already connected. Level-triggered epoll brings the rest next cycle.
- **Teardown**: EOF, protocol error, or shutdown → one idempotent path that destroys
  resources in reverse creation order, closes the socket, closes descriptors that arrived but
  no message claimed, closes any descriptor queued in the out buffer that never went out, and
  removes the client from the display's list. It is the only function allowed to free
  per-client state.

## 6. Client semantics

Needed for the nested backend, for tests, and for tooling. Shaped like wayflan, so a wayflan
example ports with cosmetic changes. This is what `cl-wayland-client` implements:

```lisp
(with-open-display (display)                       ; WAYLAND_DISPLAY / $XDG_RUNTIME_DIR
  (let ((registry (wl-display.get-registry display)))
    (push (lambda (event &rest args)
            (ecase event (:global (destructuring-bind (name iface version) args …))))
          (proxy-hooks registry))
    (roundtrip display)))                           ; sync + dispatch until done
```

What exists:

- **Connect**: `WAYLAND_DISPLAY` may be a bare name under `$XDG_RUNTIME_DIR` or an absolute
  path; the default name is `wayland-0`. `connect` returns a `display`;
  `with-open-display` disconnects on the way out, error or not.
- **Proxies and ids** (D15): `display` is a subclass of `proxy` with id 1. Ids are allocated
  from 2 upward, returned to a free list on `wl_display.delete_id`, and a request on a
  destroyed proxy signals `destroyed-proxy` instead of sending a message the server would
  reject.
- **Requests** are methods on the generated generic functions: `wl-display.get-registry`,
  `wl-display.sync`, `wl-registry.bind` (four wire arguments, version clamped to what the
  loaded schema knows). Everything else arrives with the protocols the client declares.
- **Events** reach hooks — `(push (lambda (event &rest args) …) (proxy-hooks proxy))`, with
  `event` a keyword such as `:global` — and, independently, methods specialised on the
  generated event function (`(defmethod wl-registry.global ((registry my-registry) name
  interface version) …)`), which is how one interface gets behaviour. The connection layer
  keeps three events to itself: `wl_display.error` signals `display-error`,
  `wl_display.delete_id` frees the id, `wl_callback.done` completes a roundtrip.
- **Flushing** is batched: requests accumulate in one buffer and are written by `flush`,
  which is called by the reactor's writable callback when the socket was full. `roundtrip`
  flushes before and after, so a hook can queue requests and be understood.
- **Roundtrip** sends `sync` and dispatches until that callback's `done` arrives, with a
  deadline (`roundtrip-timeout`); `dispatch` never blocks past its timeout.

Differences from libwayland that matter: no manual proxy destruction for GC'd objects, no
toplevel-only callbacks, enums as keywords, `handler-case` instead of error codes, and one
table of objects per connection instead of per-proxy vtables.

Not yet: receiving descriptors into typed arguments for real protocols (the transport handles
fds; no client-side protocol in phase 0 declares one), `wl_registry.bind` for protocols the
system does not declare, and any notion of a client-side "destroy" request that is not
`wl_display.delete_id`.

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
- Signals, with one measured amendment (D21): `signalfd` only sees a process-directed signal
  if every thread blocks it, and an implementation brings threads of its own — SBCL creates a
  finalizer thread, and a `SIGTERM` sent to the demo server landed there and never reached
  the descriptor. So termination signals go through `wayland.reactor:add-signal-handler`,
  which installs the implementation's interrupt handler and does nothing there but post a
  command; the command runs inside a cycle, between messages. `add-signal-source` stays for
  signals whose blocking we control from the start of the image (`SIGUSR1` for VT switch,
  `SIGCHLD` for children in phase 6) and for implementations without extra threads.
  `SIGPIPE` is ignored and sends use `MSG_NOSIGNAL`; the per-client `SIGBUS` risk is discussed
  in `memory-and-rendering.md` §4.
- A watchdog logs when a cycle exceeds 50 ms, with the offending client and message.

## 8. Mimicking libwayland where the spec is silent

The spec does not define: id allocation order, `delete_id` timing, seat capability update
timing, keyboard `repeat_info` placement, whether an initial `xdg_toplevel` configure is
0×0, shm format list order, output geometry strings, or how grab serials interact. Clients
(and their test suites) do depend on these. wayflan's stance — "good-faith effort to mimic
libwayland for behaviour not defined in the spec" — is adopted here without reservation:

| Undefined behaviour | Our choice |
|---|---|
| id allocation | lowest free id here; libwayland reuses most-recently-freed first. Unobservable to the peer, so this is a trace-readability choice, not mimicry |
| `delete_id` | emitted when the destructor request is processed, before reuse |
| `wl_shm.format` | sent immediately on bind, all supported formats |
| `wl_seat.capabilities` | on bind, and on every device add/remove |
| `wl_keyboard.keymap` → `repeat_info` | keymap first, then repeat info |
| `wl_output` | geometry, mode, scale, then name/description (v4), then `done` last |
| `wl_registry.bind` arguments | XML says `(name, id)`; the wire carries `(name, interface-string, version, id)`, signature `"usun"`, because the server needs the interface to instantiate |
| client id allocation | the client picks 2 upward and reclaims an id only after `wl_display.delete_id` (D15); a client that ignores `delete_id` runs out at `0xFEFFFFFF` and is told so |
| `new_id` in a request | allocated by the sender's dispatch layer before the message is encoded; the generic function returns the created object instead of taking an id |
| `wl_display.error` | signals a Lisp condition (`display-error`); the connection is finished, as in libwayland, rather than left half-usable |
| event to an unknown object | refused (`unknown-object`), not ignored: an event for an object we do not have is a protocol mismatch worth seeing |
| initial `xdg_toplevel.configure` | size 0×0, states empty, before first buffer commit |
| `xdg_surface.configure` | only after the initial commit |
| `wl_pointer.frame` | one frame per input event batch, always last |

Regression protection: recorded `WAYLAND_DEBUG=1` traces from a real compositor (sway or
weston) are replayed against our decoder, and our encoder's output is diffed against a
libwayland client's trace for the same interaction.

## 9. Robustness checklist

Every item is a test, not an aspiration.

- [x] Message size not a multiple of 4 → error, no allocation (wire decoder)
- [x] Message size < 8 or > cap → error
- [x] Object id unknown / already destroyed → `invalid_object` (server dispatch)
- [x] Request opcode above resource version → `invalid_method`
- [x] Wrong argument types (e.g. string with absurd length) → error before reading
- [x] `new_id` already in use, or outside the client range → `invalid_object`
- [ ] fd count mismatch (missing or surplus) → close fds, error — missing is done; surplus
      still needs per-message descriptor counts from the schema
- [x] `SCM_RIGHTS` with more than 28 fds → error, close all
- [x] Client writes 1 byte then stalls → no blocking, no unbounded buffer
- [x] Client never reads → interest drops to write-only above a 64 KiB watermark, no growth
- [x] Client disconnects mid-message → resources freed, no crash, no fd leak
- [x] 10k connect/disconnect cycles → flat RSS and fd count (`scripts/soak.sh`)
- [x] Fuzz: random buffers via `socketpair`, 10⁶ iterations, no crash/hang/leak (decoder and
      transport)
- [x] Fuzz the peer: 10⁶ adversarial connections to a live server, no crash/wedge/leak and no
      malformed reply (`scripts/fuzz-client.sh`)

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
