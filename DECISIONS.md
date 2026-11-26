# Decision log

ADR-style. Newest decisions at the bottom. A decision is only "accepted" once its
consequences show up in `PLAN.md` or `docs/`.

---

## D1 — Implement the Wayland protocol from scratch, not around libwayland

**Status:** accepted

**Context.** `wayflan` demonstrates that a from-scratch client is not only possible but
nicer to use from Lisp: no per-proxy manual allocation, no toplevel-only C callbacks,
enums as keywords, hot-redefinable behaviour. All of that applies double to a *server*,
where libwayland forces an opaque `wl_resource`/vtable model.

**Decision.** `cl-wayland-core`, `-server` and `-client` implement the wire format,
object model and event loop in Lisp. No linkage to `libwayland-*`.

**Consequences.** We own protocol conformance and all the edge cases libwayland papers
over. Mitigation: mirror libwayland's undocumented behaviour deliberately (see
`docs/protocol-layer.md` §9), and run an interop matrix against real clients from day one.
We gain: real objects (not proxies to C structs), subclassing instead of vtables,
condition-based errors, and live redefinition.

---

## D2 — `cl-compositor-framework` is a Lisp framework, not CFFI over wlroots

**Status:** accepted (user requirement)

**Context.** The convenience wlroots provides — backends, output lifecycle, renderer,
scene graph, seat/focus, shell protocol implementations — is exactly what a compositor
author needs. But binding to wlroots would import wlroots' C object model, its opaque
structs, `wl_list`, and its signal/listener boilerplate into Lisp, and would make the
"from scratch" work in D1 pointless.

**Decision.** Reimplement that layer in Lisp. Borrow wlroots' *decomposition* (the
module boundaries that are known to work), not its code or ABI. Naming: `cl-compositor-framework`.

**Consequences.** This is the largest single piece of work in the project (est. 20-35k
lines). It is also where Lisp pays off most: generic functions replace signal/listener
plumbing, CLOS subclassing replaces vtables, `:before`/`:after` methods replace
`wl_listener` stacks, and the whole layer is hot-reloadable.

---

## D3 — shm-first: `wl_shm` is the primary buffer path and the reference renderer is CPU/pixman

**Status:** accepted (user requirement)

**Context.** `wl_shm` is mandatory for every client, needs no GPU, and gives the
compositor a plain mmap'd window of pixels. wlroots treats it as the fallback path
behind dmabuf; that ordering drags in EGL, GBM, modifiers and explicit sync before
anything works.

**Decision.** Build `wl_shm` pools/buffers first and completely (memfd, mmap, format
table, validation, release). Implement the renderer interface with a **pixman** backend
as the reference implementation. Render targets are shm-backed (headless/nested) or
dumb-buffer-backed (DRM). GLES2/GBM/dmabuf arrive later behind the same interface.

**Consequences.** A fully functional real-hardware compositor with **zero** EGL/GL/GBM
dependency (dumb buffers + page flips). Golden-image tests run on any machine, including
CI without a GPU. Cost: CPU compositing caps throughput — acceptable at 1080p, tight at
4K with many overlapping windows and blur; the mitigation ladder is documented in
`docs/memory-and-rendering.md` §7.

---

## D4 — CFFI first; Rust shim only as a last resort, as a leaf

**Status:** accepted (user requirement)

**Context.** Some kernel/driver paths are painful through CFFI: atomic KMS property
blobs, DRM syncobj/fences, EGL extension loading, va_list-shaped APIs, struct-by-value
returns. The user prefers a Rust shim over C when one is needed.

**Decision.** Everything is CFFI until a specific, documented path is proven hostile.
Any shim is: Rust, `cdylib`, plain C ABI, POD structs + fds only, versioned, no state
machine, no Wayland knowledge, and optional at build time. A Lisp fallback must exist
for every shim function or the shim must be confined to a phase-gated feature.

**Consequences.** No shim is required for phases 0-4 (protocol, shm, pixman, dumb-buffer
DRM, libinput). Candidate shim territory: explicit sync (phase 7), HDR metadata blobs
(phase 7), and possibly atomic-commit batching (phase 5).

---

## D5 — Project naming: `cl-*` family, framework named `cl-compositor-framework`

**Status:** accepted (user requirement)

**Context.** A `cl-wayland` name already belongs to Malcolm Still's libwayland binding,
and calling the framework `cl-wlroots` implies a binding.

**Decision.** Umbrella repo `cl-wayland-project`; systems `cl-wayland-core`,
`cl-wayland-client`, `cl-wayland-server`, `cl-compositor-framework`, `cl-tinywl`,
`cl-umbra`. Lisp packages: `wayland.wire`, `wayland.protocol`, `wayland.server`,
`wayland.client`, `cf` (nickname for `cl-compositor-framework`), `umbra`.

---

## D6 — Protocol definitions come from XML at build time, via an ASDF component

**Status:** accepted

**Context.** wayflan's best idea: `:wayflan-client-impl` teaches ASDF to compile a
protocol XML file into Lisp forms, so adding a protocol needs no build-system surgery.
Hand-written protocol bindings rot; generated ones track `wayland-protocols` releases.

**Decision.** Vendor `wayland.xml`, `wayland-protocols/*`, `wlr-protocols/*` and our own
`umbra-*.xml` under `protocols/`. Provide an ASDF component type that turns any of them
into interface classes, enum keywords, opcode constants, dispatch tables and
documentation strings. Generated code is *metadata-driven with static fast paths*: a
runtime generic marshaller exists for protocols loaded after boot, but hot paths
(pointer, keyboard, frame callbacks, commits) compile to direct setters/readers.

**Consequences.** Regenerating on a protocol bump is a recompile. Load-time cost is
bounded by only generating protocols a system declares it implements.

---

## D7 — CLOS subclassing instead of C vtables; generic functions instead of signal/listener

**Status:** accepted

**Context.** libwayland server objects carry an implementation vtable of function
pointers; wlroots adds `wl_listener` structs wired to `wl_signal`. Both are C's answer to
"let the user override behaviour". CLOS does this natively.

**Decision.** The generated `wl-surface`, `wl-output`, `wl-seat` classes are *subclassed*
by the framework (`cf-surface`, `cf-output`, `cf-seat`), whose slots hold compositor
state and whose `handle-request`/event methods hold behaviour. Framework events are
generic functions with `:before`/`:after`/`:around` methods.

**Consequences.** Per-object overriding, per-role mixins, and live method redefinition
come free; the usual "listener bookkeeping" and "did I remove the listener" class of bugs
disappears. Dispatch through generic functions must stay off the per-event hot path —
see `docs/protocol-layer.md` §6 for the opcode-table design.

---

## D8 — One protocol description, two directions

**Status:** accepted

**Context.** A compositor needs both ends: the server end, and a client end for the
nested backend, for tests, and for tooling (control-channel scripts, a session locker).

**Decision.** `cl-wayland-core` generates metadata once; `cl-wayland-client` and
`cl-wayland-server` consume it. `cl-wayland-client` is API-compatible in spirit with
wayflan (so wayflan examples port easily) but shares our objects, reactor and schema.

**Consequences.** Bugs found in one direction inform the other; the nested backend is
also a permanent conformance test for the server.

---

## D9 — Single-threaded protocol loop, with a supervised command channel

**Status:** accepted

**Context.** Wayland state is per-client and order-sensitive. A lock-free multi-threaded
compositor is a research project; also, an SBCL debugger prompt in the main loop freezes
every client, which is a bad first impression.

**Decision.** One thread owns the display, clients, scene and backends. Other threads
(control channel, REPL helpers, child-process reaping) submit work through a command queue
that wakes the loop via `eventfd`. Protocol errors from clients never enter the debugger: they post
`wl_display.error` and disconnect. Internal bugs are logged, and the compositor attempts
to keep running (configurable to abort).

**Consequences.** Input latency and frame timing stay predictable. Hot-reload works
because redefinition happens *between* dispatches, not inside them.

---

## D10 — `cl-umbra` targets daily-driver parity, not Umbriel's eye candy

**Status:** accepted (user requirement)

**Context.** Umbriel = wlroots + SceneFX fork: scrolling/dwindle/master/stacking layouts,
per-output workspaces, rules, blur, shadows, animations, HDR, VRR, explicit sync,
Xwayland, IPC, live-reloaded TOML.

**Decision.** v1 ("daily driver, no eye candy") = xdg-shell + layer-shell, master and
scrolling layouts, per-output workspaces, keybinds, config file, live control, screenshots, session
lock, clipboard/DnD, fractional-scale, cursor-shape, xdg-activation. Effects/HDR/VRR/
explicit sync/Xwayland are phase 7, not v1 gates.

**Consequences.** v1 is reachable. The scene graph and renderer are designed with effects
in mind (retained tree, damage, offscreen passes) so phase 7 does not require a rewrite.

---

## D11 — Config is s-expressions; no TOML

**Status:** accepted (user requirement)

**Context.** Umbriel uses live-reloaded TOML because its users expect it. In Lisp, an
s-expression config is read by `read`, validated as data, macro-expandable, and can *be*
code: keybinds can call named commands, layouts can be parameterised. TOML would mean a
parser dependency and a second configuration language underneath the first.

**Decision.** `~/.config/umbra/init.lisp` is the canonical config. It is a list of
declarative sections (`output`, `layout`, `bind`, `device`, `rule`, `layer-rule`, `startup`,
`env`), read with `*read-eval*` bound to `nil` in a dedicated package, validated against a
per-section schema, and applied atomically with rollback. Keybindings reference *registered
commands* (with data arguments), not arbitrary evaluation. Arbitrary Lisp in the config is
available only behind an explicit `(enable-lisp-config)` opt-in.

Design details in [`docs/config-and-control.md`](docs/config-and-control.md).

**Consequences.** No TOML parser; config is inspectable (`(umbra:current-config)`),
diffable, and reloadable with precise diagnostics (line numbers, unknown keys, range
errors). The REPL and the config speak the same language. Umbriel users need a translation
table; a TOML compatibility reader is explicitly **not** planned, because it would
reintroduce the second language. Security posture: a config file is trusted input from the
user's own home directory, but it is still read as data by default, so a stray paste cannot
execute code.

---

## D12 — Xwayland via `xwayland-satellite`, not an embedded XWM

**Status:** accepted (user requirement)

**Context.** wlroots' `xwayland` module (XWM, selection bridge, window→surface mapping) is
thousands of lines and the least pleasant code in the tree. `xwayland-satellite` is a
separate rootless Xwayland integration that acts as both a Wayland client and an X server
for the compositor.

Its actual requirements were checked against the project's README, not assumed:

- **Must have:** core interfaces (`wl_compositor`, `wl_surface`, `wl_output`), `xdg-shell`,
  and `wp_viewporter` (used for scaling).
- **Optional, improved with:** `linux-dmabuf`, `xdg-activation`, `xdg-decoration`,
  `xdg-foreign`, `pointer-constraints`, `primary-selection`, `tablet`, fractional scale.
- **Not required:** `wlr-layer-shell`, `wlr-foreign-toplevel`, `xwayland-shell`, or any
  compositor-internal XWM.

**Decision.** Defer X to phase 6/7 and support `xwayland-satellite` as a supervised child
process. On-demand activation uses its `-listenfd` mode (spawn with a display number and a
listening fd, as niri does); otherwise it starts after compositor init and X clients get
`DISPLAY` pointing at it. No X protocol code, no XWM, no X selection bridge in `cl-umbra`.

**Consequences.** The Xwayland cost collapses from "thousands of lines" to "spawn and
supervise a process", because we implement `xdg-shell` and `viewporter` anyway. X clipboard
and X window management are satellite's problem. The `xwayland-shell` protocol is not
needed. Risk moves to process supervision and to satellite's optional-protocol wishes,
which are phase 6-7 items regardless. Cost of reversal: low — replacing a child process
with an in-process XWM later would not change the rest of the compositor.

---

## D13 — License: GPL-3.0-or-later for everything

**Status:** accepted (user requirement)

**Context.** The project was initially drafted as MIT. The user wants copyleft instead, so a
compositor built on this framework cannot be closed. Version and scope were decided
explicitly: GPL-3 (not 2) because it is compatible with Apache-2.0 code, carries an express
patent grant and anti-tivoization terms, and is what river, niri and dwl use; "or later" so
the project can move to a future GPL version without tracking down every contributor.

**Decision.** GPL-3.0-or-later for **all** systems — `cl-wayland-core`, `cl-wayland-client`,
`cl-wayland-server`, `cl-compositor-framework`, `cl-tinywl`, `cl-umbra` — plus the
documentation in `docs/`. One `LICENSE` at the repository root (the canonical GPL-3.0 text,
already committed), SPDX headers in source files
(`;; SPDX-License-Identifier: GPL-3.0-or-later`), and a short notice in each `.asd`.

Vendored protocol XML under `protocols/` keeps its own license: `wayland.xml` is MIT/HPND
and `wayland-protocols`/`wlr-protocols` are MIT. Those notices stay in place next to the
files. MIT → GPL is a compatible direction, so generating GPL code from those XML files is
unproblematic.

**Consequences.**

- Any compositor built on `cl-compositor-framework` is GPL-3.0-or-later. That is the intent:
  the framework is a commons, and improvements to it flow back.
- **Wayland clients are unaffected.** Firefox, kitty, GTK and Qt apps talk to the compositor
  over a socket using a protocol; that is not linking or a derivative work, so no client
  becomes GPL by running on `cl-umbra`. The same holds for programs that send forms over the
  eval channel.
- Code that may be *copied* narrows: GPL-3 code (river, niri, dwl, sway where GPL) is
  compatible with attribution; GPL-2.0-only code is not, and neither is code with no license.
  The project's stance is still independent implementation — consult, do not transcribe — so
  this mostly affects convenience copying.
- wayflan's BSD-3-Clause is one-way compatible: adapting its code is fine, keeping the notice
  in the file is required.
- Dependencies are unaffected in practice (SBCL is public-domain/BSD, CFFI is MIT, `plump` is
  zlib, `alexandria` is MIT, `closer-mop` is MIT): permissive licenses are GPL-compatible.
- Distribution: any binary we ship (`save-lisp-and-die` image) is conveyed under GPL-3 and
  must come with corresponding source, which this repository is.
- A future decision could relicense a *client* library separately if non-GPL Lisp programs
  ever need it; that would require every copyright holder's agreement, which is why it is
  cheaper to keep one license now.

---

## D14 — The REPL is the control surface; no IPC message layer

**Status:** accepted (user requirement)

**Context.** Compositors grow message layers (`swaymsg`, `riverctl`, Umbriel's JSON socket)
because a C or Rust process's state is not addressable from outside. The layer then
accumulates: a command registry, a wire format, request/reply framing, an event stream,
subscriptions, schema versioning, a client library, and conformance tests for all of it. In
Common Lisp the running image is addressable, and a form is the message.

**Decision.** No command registry and no IPC protocol.

- The control surface is package `umbra`: exported command and query **functions** with
  lambda lists and docstrings (`focus`, `workspaces`, `dispatch`, `reload-config`, …).
- Humans attach SLY/SLIME and evaluate anything, between dispatches (D9).
- Non-image processes (scripts, bars, test harnesses) use a local **eval channel**: a 0600
  Unix socket that reads s-expressions and returns printed values, executes at safe points
  under a deadline, and never enters the debugger.
- Events are closures: `(umbra:subscribe (lambda (event) …))` in the image; a client that
  wants a stream sends that one form with its own stream captured. No event bus, no schema.
- Panels, notifiers and lockers stay separate Wayland clients using protocols
  (`wlr-layer-shell`, `wlr-foreign-toplevel`, `ext-session-lock`), not IPC.

**Consequences.** A subsystem disappears from v1 — estimated 2-3 focused weeks of build plus
permanent schema maintenance, a client library and a conformance suite. The control surface
is tested by ordinary function tests. Stability is promised by a package and docstrings,
which is a weaker promise than a versioned protocol and much cheaper to keep. Scripts need
no client library: `socat` plus a form. Costs: evaluating a form is shell-equivalent power,
so the channel is opt-in, `0600`, peer-credential checked, deadline-bounded and logged; a
third-party tool that insists on a specific protocol (`waybar`'s sway mode, say) gets a small
out-of-tree adapter if and when someone needs it, not a protocol in the core.

---

## D15 — A `new_id` is allocated by the dispatch layer, not passed in

**Status:** accepted

**Context.** The wire carries a `new_id` argument — an object id the sender chooses — in
about a third of all requests (`wl_display.get_registry`, `wl_display.sync`,
`wl_surface.get_buffer_release`, `wl_shm.create_pool`, every `create_*` factory). The
schema has to record it: the type is `n`, not `o`, and the id may be null only in `object`
position. But *as a Lisp argument* it is noise: a client allocates the id from its own
range, the server allocates it from its range, and either way the caller of a request
function wants the created object, not the number.

**Decision.** Generated request generic functions omit `:new-id` arguments from their
lambda lists; the schema keeps them for the wire. The dispatch layer allocates, the request
method returns the proxy (client) or creates the resource (server, phase 1):

```lisp
(wl-display.get-registry display)                 ; -> wl_registry proxy
(wl-registry.bind registry 5 "wl_compositor" 3)   ; -> wl_compositor proxy at version 3
(wl-shm.create-pool shm fd size)                  ; -> wl_shm_pool proxy
```

Events keep every argument, `new_id` included: there the *sender* chose the id, and the
receiver must learn it (`wl_data_device.data_offer` introduces a `wl_data_offer` the client
never asked for by id).

**Consequences.** One schema, two directions, still (D8): the same generic function is the
client's sending method and the compositor's handler. Clients cannot accidentally send an
id they do not own — allocation happens in one place, `allocate-proxy`. Server code in
phase 1 must allocate before it calls the handler, which is where the "unused new_id" check
belongs anyway. `wl_registry.bind` is the exception that proves the rule: its interface
name and version come from the caller, so its *client* method resolves the interface and
clamps the version before allocating. The generated code for a request whose only argument
was a `new_id` (`wl_display.sync`) is now `(defgeneric wl-display.sync (object))`.

## D16 — Generated protocol fasls depend on the generator's sources

**Status:** accepted

**Context.** The `:wayland-protocol` ASDF component writes a Lisp file from XML and compiles
it. ASDF decides whether that fasl is stale from the component's *inputs*, which by default
are just the XML. So changing `wayland.codegen` or `wayland.schema` — which change every
generated file — rebuilt nothing: the image kept the old generic function lambda lists,
and the next system to compile against them failed somewhere unrelated, or worse, agreed
with itself and disagreed with the XML.

**Decision.** `asdf:input-files` for the component includes `cl-wayland-core`'s
`src/schema.lisp` and `src/codegen.lisp`. A change to either re-generates and recompiles
every declared protocol on the next build.

**Consequences.** Editing the generator costs one regeneration (~1 s for the two protocols
currently declared), which is the correct price. It also means a `git checkout` of an older
generator forces the same rebuild, so a stale fasl cannot outlive the source it came from.
This was found the hard way: D15's change compiled against a fasl that predated it.

---

## D17 — Tests run on Rove

**Status:** accepted (user preference)

**Context.** Phase 0 started with a 105-line hand-rolled harness in `tests/harness.lisp`
(`deftest`, `is`, `is-equal`, `signals`, `run-all`), on the theory that a dependency-free
suite was cheaper than adopting a framework. It worked, but it had two costs that grew with
the suite: no per-assertion reporting (a failure printed a form and two values, and nothing
else), and a home-grown `is-equal` whose arguments were (expected, form) — the reverse of
every other Lisp assertion library, including Rove's.

**Decision.** `cl-wayland-tests` depends on Rove; the harness is deleted. Assertions are
Rove's `ok` and `signals`, so the reporting (form, argument values, backtrace on failure) is
the framework's. One test file's package is one suite, and `(rove:run :cl-wayland-tests)`
runs them all; `scripts/run-tests.sh` quits with Rove's verdict.

**Consequences.**

- A dependency appears, but only in the test system: no shipped system loads Rove, so the
  purity rule (D1) and the runtime dependency list (SBCL + CFFI) are unchanged. `qlfile`
  gains `ql rove`.
- The codegen tests now load generated code into a throwaway package under a throwaway
  registry. Loading it over the live `WAYLAND` package cost 447 redefinition warnings per run
  and, once the package changed, replaced the real registry entries with copies whose symbols
  no client had methods on.
- Rove 0.10 has no `is`/`is-equal`; assertions are `ok`. The migration rewrote 359 call
  sites (`is` → `ok`, `is-equal` → `ok` with the predicate spelled out, `signals` → `ok
  (signals form 'type)`), keeping the assertion count identical (2152) as the check that
  nothing was silently dropped.
- The runner (`tests/runner.lisp`) names the six suites instead of calling
  `(rove:run :cl-wayland-tests)`. Rove finds suites by mapping each fasl back to its source
  file, which only works when the fasl is in ASDF's user cache; a translated build finds
  none and reports success on zero tests. Naming them also makes an empty suite a failure.
- Rove depends on dissect, and dissect 20231021's SBCL backend interns symbols from `SB-DI`,
  which SBCL 2.6 locks. `tests/cl-wayland-tests.asd` unlocks that package before Rove is
  loaded. It is a workaround, it is confined to the test system, and it should be deleted
  when dissect catches up.
- `signals` changes shape: Rove's takes a form and a quoted condition type and *returns*
  whether it was signalled, so the idiom is `(ok (signals (f) 'type))` rather than
  `(signals type (f))`. The old order is not preserved: one convention is better than a
  wrapper that hides it.

---

## D18 — The fuzzer is a decoder fuzzer with its own seeded random source

**Status:** accepted

**Context.** The phase-0 gate asks for 10⁶ fuzz iterations with no crash, hang, unbounded
allocation or descriptor leak. "Fuzz the decoder" can mean anything from feeding random
bytes to a parser to a full grammar-driven protocol fuzzer, and a fuzzer whose failures
cannot be reproduced is a fuzzer nobody uses.

**Decision.** `tests/fuzz/fuzz.lisp` (system `cl-wayland-tests/fuzz`, driver
`scripts/fuzz.sh ITERATIONS [SEED]`) runs three cases, one per iteration, chosen by a
xorshift64\* generator seeded from the command line:

1. **header** — random octets, half the time with a plausible `(object-id, size, opcode)`,
   through `decode-header`, checking every invariant it promises;
2. **schema** — random octets decoded as the arguments of a random request or event from the
   loaded protocols, asserting that the only escape is a `wayland.wire` condition;
3. **transport** — random writes (garbage, truncated messages, whole messages, some with
   descriptors attached) to one end of a real `socketpair`, `pump` on the other, checking
   what dispatches, that the partial tail and the buffer capacity stay bounded, and that
   every descriptor the stream delivered is closed.

**Consequences.**

- A failure prints the seed, and the seed reproduces it exactly on any SBCL: `cl:random` is
  not used because its sequence is implementation-defined.
- The in-memory cases are cheap (10⁶ plus socket I/O in under three seconds), so the gate
  runs the full 10⁶ rather than a smaller nightly budget.
- The hang clause is `sb-ext:with-timeout`, which is SBCL-specific; the project is SBCL-only
  and the alternative would only detect a hang after the fact.
- The first run found a real hazard: `wayland.io` queued descriptors that a rejected stream
  would drop without closing them. `reset-input-buffer` now closes them by default (and
  returns how many), because the kernel's duplicates are nobody else's to close.
- It does not fuzz a *peer*: pool validation, stride/format checks and protocol errors need a
  server to reject them, and arrive with phase 1.

---

## D19 — One object table and one socket-name rule, in the core

**Status:** accepted

**Context.** Phase 1 needs what phase 0's client already had: an object table per connection
and the two id namespaces (`2 .. 0xFEFFFFFF` for the client, `0xFF000000 ..` for the server),
with lowest-free-id allocation. It also needs the socket-name rule
(`$WAYLAND_DISPLAY` under `$XDG_RUNTIME_DIR`, absolute names used as-is) that the client
already implemented. Two copies of either would drift, and the second copy would be the one
nobody tested.

**Decision.** `cl-wayland-core/src/object.lisp` (package `wayland.object`) owns the id ranges,
`object-table`, allocation and release; `wayland.client` and `wayland.server` both use it.
`wayland.io:socket-path` owns the socket-name rule, and `wayland.client:socket-path` is now a
thin wrapper that re-signals the failure as its own `client-error`.

**Consequences.**

- The client's `display-next-id` and `display-free-ids` slots are gone (replaced by the
  table); the suite stayed green, which is the check that nothing depended on them.
- Client and server id reuse is *lowest free id*, on purpose. This is not what libwayland
  does — its client reuses the most recently freed id first, which the C probe showed
  directly — and the docs were corrected rather than the code: which free id a client picks
  is invisible to the peer, ascending ids are easier to read in a trace, and the property
  that matters (the id comes back at all, because `wl_display.delete_id` arrived) is
  unchanged and now tested from outside by `tests/c-client`.
- A bad socket name is reported as `wayland.io:socket-path-error`; each end wraps it in the
  condition its callers already catch. One message, two vocabularies, no duplicated rule.
- `wayland.object` deliberately knows nothing about destruction or `delete_id`: who may
  recycle an id, and when, differs between the two ends and stays in their dispatch layers.

---

## D20 — The socket lock is `flock(2)`, not a POSIX record lock

**Status:** accepted

**Context.** A compositor has to answer "is another one already using this name?" without a
race, and leave a pid for the session manager. The two candidate locks are `fcntl`'s
`F_SETLK` and `flock(2)`.

**Decision.** `flock(fd, LOCK_EX | LOCK_NB)` on `<socket>.lock`, the holder's pid written into
it, mode 0600, taken *before* a stale socket file is unlinked; socket mode 0700. Teardown
unlinks the socket, releases the lock by closing, then unlinks the lock file.

**Consequences.**

- POSIX record locks belong to the *process*, so two servers in one image — a nested
  compositor, or a test that creates two displays — would both believe they held the name.
  A unit test caught exactly that: the expected `socket-in-use` never arrived. `flock` locks
  belong to the open file description, so the same process conflicts with itself the way a
  second process would.
- The lock is advisory, which is all it needs to be: the socket file mode is the access
  control, and the lock only arbitrates ownership of the name.
- A crashed server leaves its socket file behind; the next server holds the lock, so
  deleting that file is safe and is what it does.

---

## D21 — Termination signals arrive as posted commands, not through `signalfd`

**Status:** accepted

**Context.** D9 and `docs/protocol-layer.md` §7 say signals reach the loop as descriptor
events, never as handlers that preempt dispatch. `signalfd` gives that, but only sees a
process-directed signal if *every* thread blocks it — and an implementation has threads of
its own. SBCL creates a finalizer thread on demand (loading Quicklisp is enough), and a
process-directed `SIGTERM` can then be delivered there. Measured, twice: the demo server with
two threads stayed in `epoll_wait`, signalfd empty, after `kill -TERM`; the same server with
the signal blocked in the only thread read it immediately.

**Decision.** `wayland.reactor:add-signal-handler` installs the implementation's interrupt
handler (`sb-sys:enable-interrupt`, by number) and the handler does one thing: `post` a
command to the reactor. The command runs `ON-SIGNAL` inside a normal cycle, between messages,
which is the guarantee `signalfd` was there to provide. `add-signal-source` remains for
signals whose blocking we control from the start of the image, and for implementations with
no extra threads.

**Consequences.**

- The handler may run on any thread, so it must not touch protocol state; the API shape
  enforces that by giving it no access beyond `post` (mutex plus eventfd wakeup).
- A signal that arrives after `close-reactor` is ignored instead of posting to a closed
  eventfd — the handler checks `reactor-closed-p` first.
- The demo server now exits 0 on `SIGTERM` and removes its socket and lock file; the gate
  clause asserts all three.
- `add-signal-handler` verifies the installation by reading the disposition back
  (`wayland.ffi:signal-handler-installed-p`), so a handler that silently failed to take is a
  startup error instead of a compositor that dies like a crash and leaves a socket file
  behind. During this work, three ad-hoc shutdowns did exactly that and eight controlled
  reruns did not; the check turns that class of uncertainty into a message.


---

## D22 — The phase-1 gate has two independent peers, and they check different things

**Status:** accepted

**Context.** The phase-1 gate says `wayland-info` must talk to our server, and that a fuzz
client must not crash or wedge it. `wayland-info` binds globals and prints them, but it does
not destroy, re-bind, or misbehave; and "cannot crash or wedge" is only meaningful against a
client that tries. Our own client is not a credible adversary or a credible oracle for its
own server's mistakes.

**Decision.** Two fixtures, both kept outside every shipped system:

1. `tests/fuzz/client-fuzz.lisp` (`scripts/fuzz-client.sh`), the *peer fuzzer*: one real
   connection per case, five case kinds (garbage, plausible-but-random, specifically illegal,
   corrupted size, tiny), and four invariants — well-formed replies with at most one
   `wl_display.error`; the client is dropped after EOF; no `:error`-level line from our own
   code for the whole run; and no descriptor or memory growth across it, with a well-behaved
   client still served at the end and every 1000 cases. It shares the decoder fuzzer's seeded
   generator, so a seed reproduces a failure in either.
2. `tests/c-client/wayland-probe.c` (`scripts/c-probe.sh`), an *independent C client* built
   against the system's libwayland-client: it binds `wl_output` at versions 3 and 1, checks
   the initial events and their order and the absence of newer events below their `since`,
   releases, and proves `wl_display.delete_id` by getting the released id back on a later
   bind.

**Consequences.**

- The probe links libwayland on purpose. D1 (purity) is about what we *ship*; a fixture whose
  entire job is to be the other side is the one place the rule inverts, and it is stated in
  the file and in `scripts/c-probe.sh` so nobody reads it as a violation.
- The C probe immediately earned its keep: it proved the id-reuse order the docs claimed was
  wrong (see D19), and it exercises libwayland's own id allocator, event queue and proxy
  lifetime against our server, which no Lisp-side test can.
- Both are gate clauses (8 and 9), so a client-visible server mistake fails the gate rather
  than being noticed by a user.
- Neither covers protocol content that does not exist yet: pools, strides, formats, seats.
  They grow with phase 2's globals, and the peer fuzzer gains its "descriptor on a request
  that declares none" case when there is a request that declares one.

---

## D23 — A file descriptor occupies zero octets on the wire

**Status:** accepted (corrects a phase-0 mistake)

**Context.** Phase 0 implemented `fd` arguments as a 4-octet placeholder in the message body,
with the descriptor in `SCM_RIGHTS`. The byte-exact unit tests, the encoder and the decoder all
agreed with that, so the suite was green for two phases. Phase 2a's first real peer — a
libwayland client calling `wl_shm.create_pool(new_id, fd, size)` — announced the mistake as a
protocol error on our side within one run.

**Decision.** An `fd` argument occupies **no octets**: `put-fd` writes nothing and only
appends to the out buffer's descriptor queue; `read-fd` consumes nothing and only advances
through the received queue. The message's size and layout are exactly as if the argument were
not there; descriptors are assigned to `fd` arguments in argument order across the batch.

**Evidence.** Two independent measurements, both recorded in `docs/protocol-layer.md` §1:
`strace` on libwayland-client shows `create_pool` as a 16-octet message (header, new id, size)
with the descriptor in `cmsg_data`; wayflan's encoder sizes `:fd` as `0`.

**Consequences.**

- The wire tests were wrong in a way that only a foreign peer could expose: the oracle
  (`wayland-scanner`) compares signatures, not sizes, so a self-consistent codec passed. The
  test now asserts that an fd adds no octets and does not move the reader, and the peer
  fuzzer's "plausible" case picks real requests — including fd-carrying ones — so this stays
  covered.
- `wl_shm.create_pool` and every future fd-bearing request decode correctly; a `fd` argument
  with an empty descriptor queue remains `missing-fd`, which is a protocol error.
- The general lesson, worth repeating when the next "obviously right" codec invariant appears:
  a stub peer that is really a peer is worth more than any amount of self-consistency.

---

## D24 — A frame is rendered once per cycle, and the render flushes

**Status:** accepted

**Context.** Phase 2a has to answer three questions that the protocol deliberately leaves
open: when a commit becomes pixels, when a frame callback fires, and who writes the events the
renderer produces.

**Decision.** A commit marks the output dirty and registers one reactor *idle*; the idle
renders if dirty and then flushes every client. Frame callbacks fire at the end of that render,
with a millisecond timestamp, never at commit time. The target is cleared and every mapped
surface is drawn back to front; damage is accepted and ignored until 2b, and the whole target
is repainted.

**Consequences.**

- One render per cycle however many commits arrive, so a client that bursts commits costs one
  frame — the same coalescing a real output's clock gives, without a clock.
- The flush is load-bearing: the read loop flushes before the idle runs, so a `done` queued by
  the render would otherwise sit in the buffer while the client waited forever. Found by the
  gate client hanging; fixed by flushing after presenting.
- Releasing a replaced buffer at the next commit was safe *because* rendering happens before
  the next cycle's commits, but it is not enough for a real client: see D25, which moved the
  release to presentation after `weston-simple-shm` deadlocked on it.
- A real output clock (timer for headless, page flip for DRM) replaces the idle without
  touching the renderer or the surface objects, which is why the renderer never learned about
  time.

---

## D25 — A buffer is released when the frame using it is presented

**Status:** accepted (corrects D24's release rule)

**Context.** D24 released a *replaced* buffer at the next commit. The phase-2a gate client
attaches one buffer, commits once and exits, so nothing noticed. The first double-buffered
client — `weston-simple-shm`, in phase 3 — printed `Both buffers busy at redraw(). Server bug?`
after two frames and then hung, because it waits for `wl_buffer.release` before redrawing into a
buffer it already committed, and we never sent one.

The root cause was subtler than the timing rule: `released-p` started true ("the client has
it") and was never cleared, because nothing claimed a buffer on attach. Every `release` call
was therefore a no-op, including the one D24 believed it was making.

**Decision.** `wl_surface.attach` with a non-nil buffer *claims* it (`claim-shm-buffer`: the
client no longer owns it). The compositor releases the buffer it drew **after compositing that
frame into the target**, before the frame callback fires. A buffer replaced by a later commit
before it was presented is still released at that commit, so a burst of commits in one batch
cannot strand one.

**Evidence.** `./scripts/xdg-shell-gate.sh`: `weston-simple-shm` now runs for as long as the
gate pumps it, drawing 570 distinct colours, and exits only when signalled. The phase-2a pixel
gate (`./scripts/headless-frame.sh`) still passes unchanged.

**Consequences.**

- Release is no longer tied to "the next commit", which was a claim about *our* scheduling; it
  is tied to presentation, which is the protocol's own rule and survives a real output clock.
- Because rendering copies into our own target synchronously, releasing immediately after the
  copy is correct; a GPU renderer with queued frames must keep the buffer until the fence
  signals. That is written down here so the change is deliberate when the renderer changes.
- `shm-buffer-released-p` now means what its name says at every moment, and the double-release
  guard still holds (a released buffer's second release is a no-op).

---

## D26 — xdg-shell is offered at version 1, with roles linked by three commit hooks

**Status:** accepted

**Context.** Phase 3 needs `xdg_wm_base`, `xdg_surface` and `xdg_toplevel`. Two design questions
had to be answered before writing them: how much of the interface to advertise, and where the
role state lives relative to `wl_surface`.

**Decision.**

1. **Version 1 only.** The generated schema knows v7; we advertise v1 because v1 is what we
   implement. Advertising v4+ would promise `xdg_toplevel.configure_bounds` and v5+ would
   promise `wm_capabilities`, and a compositor that stays silent about an event it advertised
   is worse than one that never offered it. Bumping the version is a slice of its own: the
   event must be sent, and the version gate in `send-event` will not lie about it.
2. **Roles are separate resources, linked from `wl_surface`.** `xdg_surface` (the configure
   handshake) and `xdg_toplevel` (the window) are ordinary resources; the `wl_surface` keeps a
   `surface-shell-surface` pointer. The commit path asks the role three questions through
   generic functions with do-nothing defaults: `surface-shell-check-commit` (may refuse: a
   buffer before the first ack), `surface-shell-committed` (produces what the commit implies:
   the initial configure) and `surface-shell-lost` (the surface died under the role). A bare
   `wl_surface`, which is what every phase-2a client creates, runs none of it.
3. **What is absent says so.** `xdg_popup`, `xdg_positioner` and decoration negotiation have no
   methods, so the dispatch layer answers `wl_display.error` with `implementation` — the same
   honest "not built yet" the plan asks for.
4. **Policy hooks exist but do nothing yet.** `close-toplevel` and `set-toplevel-activated`
   are the two things a window manager will call; with no seat and no layout they are unused by
   the compositor, and the configure they would send carries a complete state array computed
   from scratch, never patched.
5. **The compositor prunes destroyed surfaces from its draw list** at render time rather than
   at destroy time, because destroy happens mid-dispatch while the list is owned by the frame.

**Consequences.**

- Client-chosen ids for `xdg_surface`/`xdg_toplevel` are `delete_id`-ed like any other, and the
  objects unlink themselves from the surface and the `wm_base` when destroyed, so no id can be
  reached after it is gone.
- The configure handshake is enforced, not decorative: `unconfigured_buffer`,
  `invalid_serial`, `already_constructed`, `defunct_role_object` and `defunct_surfaces` are all
  reachable and all tested (`wayland.test.server`, 8 tests).
- `xdg_toplevel.configure` carries an empty state array and 0×0 on the initial configure,
  matching `docs/protocol-layer.md` §8; a real client chooses its own size and the gate asserts
  that it did.
- Popups will arrive with a slice that can also position and grab them; a positioner that
  positions nothing would be the lie this decision avoids.

---

## D27 — One seat per compositor, explicit focus, and synthetic input as the backend seam

**Status:** accepted

**Context.** Phase 3b has to deliver `wl_seat`, `wl_pointer` and `wl_keyboard` with no input
device, no libinput and no cursor — and prove it with a real client.

**Decision.**

1. **The seat is not a resource.** `seat` is a per-compositor object holding capabilities, one
   keymap, the keyboard and pointer focus, the pointer position, the logically-down keys and
   the modifier state. Each client that binds the global gets a `seat-resource` beneath it,
   which is only a factory for that client's `pointer`/`keyboard`/`touch` objects. Focus and
   modifier state outlive any client, so they cannot live on one.
2. **Version 4.** v5 adds `wl_pointer.frame` and `wl_seat.release`, v6 `axis_source` and
   wheel tilt, v7+ high-resolution scroll, v10 the `repeated` key state. v4 is the newest
   version whose every request and event this slice implements, so `wl_seat.release` is
   correctly answered `invalid_method` rather than silently accepted.
3. **Focus is one call.** `set-keyboard-focus` sends `leave` to the keyboards that had focus,
   `enter` + `modifiers` (and the array of held keys) to the client that gained it, and calls
   the `seat-focus-changed` hook that a compositor uses to send `xdg_toplevel.configure` with
   `activated`. Enter/leave and activation cannot drift apart, because they hang off the same
   call.
4. **Synthetic input is the seam a backend uses**: `send-key-event`, `send-pointer-motion`,
   `-button`, `-axis`. The headless backend exposes `inject-*` wrappers that look up the key in
   the table and update the modifier mask, so what a test injects is exactly what a device
   would have reported. A real backend replaces the caller, not the seat.
5. **The compositor flushes every cycle.** `run-once` ends with `flush-all`, as
   libwayland-server's loop does. Without it, events produced outside a client's readable
   event — input injection, timers, idles — sat in the buffer until something unrelated
   flushed; `weston-eventdemo` sat idle and never saw the motion events at all.
6. **Focus follows the map, once.** The headless compositor focuses a toplevel when it maps
   (tinywl's policy) and not on every commit: `focus-surface` re-places the pointer, so calling
   it per commit teleported the cursor back to (0,0) and sprayed enter/leave at the client.

**Consequences.**

- The seat gate proves the chain with a real client: `weston-eventdemo` prints the coordinates,
  button codes and *unicode code points* it received, and a libxkbcommon probe parses the
  keymap we sent.
- Grabs, cursor rendering, touch, and a real keymap from libxkbcommon stay open; the seat's
  shape does not change when they arrive.

---

## D28 — Keymaps are generated as text, and parsed by the peer

**Status:** accepted (phase 4 revisits the generator, not the contract)

**Context.** A `wl_keyboard.keymap` event carries an XKB keymap the *client* compiles with its
own libxkbcommon. Something has to produce one, and phase 3 has no input devices.

**Decision.** `cf.input` generates a self-contained XKB keymap from a table of keys: the evdev
code (what `wl_keyboard.key` carries), the XKB keycode (computed as evdev + 8, never stored, so
the classic off-by-eight bug cannot be typed in), two keysyms, the modifier the key sets, and
the keysym name. No `include` of rules or data files, so a client needs nothing from
`/usr/share/X11/xkb`. The compositor's modifier state comes from the same table, so what the
client computes and what `wl_keyboard.modifiers` says agree by construction.

**Evidence.** `tests/c-client/xkb-keymap-probe.c` compiles the keymap we actually sent (dumped
by the gate from the seat) with `XKB_CONTEXT_NO_DEFAULT_INCLUDES`, checks keycode 1 is Escape,
16 is q/Q, 42 is Shift_L, and runs a state test — Shift held, q pressed, keysym `Q` — which is
the part a keymap that merely parses can still get wrong. The gate also requires the real
client to print `key key: 16, unicode: 81, ... modifiers: 0x1`.

**Consequences.** libxkbcommon stays out of the shipped image until phase 4, where real layouts
and device keymaps from libinput need it. Everything else already speaks keycodes and masks, so
that change stays inside `cf.input`.

---

## D29 — `wl_region` is a rectangle set, and `wl_compositor` is offered at version 3

**Status:** accepted

**Context.** Every `window.c`-based client in weston's demo set binds `wl_compositor` at
version 3 unconditionally and calls `create_region` before it maps a window. Advertising v1
(the honest minimum) kept every pointer-using client off the compositor entirely.

**Decision.**

1. **`wl_region` is a real object**: a list of `(x y width height)`, `add` is union,
   `subtract` is difference and produces up to four pieces per existing rectangle. It is not
   canonicalised — the protocol defines the *area*, and a minimal decomposition is not needed
   to be correct.
2. **Regions are snapshotted when they are set.** `set_opaque_region`/`set_input_region` copy
   the rectangle list immediately; `commit` publishes the copy. A client may destroy the region
   object the moment it has set it, and the surface must keep the area. *(Corrected by D31.5:
   this decision as first written copied at commit, which read a destroyed region as empty.)*
3. **`wl_compositor` is offered at version 3.** v2 adds `set_buffer_transform`, v3 adds
   `set_buffer_scale` (and `damage_buffer` is v4, which we do not offer). Both requests are
   validated, stored and *not* applied: the headless output advertises transform 0 and scale 1,
   so a client that respects the output loses nothing, and the renderer's transform/scale work
   in 2b starts from state that already exists.
4. Regions are stored and not yet *acted on*: there is no hit-testing (no scene graph) and the
   renderer composites without an opaque optimisation. That is 2b, and the set arithmetic is
   tested now so that 2b has something correct to consume.

**Consequences.** The version is a promise, and the promise is "we accept and remember". A
client that sets scale 2 gets a window drawn at half the size it asked for; that is written
down in `docs/framework.md` §5 and is the first thing 2b fixes.

---

## D30 — `wl_shm_pool.resize` grows only, and checks the file first

**Status:** accepted

**Context.** `window.c` grows its pool when it needs a bigger buffer, so every real client
calls `resize`. It was listed as phase-2b work; phase 3b needed it.

**Decision.** `resize` accepts only a larger size (the protocol says it can only grow), maps
the new range *before* dropping the old one so a failure changes nothing, and — because the
pool's descriptor is ours — asks `lseek(SEEK_END)` for the file's size first. mmap succeeds
past the end of a file and the failure arrives later as SIGBUS in the renderer; the lseek turns
that into a protocol error at the request that caused it, with the two sizes in the message.

**Consequences.** Growing a pool whose file was not grown is now a clean protocol error rather
than a SIGBUS. The remaining SIGBUS case (a client that *shrinks* its file after mapping) is
still open and still documented in `docs/memory-and-rendering.md` §4; `resize` no longer makes
it worse.


---

## D31 — The scene is a retained node tree, and regions are copied when they are set

**Status:** accepted

**Context.** Phase 3a/3b drew every mapped surface at its attach offset, in commit order. That
is not a scene: nothing could be placed, nothing could be hit-tested, "on top" meant "committed
last", and `wl_pointer.set_cursor` was recorded but nothing was drawn. Phase 3c needs two
windows, a pointer and a cursor before grabs or tinywl can exist.

**Decision.**

1. **`cf.scene` is a retained tree per output** with four node kinds: `tree-node` (a group;
   the root is one, and layer-shell's layers will be more), `buffer-node` (a mapped
   `wl_surface`, sized by its current buffer and never by a value the compositor chose),
   `rect-node` (a solid premultiplied rectangle) and `image-node` (pixels we own). A node has a
   position in its *parent's* space, a visibility flag and a parent; the root's parent is the
   output, so a root child's position is output-local, which is the space both the renderer and
   hit testing use.
2. **Placement is the compositor's statement, the attach offset is the client's.** A node's
   position is where the compositor put the window; `wl_surface.attach`'s x, y is the client's
   own offset for its content inside the surface, and the two are added at draw time. A surface
   with *no* shell role keeps a node at the origin and is therefore drawn exactly where phase 2a
   drew it (its attach offset), which is why the phase-2a pixel assertions still mean what they
   meant.
3. **Stacking is placement order, not commit order.** A new window goes on top; committing is
   not raising. Phase 2a's "commit order is draw order" made two redrawing clients flip places
   several times a second (the scene gate found it: the hit test at (37,37) alternated between
   the two windows). `scene:node-raised` exists for the click-to-raise policy that will use it.
4. **Hit testing is a front-to-back walk** returning the node and the point in that node's own
   space; the compositor turns a `buffer-node` into a surface. A `buffer-node` is hit only where
   it is mapped, inside its buffer, and inside its committed **input region** — which is now
   acted on, for the first time.
5. **Regions are copied when they are *set*, not when the surface commits** (amending D29
   item 2). A client is allowed to destroy the `wl_region` immediately after
   `set_input_region`, and weston's clients do; reading the rectangles at commit time read an
   empty region, so `weston-eventdemo`'s window became input-transparent at (0,0) while its
   real input region was `(32 32 436 336)`. Three states are kept for input: `nil` (never set,
   the whole surface), `:empty` (an empty region, click-through), and a list of rectangles.
6. **The cursor is a node that is drawn last and never hit-tested.** It is
   `scene:cursor`, a sibling of the root rather than a child of it, so the pointer can never be
   standing on the pointer; its position *is* the pointer's position in output space, and the
   default image is a 16x16 arrow generated from a table (no theme, no libxcursor until
   phase 5).

**Consequences.** `cf:compositor-scene`, `cf:scene-hit-test`, `cf:on-new-toplevel` and
`cf.scene:set-node-position` are the surface a compositor author writes against. Damage,
clipping, culling, layers, per-output roots and hit-testing of popups stay open; the node types
and the coordinate rule do not change when they arrive.

---

## D32 — Pointer focus follows the pointer, a click focuses the keyboard, and focus follows the map once

**Status:** accepted

**Context.** D27 made focus one call and focused a toplevel when it mapped. With one client that
was indistinguishable from a policy. With two, it is not: every commit by an unfocused window
re-focused it, so two redrawing clients fought over the keyboard (found by the scene gate).

**Decision.**

1. **Pointer focus follows the pointer.** Motion hit-tests, then enters the surface under the
   pointer, leaves the one that had it, or sends `wl_pointer.motion` if it is the same surface —
   with *surface-local* coordinates computed by the scene. Hovering does not change the keyboard
   focus, and does not send anything to a surface the pointer is not over.
2. **A press focuses the window under the pointer.** `inject-pointer-button :pressed` hit-tests,
   fixes the pointer focus if it somehow differs, and calls `focus-surface` for the keyboard
   before the button event goes out, so the click is delivered to a window that is already
   activated. A press on the bare output changes nothing.
3. **Focus follows the *map*, once.** The condition is "this surface's node was just created",
   not "this surface is not focused". An unmapped-then-remapped toplevel counts as a new map.
4. **Two coordinate spaces, deliberately separate.** The cursor node's position is output space;
   `seat-pointer-x/y` is surface-local. Conflating them is how a compositor ends up sending
   output coordinates to a client that expects its own.
5. **Injection keeps the seat honest.** `inject-pointer-motion` moves the cursor node, updates
   pointer focus and marks the output dirty, because the frame changed even if no client did.

**Consequences.** Click-to-focus, hover and the cursor are one slice because they are one
question ("who is under the pointer?"). Grabs, click-to-raise, the focus stack, cursor shapes
and client-provided cursor surfaces are the next slices and hang off the same calls:
`focus-surface`, `surface-under-cursor`, `scene:node-raised`.

**Evidence.** `scripts/scene-gate.sh`: two `weston-simple-shm` clients, placed at (0,0) and
(32,32); hover moves the pointer to A while the keyboard stays on B; clicking A moves the
keyboard and makes A's configure carry `activated` while B's carries nothing; clicking B moves
it back; both windows' pixels are drawn where they were placed; the cursor's black tip and white
body are the exact pixels at the pointer's position.

---

## D33 — Grabs are objects started by a validated serial, and keybindings come before the client

**Status:** accepted

**Context.** `xdg_toplevel.move`/`.resize` were accepted, validated for the enum and ignored: there
was a seat but no serial vocabulary and nothing to move. The scene (D31) and pointer focus (D32)
made both possible.

**Decision.**

1. **A serial is a capability.** Every serial-bearing event the server sends comes from
   `display-next-serial`, which now also remembers the last 64 serials.
   `display-valid-serial-p`/`valid-serial-p` answer "did we issue this recently"; a serial we never
   sent, one from before the window, and one from a previous interaction are all refused. The
   window is bounded on purpose: a click-to-request round trip is short, and keeping every serial
   forever would make an old one replayable into a new interaction.
2. **`move`/`resize` are checked twice.** The shell refuses a request whose serial is not ours or
   whose surface is not the seat's keyboard or pointer focus, *silently* — the protocol defines no
   error for this, and a client asking to move a window it does not have is a client whose click we
   already ignored. Only then does it call `toplevel-move-requested`/`toplevel-resize-requested`,
   generic functions dispatched on the `wl_surface` (so a framework's `CF-SURFACE` own them) whose
   default does nothing. A transport-only server still answers xdg-shell correctly.
3. **A grab is an object that ends exactly once** (`cf.grab`): `grab-motion`, `grab-button`,
   `grab-key`, and `grab-end`, which is idempotent. A grab holds the button that was *physically
   down* when the client asked (the seat tracks pressed buttons), so a middle-button drag ends on
   the middle button instead of assuming the left one.
4. **A move follows the pointer's delta from a remembered origin**, not an accumulation of events:
   a lost motion event cannot leave the window drifting behind the pointer.
5. **A resize is a configure.** The compositor cannot resize a buffer it does not own, so the grab
   computes the size the edge implies (`resize-target-size`, a pure function) and asks the client
   for it with `xdg_toplevel.configure`. `set-toplevel-activated` already re-sends the last
   configure size, so a focus change does not reset a resized window to "you choose". Dragging a
   top or left edge does **not** move the node: until the client comes back with a buffer of the
   requested size there is nothing to anchor, and a node that slides while its content does not is
   worse than one that waits.
6. **Keybindings are consulted before the client**, in the one key path a backend and a test both
   use (`handle-key`): a grab first, then the table, then the focused window. A consumed press
   never reaches the client, and its release is swallowed too, because a client that never saw the
   press must not see the release. Modifier keys are still forwarded when they are not themselves
   bound — v0 has no device to suppress them from, and a client that never saw Alt release would
   think it was still held. That is a documented simplification, not an oversight.
7. **Matching is exact on the modifier mask.** Alt+Escape does not fire with Alt+Shift held. A
   compositor that wants "any of these" adds bindings; predictable is worth more than clever.
8. **The default table is tinywl's two**: Alt+Esc stops the main loop, Alt+F1 brings the bottom
   window to the top and focuses it. They are installed by `make-headless-compositor` because that
   compositor is the tinywl-shaped default; a compositor removes them with
   `cf:remove-keybinding`.

**Evidence.** `scripts/grab-gate.sh`: a real libwayland client, with xdg-shell generated from our
vendored XML by `wayland-scanner`, asks to be moved with the serial from a button event we sent;
the window moves to the drag's delta, stops on the release and is not moved again; its pixels are
at the new position; a right-button drag produces `configure 240x180` from a 200x150 window and a
(40,30) drag; Alt+F1 raises the bottom of two windows and focuses it; Alt+Esc stops the loop; the
client is still connected at the end. Unit tests cover the rule the gate cannot show: a serial we
never issued, or a real one without focus, is refused, and a grab's second ending is a no-op.

**Consequences.** Escape-to-cancel is not installed by default: a compositor binds it to
`cf:end-active-grab`. Window menus, keyboard grabs, popup grabs, a focus stack and edge-anchored
resizing are the next slices; the grab object, the serial predicate and the key path do not change
when they arrive.

---

## D34 — The client speaks surfaces and shm, and a nested session is a headless compositor with a parent

**Status:** accepted

**Context.** Phase 3's last pieces needed two things the tree did not have: a client library that
can create and draw a surface (it could connect, bind, roundtrip and receive events, and nothing
else), and a backend that presents our output inside another compositor. Both were listed in
`docs/roadmap.md` under `cf.backend.nested`; neither needs libwayland, a display or hardware. The
live-session demo of a nested window needs its own authorization and was not part of this slice.

**Decision.**

1. **The client library implements the requests a compositor needs, one method per request, and
   nothing more**: surfaces and regions, shm pools and buffers, seat devices, and the xdg-shell
   toplevel handshake. Each method is a `check-live`, an id allocation where the XML has a
   `new_id`, and one `send-request`. A child speaks its parent's version, clamped to what the
   interface knows (`allocate-child`).
2. **A bound global gets the class its interface registered**, not a bare `proxy`: a class table
   keyed by wire interface name, filled at load time. Both directions use it — `bind` and a
   server-chosen id in an event. Without it `wl_seat.get_pointer` would return something with no
   methods, and the failure would appear one call later.
3. **`object-id-of` is a generic function, not an `etypecase`.** A `client-buffer` is not a proxy
   but attaches as one, so `ATTACH` takes the struct and the encoder asks it for its `wl_buffer`
   id. An `etypecase` in `proxy.lisp` cannot know about a class defined later in `shm.lisp`.
4. **The client owns a memfd and a read-write mapping; the compositor gets the descriptor once.**
   `wl_shm.create_pool` carries it as ancillary data and spends no octets on it (D23). The client
   keeps its own descriptor only because its mapping was made from it, and keeps the mapping for
   as long as its buffers live. Geometry is checked client-side before the wire: a buffer larger
   than its pool is a client bug, and the compositor's answer would arrive as a protocol error
   after the pixels were written.
5. **A nested session is a `headless-compositor` with two function slots**, `frame-preparer` and
   `frame-presenter`. Nothing in `cf.backend.headless` knows what a parent is: the preparer returns
   the target to draw into and the presenter is called after the scene is rendered and before the
   nested clients' frame callbacks fire. This is the backend seam `docs/framework.md` §2 asked
   for, at the size the second backend justified.
6. **The nested output is drawn straight into the parent's buffer.** The target is a pixman image
   over the `wl_shm` mapping (`make-target-over-pointer`), not a Lisp vector mirrored into one:
   there is no copy per frame, and `target-octets-copy` exists only for screenshots. Two buffers
   are used; a frame that finds both owned by the parent is **deferred**, not queued — the dirty
   flag stays set and the parent's `wl_buffer.release` re-arms the frame. The parent's
   `wl_surface.frame` callback is the frame clock: at most one frame is in flight.
7. **The parent sees an ordinary toplevel when it offers `xdg_wm_base`**: a title, an app id, an
   initial commit with no buffer to ask for a configure, `ack_configure` for every configure, and
   a `pong` for every `ping` (the pong lives in the client library: a client that ignores a ping is
   a client the parent may kill). A parent without xdg-shell gets a roleless surface, which our own
   headless compositor maps at the client's attach offset.
8. **The nested output's size is fixed at start.** A configure offering another size is
   acknowledged and its size ignored. A client may choose its own size, so this is legal, and
   resizing the inner output (scene dimensions, target, scene nodes) is a separate change; the
   nested window not following a parent-driven resize is a documented v0 limit. **Amended by
   D37 item 2**: the size now follows the parent, because a tiling parent's configure is how a
   nested session learns how much space it was given.
9. **Input crosses as reports, not as shared state**: a parent motion becomes
   `cf:inject-pointer-motion`, a button becomes `cf:inject-pointer-button`, a key becomes
   `cf:inject-key` after its evdev code is translated through our key table. Modifier masks are
   recomputed from *our* keymap by the one key path every backend uses, because the parent's masks
   belong to the parent's keymap and our clients are sent ours (D28). A key our table has no name
   for is dropped rather than guessed. The parent's keymap descriptor is read and closed — a
   client that never closes a received descriptor leaks one per keyboard.
10. **Two reactors, polled.** The parent connection and the nested compositor have separate epoll
    instances and `nested-dispatch` advances both; a merged wait is phase-4 work, and a nested
    session is a test and debugging backend. `start-nested` takes an optional `:pump` so that the
    in-process gate can run the parent's reactor while the nested backend waits, without the
    backend knowing the parent is in the same image.

**Evidence.** Gate clause 15 (`scripts/nested-gate.sh`): one image, two sockets, a real
`weston-eventdemo` inside the nested session. The parent maps our window with the title and app id
we sent and configures it activated; the parent's frame equals the nested compositor's own target at
five sample points and has content of its own; a pointer motion and a Shift+q injected into the
*parent* are printed by the client inside the *nested* session at the same coordinates with
unicode 81 and mask 0x1; the parent's keymap descriptor crossed (6978 octets); teardown removes the
parent's toplevel, empties its client list and leaks no descriptors. Eight new client tests pin the
wire: the request opcodes and argument order for surfaces, regions, seats and xdg-shell, that a
pool's descriptor really is attached and names the same file as our mapping, that pixel helpers
check bounds, and that a `ping` produces a `pong`.

**Consequences.** Nesting into a *foreign* compositor on the live session is possible now but is
not demonstrated here: it needs a window on the user's session and its own authorization. Client
cursor surfaces, buffer scale and transform, damage-driven partial updates, popups, and a merged
reactor wait are the next slices; none of them changes the seam this decision introduces. A trap
worth recording: `wl_keyboard.release` and `wl_touch.release` are opcode 0 (the interfaces have no
other request), not opcode 1 like `wl_pointer.release`.

---

## D35 — A render target's pixels live in foreign memory, and C never keeps a pointer to a Lisp object

**Status:** accepted

**Context.** Phase 2a put a render target in a Lisp octet vector: convenient to allocate, easy to
read back, and pixman draws into it in place. The pixman image is created once, in `make-target`,
and holds the vector's address for the life of the image. Phase 3e's nested backend needed a
target over a `wl_shm` mapping, which prompted a second look — and a unit test that forced a full
GC between creating a target and drawing into it failed 100% of the time: the vector had moved,
pixman was still writing to the old address, and `frame-pixel` read the new one, so the frame was
background with no error anywhere. The same latent bug had been producing a rare flaky failure in
the cursor tests (about one run in ten under CPU load) since phase 3c.

**Decision.**

1. **Targets own foreign memory** (`make-target` uses `cffi:foreign-alloc`), and
   `make-target-over-pointer` is the same shape over memory someone else owns (a `wl_shm`
   mapping). The two differ only in who frees the memory; `destroy-target` releases the image and
   only frees what `make-target` allocated.
2. **Readback copies** (`target-octets-copy`) instead of returning a vector that is the target.
   The PNG writer and tests use it; the render path never does.
3. **A Lisp vector may be handed to C only inside the call that uses it.** The cursor bitmap is
   the remaining case: it is copied through `with-pointer-to-vector-data` for the duration of one
   `composite32`, and the pixman image over it is unref'd before the block ends. Nothing keeps a
   SAP to Lisp memory across calls.
4. **The regression is a test, not a comment**:
   `a-target-survives-a-full-gc` runs a full GC between creating the compositor and rendering, and
   asserts the cursor's white pixel is still there. It is in the suite because this failure is
   invisible without forcing it.

**Evidence.** Before the change, a script that allocates, calls `(sb-ext:gc :full t)`, then
renders reported `stored #x12024C2A40 vector-now #x1200D23FC0 image-data #x12024C2A40` — the
image pointed at the old address after the vector moved — and `frame-pixel` returned the
background; the same script after the change returns `#xFFFFFFFF`. The new unit test fails on the
old code and passes on the new. The unit suite is 201 tests and passes repeatedly under CPU load,
where the cursor flake used to appear.

**Consequences.** A target is no longer a Lisp vector, so anything that wants to read pixels does
a copy; `target-octets` is gone. `fill-target` writes word at a time through `cffi:mem-aref`
(slower than a vector loop, and invisible next to compositing). The nested backend and the
headless backend now share one target representation, which is why the nested path could render
straight into the parent's buffer with no copy in the first place.

---

## D36 — A compositor is a subclass, a press is policy, and tinywl places at the origin

**Status:** accepted

**Context.** Phase 3's exit slice is `cl-tinywl`: a working port of tinywl.c over the
framework. Everything tinywl.c is *made of* — the event loop, xdg-shell, the seat, the keymap,
the scene, the renderer, the frame clock — already existed, so the slice was going to be small.
Two things stood in the way of it being only policy. The framework built a fixed class
(`headless-compositor`) with no way to specialise behaviour, and it decided for the compositor
what a pointer press meant. And a client's `set_cursor` surface, which nothing draws yet, was
being given a scene node like any other surface: at (0,0), hit-testable, and first in the stack
order, where the parity gate's Alt+F1 promptly raised a 32x32 arrow instead of a window.

**Decision.**

1. **`make-headless-compositor` takes `:compositor-class`,** defaulting to `headless-compositor`,
   and `headless-compositor` is exported. A compositor subclasses it and passes its own class;
   `cf:on-new-toplevel` and the new `cf:on-pointer-button` dispatch on that object, so the class
   *is* the policy (D7: classes, not vtables). `start-nested` takes the same keyword and passes
   it through, because a nested session is a session of *this* compositor: the same methods must
   see input that arrived through a parent's seat.
2. **A pointer press is a generic function** (`cf:on-pointer-button`). Its default method is
   D32's rule unchanged: focus what is under the pointer, then send the button. A compositor
   specialises it and calls `call-next-method` for the presses it does not want — and a press
   it consumes is a press the client never sees, so the client must not see the release either.
   A grab still takes precedence: while one holds the pointer, no policy is consulted.
3. **A client's cursor surface is not a window.** `wl_pointer.set_cursor` records the surface;
   `ensure-scene-node` refuses it, so it is neither drawn, nor hit-tested, nor raised. Drawing
   it is phase 5, and a compositor's own cursor is what v0 draws.
4. **`cycle-views` cycles windows, not buffer nodes** (`window-node-p`: a buffer node whose
   surface has a shell role). The two bugs in 3 and 4 are the same mistake, and the parity gate
   found both.
5. **A move or resize request whose button is already up starts no grab.** The grab must end on
   the button that began it; a request that arrives after that release (a click whose press and
   release were read in one dispatch, which is what injected input does) would otherwise leave
   the pointer owned by a drag nobody is making, and the next click would go to the grab instead
   of the window. This is how `dragged-button`'s `#x110` default went away.
6. **cl-tinywl is tinywl.c's policy, including its placement.** Every window goes to the output
   origin, overriding the framework's cascade: the stack is the layout, and a port that quietly
   improved on the original would make the comparison meaningless. Where it differs, it says so:
   tinywl.c has no compositor-side drag (its moves and resizes come from a client's titlebar
   request, gate clause 14), and PLAN.md's exit gate asks for one, so Alt+left moves a window and
   Alt+right resizes it from the edge under the pointer, choosing the edge with a 12-pixel margin
   and defaulting to the bottom-right. `install-keybindings` *replaces* the framework's default
   table rather than adding to it, and Alt+Esc sends `xdg_toplevel.close` to every mapped window
   before stopping the loop — one request, and the difference between a session that ends and one
   that is cut off.

**Evidence.** Gate clause 16 (`scripts/tinywl-parity.sh`), which runs the same scenario twice:
31 checks headless and 33 nested (the two extra are the parent's teardown), each with two real
libwayland clients — `weston-eventdemo` printing every key and every configure, and the compiled
move client as a uniform green window. Headless and nested: both windows land at (0,0); the top
window's pixels are at the sample point and the lower one's come back when it is dragged aside
by exactly the pointer's delta; the click moves the keyboard; the focused client prints
`key key: 16, unicode: 81` and the unfocused one prints nothing further; Alt+right at the corner
puts `resize width: 240, height: 180` in the client's output and yields a 240x180 buffer; Alt+F1
raises the bottom window; Alt+Esc stops the loop with both clients still connected, closes them
by request, and no `wl_display.error` in either client's `WAYLAND_DEBUG=1` stream, which is also
checked for an ordered `get_registry` → `configure` → `ack_configure`. The nested run ends with
the parent holding no window and no clients of ours. Eleven unit tests (`wayland.test.tinywl`)
pin the parts a gate cannot isolate: `edges-at` at every side and corner, placement at the
origin and stacking, a move grab following the pointer's delta and stopping, a resize grab asking
for the size the drag implies without resizing the node, Alt+left/Alt+right starting the right
grabs, a plain press not starting one, Alt over the bare output not starting one, the bindings
being tinywl's own, Alt+Esc stopping the reactor, and `:compositor-class` being honoured. The
suite is 212 tests in 10 suites.

**Consequences.** Adding a compositor's behaviour no longer needs a framework change: subclass
what is there, specialise the two `on-*` generics, and pass the class in. Anything that treats a
`buffer-node` as a window must now ask `cf.backend.headless:window-node-p` (or check the shell
role itself), because cursor surfaces and roleless surfaces are buffer nodes too. Client cursor
surfaces are recorded and ignored rather than drawn — a visible gap, listed as phase 5, not a
silent one. Popups, the focus stack, edge-anchored resizing and a nested window on a *foreign*
compositor remain the rest of phase 3.

---

## D37 — A nested output follows the parent's size, a press may start a client, and a focus event never names another client's surface

**Status:** accepted

**Context.** The phase-3 exit slice shipped and the first manual test of it produced three
findings, none of which a gate had asked about. The nested window appeared too small for the
space the session had given it. Nothing could be started *inside* it: the environment's
`WAYLAND_DISPLAY` names the parent, so a client started from a shell lands outside the window
you meant — and `kitty` needs an EGL surface, `xterm` needs XWayland, so neither could work
anyway. And the first launcher that did connect (`weston-terminal`) was killed immediately by a
protocol error: `invalid object (3), type (wl_shm_pool), message enter(uoff)`.

**Decision.**

1. **A press is where a client may come from.** `tinywl:launch` starts a command as a client of
   *this* compositor's display: the child inherits our environment with `WAYLAND_DISPLAY`
   replaced by our own socket name, through `/bin/sh` so `HOME`, `PATH`, `TERM` and the locale
   survive (`:environment` would replace all of it). `Alt+Shift+Return` binds it, not
   `Alt+Return`: the latter is every compositor's "open a terminal", so a parent session would
   take the key before a nested tinywl saw it. `*terminal-command*` is a special variable, so
   what to launch is policy the REPL can change (D14); `weston-terminal` is the default because
   it is toytoolkit over `wl_shm` and works on this renderer today. `--launch CMD` does the same
   at startup, which matters when the parent has the key bound: then there is no key to press.
   `stop` closes the display first, so the clients see EOF, and signals whatever is left.
2. **The nested output follows the parent's configure.** A `xdg_toplevel.configure` carrying a
   non-zero size resizes the output, the scene and the shm buffers (new pool, new buffers, new
   pixman targets over their mappings). This supersedes D34.8. A tiling parent configures the
   slot it gave us; ignoring that drew a 1024x640 window inside a much larger slot, which is
   what "too small" was. A configure of 0x0 is "choose for yourself" and changes nothing. Inner
   clients are not resized — a client's size is its own statement — so a window may end up larger
   than the output, which is the same thing that happens on a small screen. The default output
   size also went from 512x512 to 1280x800: the old number was one a *test* liked.
3. **A focus event never names another client's surface.** `wl_seat.get_pointer` and
   `get_keyboard` send `enter` immediately when the seat already has focus, so a new client does
   not have to wait for a motion — and they sent the *focused surface* whatever client it belonged
   to. An object id means nothing across connections: the new client reads it as whatever holds
   that id in its own table. That is the bug in the context, exactly: weston-terminal's id 3 was
   its shm pool, we named client 2's surface 3, and libwayland killed the connection with the
   error above. Both now check `(eq (resource-client focus) client)` first; the client gets its
   real `enter` at the next motion or focus change. A stale `wl_output` is the same mistake from
   the other direction, so `client-output` also drops an output the client has released instead of
   naming a recycled id.

**Evidence.** Gate clause 16 grew to 32 checks headless and 38 nested. Both runs now start a
client through the key binding and require a *new* client on our own display with a mapped,
non-zero window (weston-terminal, three clients in total). The nested run also configures the
nested toplevel from the parent side (`request-toplevel-size 800x600`) and requires the inner
output, the scene and a fresh presented frame to follow it, with the window that was inside still
drawn at its old position. The seat bug is what the launcher check found: before the fix the
terminal connected and was disconnected within a second, in the nested run only, because that is
the first time a client has ever connected while another client's surface held the focus. Two
unit tests join it: `resizing-an-output-resizes-the-scene-and-the-target` (the target is
replaced, not written past its end) and a third keybinding in
`tinywl-installs-its-own-bindings`. 214 tests in 10 suites.

**Consequences.** A nested session is usable by hand: start it, get a terminal, type in it. What
it still cannot do is what a *terminal* needs to be pleasant — clipboard (no data device, phase
6), file dialogs and menus (no `xdg_popup`), crisp text on a 2x output (buffer scale, phase 2b)
— and the parent has first refusal on any chord it binds, `Mod1+Shift+Return` included, so
`--launch` is the reliable path on a live session. `wl_pointer.enter`/`wl_keyboard.enter` to a
*new* device while another client is focused is now silent until the focus changes, which is
correct but worth knowing when reading a trace.

## D38 — A frame is presented after it is drawn, and a presenter is handed pixels, not a promise

**Status:** accepted

**Context.** The second manual test of the delivered tinywl slice reported two symptoms that
looked unrelated: the nested window flickered severely whenever the pointer moved, and a
terminal that mapped second was only partly visible — the window above it black below its first
line, its own body a title bar and one line of prompt. Both are one bug. `render-frame` called
the backend's presenter — attach, damage, commit, flush — *before* `scene:scene-render` painted
the scene into the target.

D34.5 already said the presenter is "called after the scene is rendered and before the nested
clients' frame callbacks fire", and `docs/framework.md` §2 said the same, so this was a
phase-3e regression against a decision rather than a missing one. The gate could not see it: the
nested run's parent lives in the same image, so it composites only after we have finished
drawing, by which time the buffer we committed *has* been painted. A real parent composites
whenever it likes. A probe made the difference visible in numbers: with one `weston-simple-shm`
window, every presented frame carried **0** sampled non-background pixels while the drawn target
held 7384, and a PNG of the parent's composited output taken inside the commit window was black
apart from the parent's own cursor. After the ordering fix the same probe reads 7384 at commit,
and the parent's output is the client's frame.

The mechanism is worth stating because it is a property of the seam, not of tinywl: a nested
target *is* the parent's `wl_shm` mapping. Committing it hands the parent a buffer to read at a
moment of its own choosing, so pixels written after the commit are pixels the parent may or may
not see. A motion that produces one frame per event then shows the parent an alternating mix of
background and half-painted frames — the flicker — and the frame a client stops at (its last one,
with nothing further dirty) can be the one the parent never sees — the half-drawn window.

**Decision.** The frame order in `render-frame` is fixed and is the whole of this decision:

1. **fill** the target with the background;
2. **prune** surfaces that are gone or unmapped;
3. **draw** the scene (`scene:scene-render`);
4. **present** — the backend's presenter, given a target that already contains the frame it is
   asked to present;
5. **release** each drawn surface's buffer and fire its frame callbacks.

Presentation stays before the release loop, not after the callbacks: a client whose buffer is
back may redraw at once, and D25's rule is that the release happens at presentation. What is
forbidden is presenting a target that has been cleared but not drawn, because "committed" then
means nothing about the pixels. A presenter is therefore handed *pixels*, and a backend that
wants them earlier has the wrong contract.

**Evidence.** Gate clause 16 grew by one check, nested only, because the presenter exists only
there: it wraps the presenter, asks for three frames, and requires the target to hold
non-background pixels at every one of them (`lit-pixel-count`). Run against the old order it
fails with `(0 0 0)`; against the new one it passes. Clause 16 is now 32 checks headless and 39
nested — 71 in two runs — and the gate is 16/16. 214 tests in 10 suites are unchanged: the
ordering is a property the gate can observe with a real client and a real parent, and a unit
test with a stub presenter would only restate the source.

**Consequences.** A nested session's frames are now what the parent shows, so the manual test's
flicker and its half-drawn window are the same fix. Two things it does not change: v0 still
repaints the whole target and damages all of it every frame (2b), so a moving pointer produces a
full-window frame per motion event — correct now, but more work per event than a damaged frame
would be; and the parent still upscales our 1x buffer on a 2x output, which is the blur D29
records. The general lesson is recorded here rather than in the code alone: **a shared-memory
target must be announced only after it is final, and the gate for a cross-process seam has to
composite on the far side of that seam.** An in-image parent is a test double for the *protocol*,
not for the *timing*.

## D39 — The pointer's image is the backend's business, and a nested session draws none

**Status:** accepted

**Context.** The third manual test, of the build with D38 in it, showed two pointer images
stacked at the same place inside the nested window: a small plain white arrow, and a themed
arrow with an outline at a larger size. The small one was ours — `cf.scene`'s 16x16 built-in
cursor, drawn into the output and then upscaled by a parent running at scale 2. The larger one
was the parent's own cursor, which that compositor draws over *every* surface it displays,
including ours. Two cursors at one pointer position is not a rendering detail: it is a wrong
picture, and it is what "some pointer image handling bugs" looked like.

The code had made this likely in two ways. `render-frame` never looked at
`compositor-cursor-visible-p` — the slot existed, was exported, and was read by nothing, so a
backend that wanted no cursor had no working way to say so. And nothing about the nested
backend said whose image the pointer is.

Related, and worth recording while it is in view: the client-set cursor
(`wl_pointer.set_cursor`) is still ignored by design (phase 5, `cursor-surface-p`), which is why
weston-terminal's own I-beam and arrow never appear inside the window. The
`could not load cursor 'dnd-copy'` / `'dnd-none'` lines in a session log are that client's own
cursor-theme lookups failing — no installed theme ships those names — and are not ours to fix;
they are also the clearest evidence that clients are asking for cursors we do not honour.

**Decision.**

1. **One flag, projected where it is used.** `COMPOSITOR-CURSOR-VISIBLE-P` is the compositor's
   statement about whether its output draws a pointer image; `render-frame` copies it onto the
   scene's `SCENE-CURSOR-VISIBLE-P` immediately before drawing. The scene keeps its own flag
   because `SCENE-RENDER` must stay usable on a bare scene (the unit tests do), but a session
   sets the compositor's. The previously dead accessor now means what its name says.
2. **A nested session draws no cursor.** `start-nested` sets the flag to NIL: the parent draws
   the pointer over our surface, from its own theme, at its own scale and size. Ours would be a
   second arrow, blurrier, and the wrong size wherever the parent is scaled. This is what other
   nested compositors do (weston's X11/Wayland backends, wlroots' embedded backends), and it is
   the honest division: the compositor that owns the seat owns the pointer's picture.
3. **A client's cursor surface still does not appear** (phase 5). Hiding our own cursor makes
   the parent's themed pointer the one a person sees, which is right for a nested session and
   wrong for a bare one — in a headless or a finished compositor, phase 5 is where a client's
   cursor image gets drawn, from the surface and hotspot the seat already records.

**Evidence.** Gate clause 16 grew by one check, in both runs, asserting the pixel at the parked
pointer with a per-mode answer: headless it is the cursor's white body (`#xFFFFFFFF`, drawn by
this session), nested it is the background (`#xFF000000`, left to the parent). Run against the
old behaviour the nested run fails it with `#xFFFFFFFF` — the doubled arrow, in a number. 33
checks headless, 40 nested, 73 in two runs; the gate is 16/16 and the suite is 214 tests in 10
suites, with `a-hidden-cursor-is-not-drawn` now setting the compositor's flag rather than the
scene's.

**Consequences.** The nested window shows one pointer, the parent's. What this does *not* fix:
the inner output is still 1x and upscaled by a scaled parent, so text is soft (D29, phase 2b);
a client's own cursor image is still not drawn anywhere (phase 5); and a nested session cannot
change the parent's cursor shape (that needs `wp_cursor_shape_v1`, or `wl_pointer` constraints
for pointer lock — neither is in the plan's phase 3). The general lesson: **a flag with no
reader is a bug report waiting to be written.** This one was exported, documented in the package
and read by nobody, which is exactly how a backend ends up drawing a second cursor because there
was no supported way not to.
