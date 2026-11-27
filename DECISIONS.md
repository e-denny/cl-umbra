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
   **Revised by D41:** hiding our cursor is only half of that division. The other half is drawing
   the *client's* image, and the session keeps its own arrow as the fallback — the parent is
   blanked for as long as we are the ones drawing. `start-nested` no longer sets this flag.
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

## D40 — A surface a client names as its cursor image is never drawn, in either order

**Status:** accepted

**Context.** The fourth manual test, of the build with D38 and D39 in it, found two pointer
images again — but a different pair: the parent's cursor, which follows the mouse, and a *second*
one stuck in the nested window's top-left corner that changed shape as the pointer crossed the
inner terminal's borders (an arrow in the body, a left-edge resize cursor on the border). A
shape that changes when the *client* changes it is the client's own cursor image: weston-terminal
installs one with `wl_pointer.set_cursor`.

A cursor surface has no shell role, so it takes the framework's roleless path, which exists so
that phase 2a could draw a bare `wl_surface`: a scene node at the scene origin, drawn where the
client's attach offset says. `cursor-surface-p` was supposed to keep cursor surfaces off that
path, and it asks the seat a narrow question — *is this surface the pointer's image now?* — which
leaves two holes.

1. **Ordering.** `wl_pointer.set_cursor`'s image takes effect at the surface's *next* commit, so
   both "name then commit" and "commit then name" are legal. In the second order the commit sees
   a surface that is not yet anybody's cursor, gets a node, and keeps it: the image then sits at
   the output's origin and updates whenever the client changes it. That is the stray cursor.
2. **Nothing could take a node back.** `ensure-scene-node` gave a roleless surface a node but
   never recorded it in `SURFACE-SCENE-NODE` — only `on-new-toplevel` did that, and that runs for
   shell surfaces. A roleless node was therefore invisible to everything that finds a surface's
   node by looking at the surface: `prune-surfaces` could not remove it when the surface unmapped
   (a latent leak of nodes for bare surfaces, found while fixing this), and a cursor image that
   had been given one could not be withdrawn.

**Decision.**

1. **A roleless surface records its node.** `ensure-scene-node` sets `SURFACE-SCENE-NODE` for the
   bare-surface case as well, so "the node this surface is drawn through" is a fact for every
   surface that has one. A consequence worth stating: a node whose surface unmaps is now removed,
   which is what `prune-surfaces` always meant to do.
2. **Being named as a cursor image is durable.** A new hook, `WAYLAND.SERVER:SEAT-CURSOR-CHANGED`
   (default: do nothing, the `seat-focus-changed` pattern), is called by `wl_pointer.set_cursor`.
   The framework's method sets `SURFACE-POINTER-IMAGE-P` for good and withdraws any node the
   surface already has. The protocol gives a surface no way back to another role, so a mark that
   never clears is the honest model.
3. **Two guards, two questions.** `cursor-surface-p` keeps answering "is it the cursor *now*"
   (cheap, and it stops the node being created at all in the ordinary order); the flag answers
   "has any client ever named it". `ensure-scene-node` refuses on either.
4. **Client cursor images are still not drawn** — phase 5. What a person sees is the
   compositor's own cursor, or, in a nested session, the parent's (D39). This decision is only
   about never drawing one by accident, at the wrong place.

**Evidence.** A probe with a real headless compositor and a hand-made cursor surface, in both
orders: committed-then-named created a node (`node T`, no flag) before the fix, and after it the
same sequence leaves `node NIL` with the flag set, while named-then-committed never creates one.
The unit test `a-surface-named-as-the-pointer-image-is-never-drawn` asserts the node *slot* rather
than the return value of the creating call — "the commit created nothing" and "the surface is
still drawn through the node it had" are different states — and deleting the withdrawal makes it
fail, which is how the assertion earned its place. Gate clause 16 grew by two checks in both runs:
a real `weston-terminal` names two cursor surfaces out of five, and none of them has a scene node.
35 checks headless, 42 nested, 77 in two runs; the gate is 16/16 and the suite is 215 tests in 10
suites.

**Consequences.** The stray cursor is gone for both orderings, and it goes away on the next
`set_cursor` in a session that already has one. Bare surfaces' nodes are now pruned when they
unmap, which is a behaviour change worth knowing when reading the shm gate's expectations
(`surface-scene-node` is no longer NIL for a roleless surface). What this does not do: draw a
client's cursor image (phase 5 — it needs the hotspot the seat already records and the
`wl_surface`-as-cursor path this decision deliberately keeps out of the scene), or make a nested
session able to change the parent's cursor shape. The lesson, recorded because it took four manual
tests to surface: **a role object whose state is only ever added is a state machine missing its
exit, and a guard that asks "is it X now" cannot defend a surface that will become X later.**

## D41 — The pointer's picture follows the client, and a nested session lends its pointer out

**Status:** accepted

**Context.** D39 stopped a nested session drawing a cursor of its own, because the parent draws
one over the same spot. That was right about the *doubling* and wrong about the *shapes*: the
fifth manual test found that a terminal's I-beam over its text, its arrow over its title bar and
whatever a client says its frame edge means never appeared at all. What a person saw was one
arrow everywhere. The client's contribution to the cursor — "the pointer *means* this here" — was
being recorded by the seat (`wl_pointer.set_cursor`, since the first slice) and then thrown away,
because D40 kept that surface out of the scene and nothing else drew it.

**Decision.**

1. **A client's cursor image is drawn, at pointer minus hotspot.** `SCENE-RENDER` draws
   `SCENE-CURSOR-SURFACE` when that surface has a current buffer (and has not been destroyed),
   at `(pointer - hotspot)`, and falls back to the built-in arrow otherwise. This is the one place
   the hotspot means anything, so it is where it is applied. The image is *not* released per
   frame: a cursor image is held until the client replaces it, which is what cursor images expect
   (`wl_buffer.release` for a picture that is redrawn every frame would let a client rewrite the
   pixels under the pointer).
2. **The frame path asks, rather than being told.** There is no event that says "the pointer's
   picture changed and a frame is due": a client may name an image and commit nothing, and a
   client that hides its cursor sends no commit at all. So `render-frame` compares the scene's
   image with `SEAT-POINTER-CURSOR-IMAGE` — the cursor image of the pointer whose client has
   *pointer focus* — and marks the frame dirty when they differ. One comparison per frame, and it
   cannot go stale the way a missed event would.
3. **The division is by picture, not by session.** A nested session draws the client's image and
   tells the parent to draw nothing while it does — `wl_pointer.set_cursor` on the *parent*
   connection with a 1x1 fully transparent shm image of our own — and gives the parent its cursor
   back (`set_cursor` with no surface) when there is no client image to draw. Over the bare
   output, and over windows whose clients set none, the parent's cursor is what a person sees,
   which is the "the outer cursor becomes the background cursor" half of the expectation.
   `COMPOSITOR-CURSOR-VISIBLE-P` (D39) keeps its narrow meaning: whether *this session's own*
   arrow is drawn. A client's image is the client's, and is drawn when it exists.
4. **`WL_POINTER.SET_CURSOR`'s serial is now kept** on the nested backend's parent pointer, because
   set_cursor requires the serial of a recent enter and the session is now a client that sets one.

**Evidence.** A finer probe over a real `weston-terminal` (headless and nested) shows the client's image
arriving and changing with position: hotspot (11, 12) over the text area (its I-beam), (6, 13)
over the frame's left band and (13, 6) over the title bar (its resize and move cursors), and no
image at all over the frame's shadow or the bare output -- which is exactly the sequence a person
crosses the window with.  The first coarse sweep missed the frame band by two pixels and reported
"one image everywhere"; that is worth recording as a caution about sampling a 12-pixel border. A frame dump
of the headless session with the pointer over the text area shows an I-beam drawn from the
client's own buffer, centred on the hotspot — the picture the manual test asked for. In nested
mode the same probe shows the parent's pointer holding our 1x1 blank while the client's image is
drawn and nothing of the sort at a bare-output spot. Gate clause 16 grew by these checks in both
runs — "the client's cursor image became the pointer's picture", "...is the focused pointer's,
hotspot (11, 12)", and nested-only "the parent is told to draw no pointer", "with a 1x1
transparent image", "over the bare output there is no client image" — 36 checks headless, 52 nested
after D42's four, 92 in two runs; the gate is 16/16 and the suite is 218 tests in 10 suites.

**Revised after the sixth manual test.** Two things were wrong. First, a nested session still hid
its *own* cursor, so with no client image there was nothing to draw at all: the pointer disappeared
when it moved from a window onto the bare output, and came back only after leaving the window
entirely (the parent shows its own cursor over its own surfaces). Second, "give the parent its
pointer back" was built on a wrong reading of the protocol: `set_cursor` with no surface means *hide
the cursor* to a compositor, not "use your default". So the rule is now: a nested session owns the
pointer's picture for as long as it exists — it blanks the parent once and again on every enter, and
draws the client's image or, failing that, its own arrow. That makes the background pointer our
16x16 stub rather than the parent's themed one, upscaled on a scaled output; it is the honest
picture, and it is what phase 2b and phase 5 (scale, cursor themes) improve.

**Consequences.** Cursor shapes now change the way a client means them to, in a nested session and
in a headless one, and the nested window shows exactly one pointer at a time — the client's image
where the client has one, this session's arrow everywhere else. What this does not
do: scale the cursor (a 24x24 image on a 2x parent is still upscaled and soft — phase 2b), animate
it (several images per `set_cursor` is `wl_cursor` frame timing, phase 5), or honour a parent that
ignores `set_cursor` from its own clients (a compositor that does would leave its cursor under
ours; ours takes the serial and asks, and that is all a client can do). The lesson, which is D39's
from the other side: **hiding your own cursor is only half a decision — the other half is drawing
somebody else's.**

## D42 — A resize moves the edge under the pointer, and a client's border is a border

**Status:** accepted

**Context.** The sixth manual test reported two things that turned out to be one interaction seen
from both ends. Dragging the left border of a `weston-terminal` resized from the *right* and
bottom edges — the edge under the pointer did not move. And that was true even when the grab did
pick the left edge, because an interactive resize only asks the client for a size: the node's
position was never touched, so the window grew and shrank from its top-left corner and the
opposite edge moved by itself.

Two separate mistakes, then, and the first one hid the second:

1. `tinywl:edges-at` measured its 12-pixel grab margin from the **surface's bounding box**. A
   client with client-side decorations sets an input region that excludes its shadow —
   weston-terminal's is `(32 32 742 499)` inside an 806x563 surface — so its *visible* left border
   is 32 pixels in from the box. A press there was 34 pixels from the box's edge, read as "the
   body of the window", and the body means the bottom-right corner: the resize then moved exactly
   the two edges the pointer was furthest from.
2. Nothing anchored the opposite edge. That was a documented v0 limitation ("until the client
   comes back with a buffer of the requested size there is nothing to anchor"), but the anchor was
   never needed to be guessed: the client's *actual* size arrives as a buffer.

**Decision.**

1. **The grab margin is measured from the part of the window a pointer can reach.**
   `TINYWL:POINTER-REACH` returns the node's rectangle intersected with its surface's input region
   (its bounding box, when there are several rectangles), in output space; `EDGES-AT` measures
   from that. A surface with no input region — every client that does not decorate itself — is its
   own reach, so the old behaviour is the fallback rather than the rule. A client's own border is
   then a border, which is also where the client draws its resize cursor, so the edge the pointer
   is pressing is the edge the picture says it is.
2. **A resize anchors the edge opposite the one being dragged.** `begin-resize-grab` records the
   position of the opposite edge (`anchor-right`, `anchor-bottom`), and `GRAB-ANCHORED` puts the
   node back so that edge stays put **using the node's actual size**: `x := anchor-right - width`
   for a left-edge drag. It is called from `grab-motion` (the client may already have answered an
   earlier event) and from `SURFACE-COMMITTED` (the answer arriving while the pointer is still). The
   window therefore never slides while its content does not: the node moves only when the client's
   size does.

**Evidence.** A probe with a real `weston-terminal` and an `Alt+right` press on its visible left
border: the grab is a `resize-grab` with `+edge-left+` (before the reach fix it was the body, i.e.
bottom-right), the drag asks for 220x180 from a 240-wide window, and afterwards the node is at
x=20 with its right edge still at 240 — the left edge followed the pointer, the right one did not
move. Gate clause 16 grew by four checks in each run ("alt+right on the left border grabs the left
edge", "the left drag asked for 220", "the window's left edge followed the pointer", "and its right
edge did not move"): 40 checks headless, 52 nested, 92 in two runs; the gate is 16/16 and the suite
is 218 tests in 10 suites, with `a-client-border-is-where-the-pointer-can-reach-it` (the reach, and
the fallback for a client with no input region) and
`a-resize-keeps-the-edge-opposite-the-dragged-one-still` (the anchor arithmetic, and that a
right-edge drag leaves the left edge alone).

**Consequences.** Dragging any border resizes from that border, in either the compositor's grab
(`Alt+right`, now reachable on all four sides) or the client's own request. Two things it does not
do: honour a *minimum* size the client sets (`xdg_toplevel.set_min_size` is recorded nowhere yet, so
a client can be squeezed past its own minimum until it clamps itself), and keep the anchor for the
*duration of a client-initiated* resize that the client finishes after the grab ends — the anchor
is applied while the grab is active and on the commits that arrive during it, which is the whole
drag. The lesson is the one this slice keeps teaching: **"the body" and "the border" are decisions
that need the same geometry the pointer does, and a client's decoration is part of its geometry.**

## D43 — A window is dragged inside its output, and a resize speaks geometry

**Status:** accepted

**Context.** The seventh manual test found two things, both about a drag not matching the
pointer. Resizing a `weston-terminal` from its frame jumped by a large amount on the first small
motion and then tracked 1:1. And a window could be dragged out of the nested output entirely,
where it could not be seen or clicked again — worse, with the outer pointer off the window the
grab outlived its pointer, so the session kept moving a window nobody was dragging.

The jump had one cause. `xdg_toplevel.configure`'s size is the surface's **window geometry**, and
`xdg_surface.set_window_geometry` is where a client declares it. `cf.grab` did its arithmetic in
*buffer* coordinates: a client with client-side decorations answers a buffer-size request with a
window 68 pixels wider than asked (weston-terminal's geometry is `(32 32 742 499)` inside an
806x563 buffer), so the first configure already moved the edge by the decoration and every motion
after it moved it by the drag. The server has stored the geometry since the xdg-shell slice, with
a note that nothing read it yet.

The lost window had two causes as well: nothing clamped a move, and a grab only ended on the
button that started it — a button that a nested session never sees released once the outer pointer
has left its surface.

**Decision.**

1. **Resize arithmetic is in window geometry.** `CF.GRAB:NODE-GEOMETRY` returns a node's geometry
   `(x y width height)` from its surface's `xdg_surface.set_window_geometry`, falling back to the
   node's own size for a surface that sets none. `begin-resize-grab` starts from the geometry size
   and anchors the *geometry's* opposite edge in output space; `grab-anchored` places the node so
   that edge stays where it was; `grab-resize` asks for a geometry size, which is what a configure
   means.
2. **A move is clamped to the output it lives in.** `CLAMP-TO-OUTPUT` keeps a window that fits
   fully inside the output and lets a window larger than the output be moved only as far as the
   output's opposite edge, so it always covers part of the output rather than sliding off it.
   `begin-move-grab` takes the output size (`:output-width`/`:output-height`, both NIL meaning
   "unbounded"), and both call sites — the framework's `toplevel-move-requested` and cl-tinywl's
   `begin-interactive` — pass their compositor's size. The *pointer* is deliberately not clamped:
   it is where the device says, and the point is that the window stops while the pointer may not.
3. **A pointer that leaves the output ends the grab.** `cf:inject-pointer-motion` ends an active
   grab when the position is outside the output, with reason `:pointer-left-output`. A drag whose
   pointer is gone is a drag nobody is making, and a nested session receives exactly that as a
   `wl_pointer.leave` from its parent. (A grab that outlives its pointer also leaves the *next*
   press going to a grab instead of to the window, which is the failure this prevents.)
   *(Refined by D47: a position outside the output is now clamped for the grab, and a grab ends
   only when the backend says the pointer left. The reason above still holds for that case — a
   leave is a pointer that is gone — but it was being inferred from a coordinate, which ended
   drags that were still meaningful on the other axis.)*

**Evidence.** A probe with a real `weston-terminal`: a left-edge drag of 50 pixels asks for a
geometry of 692 (from 742) rather than the buffer's 806, the client answers 688 (its own 2-pixel
frame rounds the request), and the *visible* right edge — node x + geometry x + geometry width —
is 774 before and after. Dragging the window far past the output's corner leaves it at (312, 362)
in a 512x512 output, i.e. flush with the corner, with the pointer itself still at 511. A pointer
moved to (-1,-1) during a drag leaves `compositor-grab` NIL. Gate clause 16 grew by eight checks
across the two runs: the clamp and the pointer position, the leaving-the-output release, and on a
decorated window "it has client-side decorations", "alt+right just inside the visible left border
grabs the left edge", "the visible right edge did not move (774 -> 774)", "and its geometry shrank
by the drag (742 -> 688)". 48 checks headless, 60 nested, 108 in two runs; the gate is 16/16 and
the suite is 221 tests in 10 suites, adding `a-move-is-clamped-so-the-window-cannot-be-lost` (both
branches of the clamp), `a-grab-motion-clamps-a-move-to-the-output` (and that the pointer is not
clamped) and `a-window-with-no-geometry-is-its-own-buffer`.

**Consequences.** Dragging and resizing now match the pointer, for decorated and undecorated
clients alike, and a window cannot be dragged out of reach. What this does not do: clamp a *resize*
to the output (a window may grow past the edge, which is a different decision — some compositors
allow it, some do not), keep the node inside on an output that shrinks under it (a configure that
shrinks the output leaves windows where they are, as D37 says), or account for a client that
changes its window geometry mid-drag (the anchor is recomputed from the geometry as it is now, so
it follows the client's own statement). The lesson: **a compositor that speaks buffer coordinates
to a client is speaking a different language than the one the client answers in — and a drag is
only as good as its bounds.**

## D44 — A popup is placed by arithmetic against a box the compositor names, and a menu belongs to its window

**Date:** 2026-11-26
**Status:** accepted
**Slice:** `xdg_popup` + `xdg_positioner`

`xdg_wm_base.create_positioner` and `xdg_surface.get_popup` were the last two v1 requests that
answered `implementation` ("not built yet"), and the header of
`cl-wayland-server/src/xdg-shell.lisp` said so on purpose: a positioner that positions nothing
would be a lie. A menu is the first surface a client creates that the compositor must *place*
rather than let it place itself, so this slice is where the framework first has to answer
"where is that, in your coordinates" — and the answer has to survive the parent moving.

Four things were unclear enough to be decided rather than improvised:

1. **The arithmetic is a pure function in the protocol layer, and the constraint box is the
   compositor's.** `xdg_popup.configure` carries x and y relative to the upper-left corner of
   the *parent's window geometry*, not to the output — so the protocol layer can compute the
   whole placement from the positioner's rules plus one box, provided the box arrives in the
   same space. `positioner-place` (rule, box) is therefore pure and unit-tested (anchor point,
   gravity, offset, then flip → slide → resize against the box); the box comes from a
   generic the compositor specialises on the popup's `wl_surface` (`popup-constraint-box`),
   and `cf.backend.headless` computes it as the output in the parent's geometry space:
   `(-parent-x -parent-y output-width output-height)`. Neither side guesses the other's
   coordinates.
2. **A flip that is still constrained is reverted**, which is what the XML says and what a
   naive implementation gets wrong: half a menu above the top of the screen is worse than a
   menu clipped at the bottom, because the *anchor edge* is what the user is looking at. Slide
   clamps a popup larger than the box so that it still covers the box — the same rule as
   `clamp-to-output` (D43) — and resize only ever shrinks, as the spec's wording allows.
3. **A popup's node is placed every frame, from its parent's node.** The configure's position
   is relative to the parent, and the parent moves: a drag, a resize, a cycle. Storing an
   absolute position at configure time gives a menu that stays behind when its window is
   dragged, and re-placing only on configure gives the same thing one interaction later.
   `sync-popup-positions` asks each frame, exactly as the pointer's image is asked for (D41).
   Two smaller rules fall out of the same idea: a popup node is *not* a window
   (`window-node-p` now demands the toplevel role, so cycling cannot raise a menu), and a raise
   takes the window's popups with it (`raise-window-with-popups`) — a menu left over another
   window is a menu for the wrong window.
4. **A popup grab is an owner-events grab that ends on dismissal, not on the button that
   started it.** Inside the stack the client hears the press (a submenu is clickable); outside,
   the compositor dismisses and swallows the press *and its release*, because a client that was
   not sent the press must not be sent the release (the same rule as a consumed key, D33). The
   grab therefore outlives the dismissal until the swallowed release has arrived, which is why
   `popup-dismissed` ends it only when nothing is pending. Escape is the keyboard half of the
   spec's "dismissed by the user"; a grab whose serial is not one this display issued is
   refused, and a refused grab dismisses the popup, as the XML requires.

**Evidence.** `scripts/popup-gate.sh` (gate clause 17), a compiled libwayland client on a
320x240 output with a 300x200 window: the first menu's configure is `(30 30 120 80)` (the anchor
point of `(10 10 20 20)`, bottom-right gravity), its magenta pixels are at (35,35) and
(145,105) with the window's green around them, Escape produces `popup-done` and the pixels revert,
the second menu — anchored at the window's corner, where it would leave the output — is
**flipped** to `(170 110 120 80)` with the requested place (305,205) still empty, and a press
outside it dismisses it with the client's own log showing no click for the closed menu. 24
checks over two clients (the gate's two fixed anchors, and the demo's `--follow-pointer` mode,
which anchors the menu at the pointer and is what a manual test uses). Unit tests: seventeen new ones -- four on the arithmetic (anchor points,
gravity and offset, flip-then-slide-then-resize, and the flip that is reverted), eleven on the
state machine over raw messages (the configure and the copied rule, map/unmap, the topmost
destroy rule, a grab accepted, a grab refused, a grab after mapping, a nested parent without a
grab, a parent with no role, a popup that would be its own parent, no parent at all, and an
incomplete positioner), and two on the framework's placement (a menu is not a window; a menu
follows its window and stays above it). The suite went from 221 to 238 tests; the gate is 17/17.

**Consequences.** Menus, tooltips and dropdowns work, with the placement and the grab a real
client expects, and the same policy holds in a nested session because nothing in it is parent
specific. What this does not do: `reposition` or reactive positioning (v3, so the global stays
v1), popups parented by anything but xdg-shell (a null parent is created and never mapped — no
layer-shell yet), multiple outputs (the constraint box is *the* output, singular), and
server-side placement of a menu that its client positions badly (the compositor adjusts only
what the client asked it to adjust). The lesson: **a surface the compositor places must be
placed from the parent's frame of reference, and asked for again whenever the parent moves.**

## D45 — Focus is history, not draw order; a menu belongs to the window it drops from

**Date:** 2026-11-26
**Status:** accepted
**Slice:** focus stack

Until this slice the compositor had two facts and no way to tell them apart: the scene's children
said what covered what, and "the window that mapped last" said who had the keyboard. Neither
answers the question a person asks by closing a window — *who has the keys now* — and neither
answers what Alt+Tab should visit. A third fact was missing: the order in which windows were
focused.

**Decision.**

1. **The focus stack is its own list: windows, most recently focused first.** The scene's
   children stay *draw* order, which is the compositor's statement about covering (D31/D36), and
   `compositor-focus-stack` is *history*. They coincide in cl-tinywl only because tinywl raises
   whatever it focuses; a compositor that does not raise on focus still has a stack. Every focus
   goes through `focus-surface`, which is where the stack is updated — so keyboard `enter`/`leave`,
   the toplevel's `activated` configure and the history cannot drift apart.
2. **Windows only, never popups.** A popup takes the keyboard while it is up (the spec says the
   topmost grabbing popup always has focus), but a menu in the history would be something Alt+Tab
   could return to after it had gone. Focusing a popup therefore pushes *the window it belongs
   to*: that window is the active window, and the menu is a temporary extension of it. A roleless
   surface — a cursor image, a surface a client mapped for itself — is nobody's window and never
   enters.
3. **A closing window hands the keys on.** When the focused surface is destroyed or unmapped it
   leaves the scene *and* the stack, and the keys go to the most recently focused window that is
   still there; when none is left the focus is cleared. This is the whole point of keeping the
   history: "the one that mapped last" is an answer that survives only until there are two
   windows.
4. **Alt+Tab rotates; it does not toggle.** `focus-stack-cycle` takes the *tail* of the stack
   (the least recently focused window), focuses it, rotates it to the front, and raises it. A
   rotating cycle visits every window exactly once and wraps, and with two windows it *is* a
   toggle — where an MRU toggle with three windows could never reach the third. A real
   hold-Tab-release switcher needs an overlay to show what is selected (a scene node, phase 6);
   the same list will serve it. The raise is part of the cycle's contract and not of
   `focus-surface`'s: a cycle that does not show the window it chose is invisible, and stacking
   stays the compositor's decision, so the policy function raises and the primitive does not.
5. **Focus and raise are separate calls in the framework, one call in tinywl.** The framework's
   click-to-focus moves the keyboard and the stack; it does not raise (D31: a framework cannot
   know whether its compositor wants click-to-raise). cl-tinywl raises on focus and on press,
   which is tinywl.c's rule, so in that compositor draw order follows focus. Alt+F1 keeps
   tinywl.c's own cycle (bottom window *in draw order* comes to the top) and Alt+Tab is the new
   focus cycle — the port gains a binding, it does not replace one.

**Evidence.** Gate clause 18 (`scripts/focus-gate.sh`, `scripts/focus-gate.lisp`) with three
independent `weston-simple-shm` clients on an 800x600 output, moved to (0,0), (150,0) and
(300,0): the last one to map has the keyboard and the stack is (C B A); Alt+Tab focuses A, raises
it (checked as the frontmost scene child), configures A `activated` and C not, and rotates the
stack to (A C B); three more presses visit B, C and A and wrap; a click at (280,10) focuses B and
moves it to the front *without* raising it; closing B hands the keys to A, removes B from the
stack and from the scene, and configures A `activated`; with two windows Alt+Tab toggles; with
one it focuses that window and is otherwise a no-op. 33 checks. Seven new unit tests: the push
order and no-duplicates rule, a popup pushing its window, a roleless surface never entering,
cycling through three windows and wrapping (and raising), two windows toggling, a closed window
handing the keys on down to the last one (and the stack emptying), and an empty cycle. The suite
went from 238 to 245 tests; the gate is 18/18. `tinywl-installs-its-own-bindings` moved from
three bindings to four, which is the test doing its job: the port's keymap is its own statement.

**Consequences.** Closing a window now leaves the keyboard somewhere sensible, and Alt+Tab is
usable in a session with more than two windows. What this does not do: a visible switcher (needs
an overlay), a focus-follows-mouse policy (the hook is `update-pointer` from a compositor's motion
handling), per-output stacks (there is one output), "urgent" or "demands attention" (a client
asking for focus without taking it — `xdg_activation` is not implemented), and the decision this
slice deliberately did not take: **clamping a resize to the output, and re-clamping windows when
the output shrinks** (D43's open question, D37's). The lesson: **draw order and focus order are
two different claims, and a compositor that keeps only one of them cannot answer who gets the
keys next.**

## D46 — A resize stops where the output does, and a shrinking output brings its windows back

**Date:** 2026-11-26
**Status:** accepted
**Slice:** resize clamping / re-clamping

Two questions D43 and D37 deliberately left open, now answered together because they are one
rule seen from two sides: a move was clamped to its output (D43), a *resize* was not
(weston-terminal could be dragged wider than the nested window and disappear past its edge), and
an output that *shrank* left its windows where they were (D37: a parent configure that made the
nested window smaller left half of each window outside it, unreachable). A window that cannot be
seen and cannot be clicked is a window the user has lost, whichever way it got there.

**Decision.**

1. **The dragged edge stops at the output's border; the opposite edge stays put.** That is the
   resize-side twin of `clamp-to-output`: the anchored edge is where it was (D42), so the largest
   size the drag may ask for is the distance from that edge to the output's border on the axis
   being dragged — `resize-grab-max-size`, computed from the anchored *geometry* edges in output
   space and the output size both callers now pass in (`toplevel-resize-requested`,
   `tinywl:begin-interactive`). A right/bottom drag is bounded by `output − anchor-left/top`; a
   left/top drag by the anchored right/bottom edge, so a window cannot be widened out of the left
   either. A client's minimum size wins where the two disagree: a window smaller than its
   client's minimum is a window the client cannot draw.
2. **Clamping speaks window geometry, in one helper.** `clamp-node-to-output` clamps a node by
   its *window geometry* and places the node back from it, because a decorated client's buffer
   starts before its window (a shadow): clamping the node would leave the shadow's width of slack
   (D43's lesson, applied to the whole family). The move grab, the re-clamp and any compositor
   that wants the same rule now call it instead of doing the arithmetic at each call site.
3. **An output that changes size re-clamps every window.** `resize-compositor` calls
   `reclamp-windows` after the new dimensions are in place, so D37's nested case — the parent
   hands us 400x300 where we had 800x600 — brings the windows back instead of leaving them
   outside. It only ever pulls *in*: growing the output again does not push anything out, because
   moving a window is the compositor's or the user's decision, not a side effect of a resize.
   Popups are not moved by it: their node is placed from their parent every frame (D44), so they
   follow for free.

**Evidence.** Gate clause 14 grew three checks with a real compiled client: a second right-drag
that would ask for 1120x1070 on a 512x512 output configures `482x472` — the window's anchored
top-left is (30,40), so the bottom-right edge stops at the border — and the grab ends on the
release. Clause 16's nested run grew two: after growing the nested output to 800x600 it is
configured to 400x300, and every live window must satisfy the clamp invariant (`x` in `[0, W−w]`
for a window that fits, `[W−w, 0]` for one larger than the output), which is what the re-clamp
now guarantees; the run then puts the space back for the rest of the scenario. Four new unit
tests pin the parts a gate cannot isolate: the four edges' bounds and the minimum-wins rule on
the pure function, the bounds the grab *derives* from its anchored edges (both the bottom-right
and the left case), an output shrinking under a window that fits and then under one that does
not, and the geometry-versus-buffer arithmetic (a 742-wide window in an 806-wide buffer is
clamped as 742). One robustness fix came with them: `grab-resize` now ignores a node that is not
a surface instead of erroring, since a grab is a scene object and not every node has a client.
Suite 253 → 257 tests, eleven suites; parity 108 → 110 checks in two runs; the gate is 18/18.

**Consequences.** A resize can no longer lose a window, and a nested session whose parent shrinks
keeps its windows usable. What this does not do: clamp a *client's* own size (a client that
attaches a larger buffer is the client's business — only interactive resizes and placement are
ours), grow a window back when the output does (deliberate, see 3), keep a window inside the
output while its client animates a size change, or compensate for a menu that would now need
re-positioning after a shrink (v1 popups have one configure; `reposition` is v3). Edge-anchored
resizing — moving the node only when the client answers, so a top/left drag does not trail the
pointer — is still open. The lesson: **a bound that holds for one way of moving a window has to
hold for the other, and for the output moving under it.**

## D47 — A grab clamps the pointer; only a backend saying "left" ends it

**Date:** 2026-11-26
**Status:** accepted
**Slice:** resize clamping, second round (a defect the manual test found in D46)

D46 stopped a resize at the output's edge, and the manual test found the flaw in how: resize
a window from its bottom-right corner and, once the height reaches the bottom of the output,
the whole resize stopped — the width would not follow the pointer any more either, although it
had room to. The prose in D43 ("a window cannot be resized out of reach") was satisfied, but the
interaction was not: a person dragging a corner past one edge expects the other axis to keep
tracking, and that is what every desktop does.

A probe with a headless compositor and an injected pointer found two separate facts, and they
had been conflated:

    motion (399,299) -> grab alive, asked (350 250)   ; both axes at their bounds
    motion (350,299) -> grab alive, asked (310 250)   ; y at its bound, x keeps tracking
    motion (390,320) -> grab NIL                      ; the pointer left the output

So the arithmetic was right and the *axes* were never coupled. What ended the resize was
`inject-pointer-motion`'s rule from D43: a position outside the output ends the grab, because a
grab that outlives its pointer swallows the mouse. That rule is right about a pointer that is
*gone* — and wrong about a pointer that is merely past an edge, which is a position this
compositor's own device can still report, and which says nothing about the axis it is not on.
In a nested session the two arrive as the same thing, because the backend encoded its parent's
`wl_pointer.leave` as the coordinate `(-1,-1)`.

**Decision.**

1. **A position outside the output is clamped for the grab, not fatal.** `clamp-pointer` maps the
   grab's copy of the pointer into `[0, width-1] x [0, height-1]`, so a drag whose pointer is
   past the bottom edge keeps resizing the width. The *cursor* keeps the raw coordinates the
   device reported: D43's "the pointer is where the device says, the window is what stops" is
   unchanged, and the renderer clips it as before.
2. **Only a backend can say the pointer is gone, and saying it ends the grab.**
   `cf:inject-pointer-leave` is that statement: it parks the cursor, drops the pointer focus and
   ends the grab with `:pointer-left-output`. `cf.backend.nested` calls it for its parent's
   `wl_pointer.leave` instead of inventing `(-1,-1)`; a top-level backend with a real device has
   no such event and will call it when a device leaves the output. The distinction is now in the
   API rather than in a magic coordinate.
3. **Nested sessions still stop at the window's edge, and that is the parent's decision.** When
   the outer pointer walks off the nested window, the parent sends `leave` and then no
   coordinates at all — so nothing can continue, whatever the grab would have done. What changed
   is *why* it stops and that it stops only there.

**Evidence.** The unit test `a-drag-past-one-edge-keeps-tracking-the-other` reproduces the
probe's numbers through the real API: 350x250 at the corner, 310 with y at its bound, then with
the pointer 600 below a 300-high output the width follows to 260 and 340 while the height stays
250 and the *cursor* is at (380, 900) — clamped for the grab, not for the device. A second unit
test does the same for a move grab. Gate clause 14 grew three checks with the compiled client:
from a drag starting at (80,80) on a 200x150 window anchored at (30,40), a pointer at (200,600)
configures `320x472`, at (300,600) `420x472` (x still following, y at the output's bound), and at
(500,500) `482x472` (both at the edge). Clause 16's both runs keep their "a pointer that leaves
the output ends the drag" check, now routed through each mode's own leave: in the nested run the
parent's motion off our window becomes `wl_pointer.leave`, in the headless one the test calls
`inject-pointer-leave` directly — so the gate tests the contract rather than a coordinate.
Suite 257 → 259 tests; the gate is 18/18.

**Consequences.** A corner drag tracks both axes independently, which is what the manual test
expected, and the "swallowed mouse" failure D43 fixed is still prevented because a `leave` still
ends the grab. What this does not change: in a nested session the pointer belongs to the parent,
so leaving the nested window still ends the drag (the parent sends no coordinates afterwards);
`wl_pointer.frame`/pointer-lock would be needed for anything else, and neither is a version we
advertise. The lesson: **a coordinate outside the output and a pointer that no longer exists are
different statements, and a compositor that infers the second from the first throws away the
first.**

---

## D48 — Damage is what changed since the last frame, and a frame that paints nothing still answers its clients

**Date:** 2026-11-26
**Status:** accepted
**Slice:** phase 2b, rendering (damage tracking, opaque culling)

Phase 2a repainted the whole output every frame: a full background fill, then every window
composited again, whether or not anything had changed. The note in
`docs/memory-and-rendering.md` §10 was that damage tracking is worth "5-10× on typical
desktops", and it is the first rung of that ladder. Getting it wrong is invisible until it
is not: a stale pixel is a pixel nobody repaints, and the frame still "looks right" for
every static screenshot a gate can take.

The design problem is *where the damage comes from*. A compositor that accumulates damage
in every operation that could change a pixel (a move, a raise, a popup following its
parent, a pointer moving, a client commit, a resize) has to remember one more thing in
each of them, and forgets one. This compositor instead keeps **the draw list of the last
frame** and diffs against it: a node that is new, gone, moved or given a different buffer
is the difference between two lists, and nothing has to remember to say so.

**Decision.**

1. **The frame is one list, computed once, and both the damage and the draw read it.**
   `scene-draw-list` turns the tree into draw items in device pixels, back to front; the
   cursor appended last. `scene-damage-between` compares it with the previous frame's list
   (geometry, content signature, and the damage each surface reported at commit);
   `scene-render-items` draws it. Because both passes read the same rectangles they cannot
   disagree, which is the failure that makes damage tracking look like magic.
2. **Client damage is the content half.** A commit's `wl_surface.damage` rectangles are
   accumulated on the surface (`surface-damage-since-frame`) and only mapped to output
   pixels once per frame, because that is the only moment the compositor knows where the
   surface *is*. A frame that paints them clears them; a frame that could not be drawn (the
   nested backend had no parent buffer) keeps them.
3. **A stacking change is a full repaint.** Raising a window uncovers the pixels under it
   and covers the pixels over it, and neither shows up in a rectangle diff of the *new*
   list. Comparing the node order costs one list walk and is honest; everything else is
   incremental.
4. **Each item is drawn through a clip: its rectangle, minus what opaque items above it
   cover, minus what is not damaged.** A surface is opaque if its buffer is `xrgb8888`
   (the alpha bits are undefined and must not be blended) or if the client's committed
   opaque region says so; a translucent rectangle hides nothing. An item whose clip is
   empty is not drawn at all, and that is what makes culling free.
5. **An empty frame still walks the list.** With nothing damaged, no pixel is touched --
   but every mapped surface still comes back from the walk, so its buffer is released and
   its frame callback fires. A client that asks for a frame without damaging anything is
   waiting for exactly that (D25), and a nested backend needs it to give back the parent
   buffer it was holding.
6. **`cf:invalidate-output` is the escape hatch** and a REPL function in its own right:
   after a mode change, a scale change, or suspicion, the next frame repaints everything and
   the frame after it goes back to damage.
7. **Translucent rectangles are filled through a repeated one-pixel premultiplied image,
   not through `pixman_image_fill_boxes`.** Measured, not assumed: pixman 0.46's
   `fill_boxes` turns a `pixman_color_t` into a *straight* alpha pixel and composites it as
   if it were premultiplied, so 50% white over green comes out `#xFFFFFFFF` instead of
   `#xFF80FF80`. Opaque colours -- every background and border -- still take the fast path.

**Evidence.** `tests/unit/render.lisp` (22 tests) checks the diff arithmetic (a moved node
damages both rectangles; an untouched output damages nothing; `invalidate-output` is whole
for exactly one frame), opaque culling (a covered window's pixels come back when it is
removed, which only works because the diff damages what disappeared), and the blend. The
strong test is `a-partial-repaint-is-a-full-repaint`: a scene of two opaque rectangles and
a translucent veil is moved four times, and the incremental frame is compared with a full
repaint of the same scene *pixel for pixel*. Gate clause 19 does the same through the
public API, and asserts that the last partial frame repainted 60x41 of a 120x90 output --
so the comparison is not passing because damage quietly became a full repaint. The bugs
this slice found, each now impossible to re-introduce quietly: the cursor item was
appended to the wrong end of the list and drawn *under* the windows (found by the scene
gate's cursor check); and an empty scene's item list is `NIL`, which the diff read as "no
frame yet" and turned every frame into a full repaint (found by the damage test, fixed with
an explicit `frame-history-p` flag).

**Consequences.** A typing client repaints its own damage rectangle; a still desktop
repaints nothing; two overlapping windows cost their visible area rather than their sum.
The list is consed per frame (one draw item per node, one clip region per item from a
pooled set), which is the honest cost of this design until a frame-budget test exists:
`docs/memory-and-rendering.md` §11's "no allocation per frame" is still a target, and the
pool is what keeps the largest part of it (the regions) out of the allocator. What this
does not do: per-surface damage *regions* (the clip is pixman's, the client's damage is a
list of rectangles), damage buffer coordinates (`wl_surface.damage_buffer` is v4 and we
advertise v3), or skipping a frame that nobody asked for. The lesson: **a compositor that
wants to know what changed should keep what it drew last time, rather than remember to
report every change.**

---

## D49 — Layout coordinates and device pixels are different spaces, and one number separates them

**Date:** 2026-11-26
**Status:** accepted
**Slice:** phase 2b, rendering (buffer scale, buffer transform)

The output scale question had been deferred since D29: `wl_compositor` v3 accepts
`set_buffer_scale` and `set_buffer_transform`, and drew them 1:1, "until the renderer
scales (2b)". The consequence was visible on the user's own output: Umbriel runs HDMI-A-1 at
scale 2, and a nested session inside it drew at scale 1 and let the parent upscale it, so
every glyph was doubled by a blit instead of drawn at the right density.

The trap is that two different numbers are called "scale". The *output* scale says how many
device pixels a layout coordinate occupies. A *client's* buffer scale says how many buffer
pixels that client drew per layout coordinate of its own surface, because it was told the
output's scale and drew at it. When they are equal the buffer maps 1:1 to the target, which
is the whole point of the protocol's buffer scale; when they differ (a scale-1 client on a
scale-2 output) the buffer is magnified.

**Decision.**

1. **The scene speaks layout coordinates; the target is device pixels; the conversion
   happens once per frame, in `scene-draw-list`.** Positions, sizes, hit tests, configure
   sizes, grabs, clamping and every policy stay layout. A node's width is the *layout* size
   of its surface: its buffer divided by its buffer scale, with the axes swapped for a
   quarter turn. `scene-scale` is the one number between the spaces.
2. **A client's buffer scale is divided out, and the output's scale multiplied in.**
   A buffer is drawn into `round(buffer-display-width * output-scale / buffer-scale)`
   device pixels, nearest-neighbour, so a client that drew at the output's scale is copied
   pixel for pixel rather than resampled.
3. **The eight `wl_output.transform` values are applied on top**, as pixman transforms
   mapping the destination rectangle back to the buffer. The matrices are derived from the
   protocol's own words ("90 degrees counter-clockwise"; the flipped family as "an initial
   flip around a vertical axis followed by rotation"), written out in `transform-matrix`,
   and checked twice: as numbers in `tests/unit/render.lisp`, and as rendered pixels of a
   real client's buffer in gate clause 19.
4. **The output advertises its scale**: `wl_output.scale` is the scene's scale and the mode
   is the layout size times it, so a well-behaved client draws at the right density.
5. **A nested session tells its parent the same scale** (`wl_surface.set_buffer_scale` on
   the parent surface) and sizes its parent buffers in device pixels. The layout size the
   parent configured it at is unchanged, so the window is the size it asked for and the
   pixels are the density it draws at.
6. **`cf:frame-pixel` reads layout coordinates and `cf:frame-pixel-device` reads device
   ones.** Every existing gate and test speaks layout, so they kept working unchanged at
   scale 1 and became meaningful at scale 2.

**Evidence.** `tests/unit/render.lisp`: `a-surfaces-layout-size-divides-out-its-buffer-scale`,
`a-buffer-node-is-hit-in-layout-coordinates` (a 64x32 buffer at scale 2 is a 32x16 window,
and a click past 32 misses it), `the-draw-list-turns-layout-into-device-pixels` (the same
window is 128x64 device on a scale-2 output and 64x32 when the client also drew at scale 2),
`a-transform-matrix-maps-destination-to-source` (all eight), and
`a-scale-two-output-draws-at-twice-the-size`. Gate clause 19 runs a real libwayland client
that decides its own `set_buffer_scale` and `set_buffer_transform`: at scale 1, on a scale-2
output (magnified to 128x64), at buffer scale 2 on a scale-2 output (1:1, 64x32), and with
transforms 90 and 180 -- four quadrants each, all landing where the rotation says. Its last
section starts a scale-2 nested session inside a scale-1 parent and checks that the parent's
server saw `buffer_scale 2`, a 200x160 buffer for a 100x80 layout, and the window drawn at
100x80 layout pixels.

**Consequences.** A nested session on a scale-2 output now draws text at its native density
-- the reason this slice was asked for. What it does not do: fractional scale
(`wp-fractional-scale` is phase 5), scaled *output* rotation (a per-surface rotation is what
is implemented; rotating the whole output is phase 4's scanout concern), or viewports
(`wp_viewport`), so a client that wants a non-integral scale still gets nearest-neighbour.
The cursor is drawn at 16x16 *layout* pixels, so it is 32x32 device pixels at scale 2: twice
the size a themed cursor would be, which is the "acceptable for now" the user named before
this slice and which phase 5's theme lookup replaces. The lesson: **a scale is a statement
about a space, so give the space a name and convert in exactly one place.**

---

## D50 — A buffer's age is how many frames it missed, and two frames is all a two-buffer session can be behind

**Date:** 2026-11-26
**Status:** accepted
**Slice:** phase 2b, rendering (buffer age for the nested path)

D48's damage is only useful for the nested backend if the buffer it paints into still holds
what the parent is showing. With two buffers, a buffer is either the last frame's (age 1) or
the one before it (age 2) -- and after two frames it must be painted whole. The old code
avoided the question by damaging the whole surface on every commit, which is correct and
wastes the whole frame.

**Decision.**

1. **Two damage entries, newest first, and a frame number per slot.** A slot is painted
   whole if it has never been presented; otherwise the frame repaints the union of the
   damage of every frame this slot missed. Two entries is not a tuning constant: with two
   buffers, a slot can only ever be two frames behind, so a third entry would describe a
   state no slot can be in.
2. **A frame recorded as `:full` makes every slot that missed it full.** A resize or a new
   buffer paints everything, so the *other* slot's contents are unknown rather than
   partially known; recording "whole" and treating an unknown entry as whole is what keeps
   the arithmetic honest after a configure.
3. **A frame that paints nothing gives its slot back without a commit.** The compositor
   still calls the presenter with an empty region; the nested presenter then attaches and
   commits nothing, marks the slot free, and records the frame. Presenting an unchanged
   buffer would cost a parent round trip and a parent repaint for no pixels, and *not*
   returning the slot was a real deadlock found the first time a client mapped after an
   idle frame: both slots were taken by frames that had nothing to draw, and no frame could
   ever be prepared again.
4. **The frame sequence and the presented-frame count are separate numbers.** A frame that
   paints nothing still occupies a sequence number (the history has to be able to say "that
   frame painted nothing"); `nested-frame-count` stays what the gate reads as "frames the
   parent was shown".

**Evidence.** The deadlock above is the evidence for 3: a nested session with one client
presented exactly one frame and then stopped, with both slots busy and `frame-dirty` still
true. After the fix the same probe shows 259 frames in 1.5 seconds (a client that redraws on
every frame callback), and the nested gate's pixel grid passes. Gate clause 19's nested
section checks the scale plumbing end to end; the nested gate and the tinywl parity script
(both runs) check that partial presenting did not change what the parent sees. The
`record-frame-damage` ring reuses two regions, so recording a frame allocates nothing, and five
unit tests pin the age arithmetic: a slot nobody has seen, a slot that missed one frame (the
region is that frame's damage), one that missed a full frame, one whose missing frame was never
recorded, and a history that keeps two frames and no more.

**Consequences.** The nested path now damages what changed, in surface-local coordinates
(device pixels divided by the scale, rounded outwards -- a damage rectangle a pixel too
small leaves a stale pixel, one too large only repaints it). What this does not do: more
than two buffers, `wp_commit_timing`/explicit sync, or presenting a frame that is still
being read by the parent (the one-frame-in-flight rule from phase 3e still holds). The
lesson: **incremental drawing is only sound against a buffer whose age you know, so count
the frames a buffer missed and stop pretending after two.**

## D51 — The switcher is an overlay, and nothing is decided until the key comes up

**Date:** 2026-11-26
**Status:** accepted
**Slice:** the visible Alt+Tab switcher

D45 gave the compositor a focus stack and a rotating cycle, and said what it could not do:
"a real hold-Tab-release switcher needs an overlay to show what is selected (a scene node,
phase 6)". The stack was right and the *view* was missing. One tap of Alt+Tab changed the
world with nothing on screen to say what had been chosen, and with three or more windows a
person had to look at the screen afterwards to find out. This slice adds the view, and the
five decisions that keep it small are about where it lives, what it is made of, and what it
is allowed to touch.

**Decision.**

1. **An overlay is a second root, not a window.** `scene` grows an `overlay` tree node: drawn
   after the tree, before the cursor, and reachable by no hit test, no raise, no cycle and no
   clamp, because those all walk `scene-root` and the overlay is not in it. That is the same
   rule the cursor already followed (D31), applied to the second thing that must be visible
   and unclickable. It is deliberately *not* a layer: layers are layer-shell's stack of
   namespaces owned by other clients, and a layer has a place in a protocol (phase 6). An
   overlay has no owner and no protocol; it is the compositor drawing on its own screen.
2. **Text is a node kind and a table of 95 glyphs.** A switcher that cannot say which window
   is which is not worth a font engine, so `cf.font` is a 5x7 bitmap font with printable ASCII
   in a table, parsed and *validated* at load (a glyph that is not seven rows of five is a
   load-time error, not a strange picture), and `text-node` rasterises a string into
   premultiplied ARGB8888 at the output's scale. One cell is one layout pixel, so a glyph at
   scale 2 is 10x14 device pixels *drawn*, not a 5x7 picture upscaled -- the same choice the
   cursor made (D49), and the reason titles are crisp. The raster is cached on the text, the
   colour and the scale, so a switcher that draws the same title every frame allocates nothing
   for it. No shaping, no kerning, no BiDi, one size; a character outside ASCII draws as `?`.
3. **The list is the cycle, drawn.** Rows are the focus stack read backwards -- from its tail,
   which is what one tap of `focus-stack-cycle` chooses, to its front. Row 0 is where one tap
   lands, row 1 where two land, and so on, so holding Tab walks exactly the sequence tapping
   walks and the key means the same thing whether the overlay is seen or not. Wrapping is the
   property D45 chose the rotation for, and it survives: after a full turn the person is back
   where they started. Alt+Shift+Tab opens one row back (on the window that has the keys now);
   it is a second binding in the port's table, not a second rule in the switcher.
4. **Nothing is decided until the key comes up.** While it is open the switcher reads the stack
   and paints it: it does not touch the stack, the keyboard, the stacking order or the focus.
   Releasing Alt makes *one* call -- focus and raise the row it was showing -- which is the same
   call the cycle makes, so the visible and invisible cycles agree by construction. A window
   that closed while the overlay was up is not chosen: the overlay showed what was there when it
   opened, and focusing a tombstone is worse than doing nothing. The mode is a generic function
   asked before grabs and bindings rather than a binding table, because a binding fires on a
   press and a switcher has to see the release that commits it: `switcher-key` and
   `switcher-pointer-press` have no-op defaults, so a compositor with no switcher pays one
   dispatch per key and keeps none of this in its key path.
5. **The key rules are about not stealing the keyboard.** Tab walks (forwards, or backwards with
   Shift -- read from the modifier state, since a switcher is one key held down and a table
   matches pairs). A *modifier* press neither cancels nor is consumed: Shift picks the direction
   of the next Tab, and a modifier whose press was swallowed but whose partner's was not is a key
   the client believes is stuck. Escape cancels *and* is consumed, because Alt is still down and
   Alt+Escape is "quit" here (D45): a cancel that also ended the session would be a spectacular
   way to lose a click. Any other press cancels and is *not* consumed, so typing still reaches
   the window. A release commits when Alt is no longer down -- the moment the person stopped
   choosing -- and is not consumed either: the client saw Alt go down, so it must see it come up.
   A pointer press cancels the overlay and is then delivered as the click it was.

**Evidence.** Gate clause 20 (`scripts/switcher-gate.sh`, `scripts/switcher-gate.lisp`) drives
three independent `weston-eventdemo` clients titled ALPHA, BETA and GAMMA on an 800x600 output
at scale 2, through *cl-tinywl's own keymap*: the stack reads (GAMMA BETA ALPHA); Alt+Tab opens
an overlay whose rows are (ALPHA BETA GAMMA) with row 0 selected, and the frame that holds it
repaints the whole output; the panel, the one-pixel outline and the selection bar are read back
at the coordinates `switcher-layout` gives, in the colours the switcher names; each row's text is
measured to the last device pixel of the last glyph -- 58, 46 and 58 device pixels for ALPHA,
BETA and GAMMA, ending at 827, 815 and 827 -- which is a width only that title produces, in the
row only the focus stack puts it in; a Tab moves the bar and damages `(754 552 90 64)`, two rows
rather than the output; releasing Alt focuses and raises ALPHA as the frontmost scene child,
rotates the history to (ALPHA GAMMA BETA) exactly as one tap always did, and the frame it leaves
is **byte-identical to a full repaint** (`cf:frame-octets` on both sides); Escape and a click
cancel without moving the keyboard; Alt+Shift+Tab opens on the last row, the window that has the
keys; and a point inside the panel hit-tests to the window under it, never to the overlay. The
last section puts the whole thing one compositor deeper: a nested tinywl session at scale 2
inside a scale-1 headless parent, two clients inside it, Alt+Tab injected into the *inner*
compositor -- the panel is in the inner frame and in the parent's own frame at the coordinate the
scale mapping implies, which is the only claim that means anything when the two compositors
disagree about scale on purpose. 58 checks. Thirty new unit tests (suite 13, `tests/unit/switcher.lisp`) pin what a gate
cannot isolate: the font's 95 glyphs and their shape, text width as `6n-1`, a raster's
premultiplication and its 2x2 blocks at scale 2, the gap column between glyphs, the fallback
glyph, `truncate-text`'s ellipsis, a text node's layout size against its device raster, the
overlay's place between the windows and the cursor, the overlay never being hit-tested or
adopted by the tree, `window-title`'s title → app-id → nothing order, the listing order, that
walking the list touches neither the stack nor the stacking order, forwards and backwards
wrapping, the bar following the selection, a 60-character title being cut rather than widening
the panel past the output, a nameless client getting a stand-in row, one window opening nothing,
Alt+Tab through the real key path (consumed press, consumed release, nothing left in
`consumed-keys`, focus untouched), a modifier press that cancels nothing, the release that
commits and raises, Escape cancelling and being consumed, a click cancelling, idempotent
cancel/commit, a window that vanished while the overlay was up, and a compositor with no
switcher binding still cycling the stack as D45 says. The suite went from 282 to 312 tests; the
gate is 20/20.

**Consequences.** Alt+Tab now shows what it is choosing, the switcher works in a nested session
for free (it is the same scene, key path and stack), and any compositor can bind `start-switcher`
or drive `advance-switcher` from its own policy -- the state machine does not care who moves the
selection. What this does not do: thumbnails (a window's picture is not drawn; a row is a title),
animations, a search box, per-output stacks, text outside printable ASCII, more than one font
size, or window lists from anything but the focus stack. The framework's *default* Alt+Tab is
still `focus-stack-cycle`: an overlay is a compositor's statement about its own screen, and a
framework default that paints one would be policy (cl-tinywl binds `start-switcher`, and the
gate drives that). The lesson: **a modal key is not a binding -- it is a state machine with a
beginning and an end, and the end is where the decision belongs.**

## D52 — A row's picture is a snapshot, taken once

**Date:** 2026-11-26
**Status:** accepted
**Slice:** thumbnails in the switcher's rows

D51 ended with a list of what the switcher deliberately did not do, and the first item was
"thumbnails (a window's picture is not drawn; a row is a title)". A title is enough to choose the
window you remember by name and not enough to choose the one you remember by what is on it,
which is most windows most of the time. This slice puts a picture in every row. The interesting
part is not the scaling; it is *when* the picture is taken, because that decides what the damage
arithmetic has to believe.

**Decision.**

1. **A picture is a copy, not a live view.** `scene` grows `snapshot-node`, a `bitmap-node`
   (pixels we own) whose size and lifetime are the compositor's. `scene:snapshot-surface` reads a
   surface's current buffer once and returns premultiplied ARGB8888 octets. The alternative --
   drawing the client's buffer shrunk into the row -- is the obvious design and is wrong three
   ways: the buffer changes whenever the client draws, so the draw item's signature changes and
   the panel repaints on every client frame; a client may destroy that buffer while the overlay
   is up; and the picture's freshness would depend on what else happened to be damaged that
   frame. With a copy, the item is a constant, and the one honest answer to "is the thumbnail
   current?" is "no: it is what the window looked like when you opened this".
2. **Taken at the resolution it will be drawn at.** A 72x48 layout box on a scale-2 output
   becomes a 144x96 picture: exactly the device pixels the row will show. Drawing it is then a
   1:1 copy with no filter and no per-frame resample, which is both the cheapest and the only
   variant a pixel check can prove (`frame pixel = picture pixel`, one for one). The single
   resample happens at open, with **bilinear**, because a picture is not a glyph grid: the font's
   nearest-neighbour rule (D51) is right for text and turns a downscaled title bar into dropped
   columns.
3. **The box is a limit, not a shape.** A window is fitted inside 72x48 preserving its aspect
   ratio, and never enlarged: a 500x400 window becomes 60x48 of the 72x48 box, a 16x8 window
   stays 16x8. A stretched thumbnail is a thumbnail of a window nobody has, and an upscaled small
   one is a blur of a window that was already small enough to read.
4. **A row is as tall as its content, and the bar is the row.** Rows with a picture are
   `picture height + 4`, rows without are the 16-pixel title row, and the title is centred
   against whichever it is. The selection bar therefore has to be *resized* as well as moved, so
   `scene:set-node-size` arrives -- and it is deliberately narrow: a rectangle's size and a
   bitmap's drawn size are the compositor's; a buffer node's is the client's answer and a
   snapshot's is the box it was taken for (D10's rule, unchanged).
5. **No pictures, no gutter.** The picture column exists only when at least one row has one. A
   switcher over windows with no pixels -- a compositor before its clients map, a test fixture
   with hand-made surfaces -- is exactly the title-only switcher D51 delivered, arithmetic
   included, so the fallback is not a second layout to keep in sync.

**Evidence.** Gate clause 20 (`scripts/switcher-gate.sh`) now reads the pictures back on an
800x600 output at scale 2 with three real `weston-eventdemo` clients: three snapshot nodes, one
per row; each row's picture `60x48 of 500x400`, which is the window's shape and inside the box;
**148 of 148** sampled opaque pixels of each row equal the picture's own octets at the coordinates
the layout gives (the right picture at the right place at the size it was taken); 16, 16 and 17
distinct colours per picture, so they are pictures and not flat fills; the titles now start one
column further right, after the picture column, and still end on the last device pixel of the last
glyph -- 58, 46 and 58 device pixels for ALPHA, BETA and GAMMA, ending at 907, 895 and 907 -- while
a Tab damages `(674 444 250 208)`, two rows rather than the output; a pointer moving over the
clients for 0.8 s leaves the pictures the same vectors and still on the screen; the nested
section finds a picture in the inner frame and matches an opaque pixel of it at the inner device
coordinate the layout gives. 75 checks, and the whole gate 20/20. Six new unit tests (suite 13,
`tests/unit/switcher.lisp`, 36 tests; the suite went from 312 to 318): the box fit and its
never-upscale rule; a picture row being taller with titles in one column after the picture; a
16x8 window's picture being the window's own two flat halves at scale 1 *and* at scale 2 (a
bilinear of a constant is that constant, whatever the ratio, which is what makes the assertion
about orientation and colour at once); a window with no pixels falling back to the title-only
layout; `set-node-size` resizing a rectangle and refusing a client's buffer; and -- the one that
is the decision -- a test that *rewrites the client's pixels* after the overlay opens and finds
the stored picture and the drawn frame unchanged. That last one needs real pixels without a
socket, so the fixture maps a memfd read-write and hands the compositor a `shm-pool` over it: the
test plays the client, which is the only way to prove a snapshot is a snapshot.

**Consequences.** Every row now says what it is offering, the switcher still touches nothing
while it is open, and the cost is one small pixman target per window per opening (allocated,
downscaled, copied out, freed -- not per frame). A window that maps while the overlay is up is
not shown, and a window that changes while it is up keeps its old picture: both are the same
decision, and both are what the person chose when they held the key. What this does not do:
live previews, thumbnails anywhere but the switcher, a picture cache that survives closing,
animations, or a picture of a window that has no buffer (it gets its title, in its column). The
lesson: **a thumbnail is a decision about freshness, and the only freshness a damage diff can
believe is "taken once, at a known moment" -- so take it where the person opened the thing.**

## D53 — The dragged edge follows the pointer; the anchored edge follows the client

**Date:** 2026-11-26
**Status:** accepted
**Slice:** edge-anchored resizing

D42 gave a resize its geometry: the edge opposite the one being dragged is recorded when the grab
begins, and the node is put back so that edge stays still -- using the size the client actually
came back with, because the node's size is the client's and the compositor cannot resize a buffer
it does not own. That was right about the anchor and wrong about the hand. Nothing placed the node
on a motion, so a left-edge drag moved the window only when the client answered: the visible edge
sat still under a pointer that had moved on, then jumped to it, once per configure round trip. The
roadmap had it as open for two slices.

**Decision.** A resize now places the node *twice*, and the two placements answer different
questions.

1. **On every motion, at the size the drag asked for.** `grab-motion` repositions the node with
   `place-anchored` and the size it just requested, so a left-edge drag has its left edge under the
   pointer in the same motion event that moved it. The window leads; the pixels follow.
2. **On the client's answer, at the size the client chose.** `grab-anchored` still runs when a
   commit arrives for the grabbed surface and places the node by the size that came back, so the
   anchored edge is exact no matter how the client answered -- including a client that clamped the
   request to its own minimum.
3. **A commit that is only a repaint is not an answer.** The node's believed size is remembered
   on the grab, and the placement at the client's size happens only when a commit shows a size
   that differs from it. Without that guard a client redrawing during a drag -- which every client
   does -- would put the node back where the old size said, and the next motion would move it
   again: a visible jitter for as long as the hand moved.
4. **The trade is stated rather than hidden.** Because the node *is* the buffer (D10), placing it
   at the requested size while the content is still the old size means the content is briefly short
   of the far edge (growing) or overlapping past it (shrinking) by the width of one round trip.
   That is what a hand-led resize looks like in every compositor with client-side decorations, and
   it is the right way round: a person dragging an edge is watching the edge, not the far corner.
   The alternative -- only ever placing by the answer -- is what D42 built, and it makes the *edge
   under the hand* lag, which is the one thing a drag cannot do.
5. **The anchor arithmetic itself is untouched.** It is still in window-geometry coordinates, so a
   decorated client's shadow stays outside it (D42), and the pure `resize-target-size` still
   clamps both directions (D46). This slice changes *when* the node is placed, not where the edges
   are.

**Evidence.** Gate clause 16 (`scripts/tinywl-parity.sh`) drives a real `weston-eventdemo` client
through a third drag on an 800x600 output, headless: Alt+right on the window's left border grabs
the left edge; one motion to x 40 leaves the node's x at **40** with the buffer still the **220**
the client last committed, i.e. the edge is at the pointer before any answer; the release and the
client's answer then give a **200**-wide buffer with node x + width still **240**, the anchored
right edge. 115 checks in the two runs (headless 53, nested 62), up from 110. Five new unit tests
(`tests/unit/scene.lisp`): a left drag placing the window at the pointer at once, a repaint commit
at the old size leaving that placement alone, and the anchor exact once the answer arrives; a
shrinking drag doing the same the other way (the content briefly overlapping past the anchor); a
top drag doing it on the y axis; a right-edge drag placing nothing because the left edge is the
anchor; and a decorated drag subtracting `geometry-x` so the buffer starts its shadow's width left
of the visible edge. The suite went from 318 to 323 tests; the gate
is 20/20.

**Consequences.** A left or top drag now tracks the pointer from the first motion, which is what
the sixth manual test's finding asked for, and the anchor is still exact at rest for a client that
honours the configure. A client that refuses part of a resize (clamps to a minimum) leaves the
anchor where the drag's last placement put it plus its own answer -- one correction at the moment
of the answer, which is the client's statement about its own size. What this does not do: cancel a
resize with Escape and restore the starting size (a compositor can bind `end-grab`, but "put it
back" needs remembered state, and it is a policy with a UI of its own); clip the window to the
requested box during the round trip (that needs a per-node clip in the scene); or animate the
correction. The lesson: **an anchor and a hand are two different rulers -- keep the far edge
faithful to the client and the near edge faithful to the pointer, and never let one substitute for
the other.**

## D54 — KMS splits at master, and the half that only describes the screen is built first

**Date:** 2026-11-26
**Status:** accepted
**Slice:** the DRM card, its connectors, and a dumb buffer (phase 4, first half)

Phase 4 as planned is six to eight weeks: DRM dumb buffers with page flips, libseat sessions,
libinput, libxkbcommon, multi-output, a software cursor, and an exit gate that wants a real TTY
session, twenty VT switches, hotplug, an eight-hour soak and suspend/resume. That is not one
slice, and its first attempt has to run somewhere. The somewhere is the problem: the machine
this project is being built on presents through Umbriel on VT 1, `/dev/tty2` belongs to root, so
an unprivileged process cannot switch VTs; and taking DRM master on `card1` would take the
display away from the session the user is sitting in front of, with nothing in the kernel that
gives it back.

**Decision.**

1. **Phase 4 is four slices, cut at the master boundary, not at a file boundary.** 4a is the
   card's describing half: resources, connectors, encoders, CRTCs, modes and dumb buffers,
   with no `SETCRTC` and no `PAGE_FLIP`. 4b takes the display (modeset, page flips, restore).
   4c is seats and input (libseat and libinput). 4d puts tinywl on DRM with libxkbcommon and
   walks the phase-4 gate list. The cut is the one the kernel already makes: everything in 4a
   is allowed on a card another process owns, and 4b is exactly the set of calls that needs to
   own the screen.
2. **4a is therefore shippable and gateable while somebody is using the machine.** The gate
   proves that rather than promising it: the connector state read from sysfs is identical before
   and after, the device reports that it was never master, and the descriptor count is flat.
   Being able to check the hardware during a working day is what makes the risky half (4b)
   smaller when it arrives.
3. **libdrm, transcribed rather than groveled.** The structs we read -- `drmVersion`,
   `drmModeRes`, `drmModeConnector`, `drmModeModeInfo`, `drmModeEncoder`, `drmModeCrtc` -- are
   written out by hand and their sizes (56, 80, 88, 68, 20, 100) and the three offsets that
   matter (mode name 36, connector modes 40, CRTC mode 28) are asserted at load time, the same
   way `wayland.ffi` asserts its socket structs. A build that needs libdrm's headers and a C
   compiler to *read* the card is a build that fails on a machine where only the library is
   installed; and a wrong offset has to be a load error rather than a silent misread of kernel
   memory. The calls themselves are libdrm's (`drmModeGetResources` and friends,
   `drmModeCreateDumbBuffer`, `drmModeMapDumbBuffer`, `drmModeAddFB`, `drmModeRmFB`): the
   libdrm ABI is stable, and hand-rolling the ioctls would be six chances to get an ioctl number
   wrong for no gain.
4. **Borrowed C memory is copied and freed before the next call.** An inventory is Lisp structs
   with numbers and strings in them -- the same rule as D35, applied to the kernel's objects
   instead of pixman's. The only foreign memory that outlives a call is a dumb buffer's mapping,
   and that one is stated where it happens because it is ours for as long as the buffer exists.
5. **Two layers: six kernel calls, and the contract above them.** `drm-claim-dumb`,
   `drm-map-dumb-memory`, `drm-unmap-dumb-memory`, `drm-allocate-framebuffer`,
   `drm-release-framebuffer` and `drm-release-dumb` are the only functions in the project that
   make these calls, and they are generic functions. Everything a compositor uses
   (`drm-create-dumb`, `drm-map-dumb`, `drm-add-framebuffer`, `drm-destroy-dumb`) is a plain
   function over them that checks arguments, remembers what it made and releases it in order.
   The reason is not layering for its own sake: it makes the marshalling testable without a
   card. A recording device sees ADDFB asked for depth 24 and bpp 32 with the driver's pitch and
   handle, and it sees the release order. 4b will want the same seam for a fake CRTC.
6. **The release order is one function, because the order is the contract.** `drm-destroy-dumb`
   removes the framebuffer, unmaps, then destroys the handle -- RMFB, then munmap, then
   `DESTROY_DUMB`. A framebuffer left behind keeps the memory alive after the handle is gone; a
   mapping left behind is a SIGBUS waiting for the next frame. No caller is offered the three
   steps separately, so no caller can get it wrong.
7. **Mode choice is a total order in Lisp, and refresh is integer millihertz.** An exact
   width-by-height match wins, then the monitor's preferred mode, then the largest area, then
   the fastest, then by name. 59.94 Hz and 60 Hz are `59940` and `60000` millihertz and compare
   unequal; a float would have lost that, and the difference is real on this monitor's EDID.
8. **The probe paints through the renderer that will draw the frame**, not through a byte loop
   of its own: a pixman target over the dumb buffer's mapping, a background and one rectangle,
   then three pixels read back at the corners and the rectangle's edge. A wrong pitch or a
   mapping that is not the buffer becomes a wrong pixel, and the mapping is proved to compose
   with the renderer 4b will use.
9. **No card, or no permission, is a skip and not a failure.** `EACCES` on a device node is the
   difference between *this machine has no card* and *this user's session was not given this
   card*, and neither is a broken implementation: the clause exits 77, which the gate reports as
   SKIP. A gate that fails on a laptop without `/dev/dri` teaches people to ignore it.
10. **One dependency is stated rather than discovered later**: `drmModeGetConnectorTypeName`
    needs libdrm 2.4.111 or later. Earlier versions had no such helper and every compositor
    carried a copy of the kernel's enum; requiring the helper is one table fewer to be wrong.

**Evidence.** Gate clause 21 (`scripts/drm-gate.sh`, `scripts/drm-gate.lisp`) runs the probe
against this machine's card and makes **37 checks**. `card1` is `amdgpu` 3.64.0 (the same name
`/sys/class/drm/card1/device/uevent` reports), opened with `master=NIL`, with dumb buffers and
PRIME. It enumerates **4 CRTCs** (108, 114, 120, 126), **2 connectors**, **6 encoders** and no
framebuffers. `DP-1` is disconnected by both libdrm and sysfs; `HDMI-A-1` (id 138, 600x340 mm) is
connected by both, offers **29 modes** where `/sys` prints **34** -- sysfs prints the connector's
whole table, `GETCONNECTOR` answers with the probed subset -- and every one of the 29 is a size
sysfs lists; every mode has totals larger than its visible size and a refresh between 20 and 240
Hz; the preferred mode is 3840x2160 at 594000 kHz, **60.000 Hz**, type `#x48`. Every connector's
encoder id and every encoder's CRTC id names an object the same enumeration found. A dumb buffer
at the preferred mode is **3840x2160, pitch 15360, 33177600 bytes**; mapped; painted through a
pixman target; `(0,0)` and `(63,47)` read back `#xFFFF8000` (the rectangle), the last pixel and
`(64,48)` read `#xFF101820` (the background); `ADDFB` named it framebuffer 158 and `RMFB`
forgot it; destroying it left neither a mapping nor a framebuffer. Afterwards the descriptor
count is **5 -> 5**, the device still reports it was never master, and the sysfs connector state
is **identical** to before the probe. The CRTC read is the other half of the point: CRTC 108 is
currently scanning out framebuffer 154 at 3840x2160, read without master -- that is the state 4b
has to put back. The gate is **21/21 clauses** (clause 21 reports these 37 checks).
Twenty-two new unit tests (`tests/unit/drm.lisp`, suite 14) take the suite from 323 to **345
tests in 14 suites**: refresh arithmetic (60000 vs 59940 millihertz, and zero totals answering
zero instead of dividing by it); the preferred flag against the driver flag; an exact size
winning over a larger mode, then preferred, then largest, then fastest; the connector status
decoding and the word sysfs uses; connector type names ("HDMI-A", "DP", "eDP", and a `TYPE-`
fallback); an inventory found by name and by id; pixel addressing through a **padded** pitch over
a real memfd mapping, with the padding byte proved never to be read as a pixel; an unmapped
buffer refusing a pointer; CREATE_DUMB asked for 32 bits per pixel and the driver's pitch and
size kept; a driver answering a pitch narrower than the width refused; ADDFB asked once, with
depth 24, bpp 32, the pitch and the handle; the release order **RMFB -> munmap -> DESTROY_DUMB**
and no RMFB at all when there is no framebuffer; map/unmap recording what they sent; a closed
device refusing an inventory and naming itself; `open-drm-device` on a missing node reporting
`ENOENT` and the path; and sysfs cards, connector state, device paths and the driver name
from a uevent, all read from fixture trees instead of the live machine.

**Consequences.** The hardware half of the framework now exists and can be exercised on a
working desktop, and 4b starts from a card that is already enumerated, a mode already chosen,
memory already allocated and the previous CRTC state already readable. What this does not do:
set a mode, flip a page, present a frame, open an input device, hold a seat, own the screen,
switch VTs, re-layout outputs on hotplug, or draw a cursor into the scanout buffer -- those are
4b to 4d, and 4b needs an explicit decision about taking the display and a plan for giving it
back. Nor does it read EDID properties or planes (4b and phase 5). The lesson: **the kernel's
object model splits at master -- everything that *describes* the screen can be read by anyone
the session trusts, and only the act of *showing* needs to own it -- so build, gate and live
with the describing half first, on the machine you are using.**

## D55 — The screen is taken with two settings and given back with its connectors

**Date:** 2026-11-27
**Status:** accepted
**Slice:** master, SETCRTC, page flips and the restore (phase 4, second half)

4a left 4b as the set of calls that need to own the screen. This slice makes them, and the
whole design is about the fact that owning a screen is a decision with a debt: a mode set is a
screen changed, and the debt is the state that was there before. The slice was built against
**vkms**, the kernel's virtual KMS -- a real KMS driver with a connector, modes, page flips and
vblank, and no display on the other end.

**Decision.**

1. **A card another client holds is not taken, and EBUSY is the answer we keep.**
   `SET MASTER` on a card with a master answers `EBUSY`, and this project reports that as a
   skip rather than retrying, stealing or asking logind to help. That is not politeness: it is
   the only mechanism that made this slice testable on a machine somebody was using. Loading
   vkms handed the live compositor a second output, and it claimed the card within seconds;
   the gate said EBUSY and stopped. Pausing the session (a VT switch, which logind turns into
   a device release) is what freed the card.
2. **Which cards a program may take is the program's policy, stated at the edges.** The module
   will take whatever it is pointed at, because a compositor on a real TTY must. The gate and
   the demo take a virtual driver -- `vkms` -- and nothing else, unless a person names a card
   *and* sets an allow variable: two settings, because taking a screen should take two
   deliberate acts. The driver is asked through libdrm and not `/sys`, because vkms presents as
   a faux device and its uevent says `faux_driver` while the driver says `vkms`.
3. **The scanout is the unit, and it owns the debt.** `DRM-OPEN-SCANOUT` becomes master, saves
   the CRTC's state *and the connectors it was feeding*, allocates, maps and names the buffers,
   then programs the CRTC; a failure anywhere undoes those steps in reverse and re-signals, so
   a failed open never leaves a card taken. `DRM-CLOSE-SCANOUT` restores, destroys and drops
   master, attempts each step even when an earlier one failed, and signals the first failure
   afterwards: a restore that fails must not also leak the buffers, and a buffer that will not
   go away must not leave the card taken.
4. **Restoring means naming the connectors again.** `SETCRTC` with a mode and an empty connector
   list is `EINVAL` -- measured, on vkms, on the first attempt at a restore. So the state to put
   back is not only "framebuffer and mode" but "framebuffer, mode, and what it was lighting",
   and the scanout saves all three. A saved state that is inconsistent (a mode with no
   framebuffer, which the kernel will not accept back) is restored as off, because off is the
   nearest legal state rather than an error that leaves a CRTC half set.
5. **There is no present that does not wait.** `DRM-SCANOUT-PRESENT` queues the flip and waits
   for the kernel's completion before it returns, because drawing into a buffer the display is
   still reading is the one thing double buffering exists to prevent. The wait has a deadline
   and a timeout is a `DRM-ERROR` about time, not a hang.
6. **Events are a stream parsed by a pure function.** No `drmHandleEvent`, no libdrm callbacks:
   `read(2)` on the descriptor is one of the kernel-call generics, and the parser is an ordinary
   function over octets, so several completions in one read, a record cut in half, an unknown
   kind and a corrupt length are unit tests instead of things discovered mid-flip. What the
   parser does not consume is kept -- whole events on the device, partial bytes for the next
   read. The flip's user-data is a per-device counter the kernel echoes back, so a completion is
   self-describing; the sequence numbers and timestamps are the kernel's, and monotonicity of
   both is what the gate asserts.
7. **`SET MASTER` is privileged even on a virtual card.** Unprivileged it is `EACCES`, so the
   clause that takes a screen runs as root -- and `scripts/lib.sh` learns to find the person's
   Quicklisp through `SUDO_USER` rather than requiring a second copy of CFFI under `/root`.
   Related and measured: on a *free* primary node the kernel makes the first opener master, so
   "take master" is a real transition only on a contended card; the gate records the state at
   open instead of asserting it is NIL.
8. **A defect found by the slice belongs to the slice.** The demo's first run crashed the
   process: `fill-rect` passed a negative `x` through to `pixman_image_fill_boxes`, which wrote
   **60 bytes before the mapping** and faulted. That is not a DRM bug -- it is a renderer bug
   that any window dragged past the left edge would have hit -- and it is fixed here, in
   `fill-rect`, by computing the intersection with the target instead of trusting pixman to clip
   a box that starts outside it. The regression test maps a guard page in front of the target,
   so a recurrence is a dirty page rather than a dead test process.

**Evidence.** Gate clause 22 (`scripts/drm-modeset-gate.sh`) makes **31 checks, 0 failed**
against `/dev/dri/card0` = vkms 1.0.0, on a VT the session had been paused off, so logind had
released the card. It enumerates 1 CRTC (45), 1 connector `Virtual-1` (id 53, connected, 34
modes), 1 encoder (52, possible CRTCs `#b1`), preferred mode 1024x768 at clock 65000 with totals
1344x806, **60.004 Hz**; vkms's own state at load was framebuffer 55 scanning 1024x768. It takes
master, opens a scanout (two buffers, 1024x768, pitch **4096**, framebuffer ids 57 and 58),
`GETCRTC` agrees the CRTC scans framebuffer 57 at 1024x768, both mappings are painted through
the pixman target and read back, and **three page flips are retired by the kernel**: sequences
**83407, 83408, 83409**, vblank timestamps 44429.364187 / 44429.380852 / 44429.397518 (16.6 ms
apart), our CRTC id and our user-data 1, 2, 3 echoed in each, in 0.044 s. Closing restores
framebuffer **55** and 1024x768, drops master, closes the descriptor, leaves the descriptor count
at **6**, and leaves the sysfs connector state **identical**. The demo (`scripts/drm-demo.sh`,
`--frames 300`) then flipped **300 frames**: mean interval **16.65 ms** (13.35 fastest, 17.20
slowest) = **60.1 Hz**, sequence numbers **83440 to 83739 contiguous and monotonic**, and it too
restored framebuffer 55 and dropped master. Measured around it: `SET MASTER` unprivileged is
`EACCES`; on a contended card it is `EBUSY`; without master, `CREATE_DUMB`, `MAP_DUMB` and
`ADDFB` succeed while `SETCRTC` and `PAGE_FLIP` are both `EACCES`; the first restore attempt
failed `EINVAL` because it named no connectors, and the first demo run died with a memory fault
60 bytes before a dumb-buffer mapping at `x=-15`. Thirty-eight new unit tests
(`tests/unit/drm-modeset.lisp`, suite 15, 38 tests) and three new render tests take the suite
from 345 to **386 tests in fifteen suites**, and clause 22's skip branches cover no card, no vkms, `EACCES`
and `EBUSY`. What this does not do: no atomic API, no planes, no cursor into the scanout buffer
(4d), no VT handover or seat management (4c -- the VT switch used here was logind's doing, not
ours), no triple buffering, no damage-driven redraw (the demo repaints whole frames), no
hotplug, no EGL. The lesson: **owning a screen is a debt, and the debt is paid in the state you
read before you took it -- connectors included, because the kernel will not accept the mode
without them.**

---

## D56 — Input is a decode path and a permission; the seat is an availability subscription

**Date:** 2026-11-27
**Status:** accepted
**Slice:** seats and input (phase 4, third slice)

4b left phase 4 with a screen it could take and nothing to put on it. This slice is the other
half of input: which device the kernel says a key came from, and who is allowed to open that
device at all. It was built while a live compositor owned the session, which turned out to be
the most informative constraint of the whole slice.

**Decision.**

1. **The slice is the decode path, not the session takeover.** `cf.session` (libseat) and
   `cf.backend.libinput` land together, but the module that *runs a compositor on a VT* is 4d's
   business. What is proved here is that a device's own reports arrive, are named, and reach a
   compositor's seat through the same `inject-*` calls a test uses.

2. **Access is the `input` group, chosen deliberately from four routes.** The candidates were a
   virtual keyboard written through `/dev/uinput`, logind's `TakeDevice` through libseat, the
   `input` group, and a decode-only slice with fixtures. The group wins because it is a
   permission on the device nodes and not on the session: nothing is grabbed, no seat protocol
   is entered, and the compositor already reading those nodes keeps its keys. It costs a
   `usermod -aG input`, a re-login (group membership is applied by PAM, so a shell that predates
   the change keeps the old set -- the gate says exactly that rather than reporting `EACCES` as
   a defect), and it does not scale to multi-seat. `TakeDevice` is the multi-seat story and
   belongs with the VT work in 4d, where a compositor owns a seat anyway.

3. **A seat is a subscription, so the session is a state machine, not a file handle.** The
   provider calls `enable_seat` when the seat becomes usable and `disable_seat` when it goes
   away; devices may be revoked; a disable must be acknowledged after the devices are closed, or
   the provider closes them itself and the closes then report `EBADF`. So: `:opening`,
   `:enabled`, `:disabled`, `:closed`; enable and disable hooks called *after* the state changes
   (a hook that reopens devices has to find the seat enabled); every callback error recorded
   rather than signalled, because an error escaping a C callback unwinds through C; and eight
   generics (`%open-seat`, `%close-seat`, `%acknowledge-disable`, `%open-device`,
   `%close-device`, `%dispatch`, `%switch-session`, `%seat-fd`) so the machine has unit tests.

4. **A session another client controls is a skip, and libseat's errno is the last backend's.**
   Measured on this machine: seatd is inactive; logind answers `EBUSY` to `Session.TakeControl`
   because the running compositor holds it (a C probe, `/tmp/seat-probe.c`, showed
   `Could not take control of session: Device or resource busy`); libseat then falls through to
   its no-op backend and returns `ENOSYS`. The gate names both errnos and skips. Working around
   it -- stealing control, asking logind for a device behind the session's back -- would break
   the session that is working, which is the same judgement D55 makes about a card another
   master owns.

5. **libinput opens devices through its interface, and the seat is optional.** The interface's
   `open_restricted` asks `cf.session` when there is a seat and `open(2)` when there is not;
   libinput cannot tell the difference. That is why one decode path serves both worlds, and why
   the gate can prove the device half without a seat.

6. **A delta becomes a position here, and the clamp is on the accumulator.** A mouse reports
   movement, the seat wants a position; accumulating without clamping means a pointer pushed
   5000 pixels past the edge and brought back five is at 4995, not 794. The clamp is applied to
   the running position on every event (D47's rule, applied to the device instead of a grab).

7. **The legacy axis event is not decoded.** Since libinput 1.19 every scroll is also delivered
   as `SCROLL_WHEEL`/`SCROLL_FINGER`/`SCROLL_CONTINUOUS`, and `POINTER_AXIS` is documented as
   sent *in addition*. Decoding both scrolls twice, which is a bug that feels like a sticky
   wheel rather than a bug.

8. **An unnamed key is reported, not dropped.** libinput reports evdev codes; the phase-3 table
   names the keys a compositor needs. A key outside it is `:unknown-key` with its code, because
   "nothing happened" and "there is no such key here" must not look the same in a log.

9. **The evdev-to-keysym join lives in `cf.input`, beside the table.** `key-entry-for-code` and
   `key-name-for-code` index the one table rather than adding a second one, so a key that is in
   the keymap is a key a device can produce, and the shifted keysym name is never the answer for
   an unshifted code.

10. **No `/dev/uinput` in the gate.** A virtual keyboard would prove the round trip on a device
    we create, and it would also appear in the live session as a real keyboard -- a test key
    would be typed into whatever window has focus. The chain clause feeds raw events into a real
    compositor's seat instead: same translation, no reach into somebody's session.

**Evidence.** `scripts/input-gate.sh` (clause 23): **34 checks, 1 skip, 0 failed**, 18 event
nodes present and 9 accepted by libinput (`Power Button`, `IKBC USB Keyboard` and its
consumer/system/mouse siblings, the mouse, `Eee PC WMI hotkeys`), every accepted device announced
exactly once and configured, descriptor count identical before and after, and the chain:
evdev 60 fires an `F2` binding, 5000-pixel motion clamps to 799 and comes back from the edge
(795), one wheel click is one axis event, code 240 is counted as unknown. The seat part skips
with libseat's `ENOSYS` (logind's `EBUSY` behind it) because this session has an owner. Unit
tests: `tests/unit/session.lisp` (12 tests) and `tests/unit/libinput.lisp` (16 tests) take the suite from **386 tests in fifteen suites** to **413 tests in seventeen**;
`./scripts/run-tests.sh` prints `PASSED`. Cold build into an empty fasl tree: our files compile,
babel's pre-existing warnings and nothing else. `libseat.so.1` and `libinput.so.10` are now
load-time dependencies of `cl-compositor-framework`, like `libdrm.so.2` (D4's category, and the
purity clause still finds no libwayland or libwlroots). What this does not do: no VT handover
callbacks exercised (4d), no libxkbcommon (4d), no udev hotplug inside a running compositor
(the path context is what the gate uses; the udev context is implemented and untested live), no
touch, tablet, gesture or switch events, no cursor in the scanout buffer, no `wl_keyboard`
repeat handling beyond what phase 3 had. The lesson: **the honest test of a permission is
opening the file, and the honest test of availability is the callback -- everything else is a
guess about somebody else's machine.**

---

## D57 — The keymap is the library's, and it comes from the session

**Date:** 2026-11-27
**Status:** accepted
**Slice:** the keymap (phase 4, fourth slice, first part)

Phase 3 owed clients a keymap it wrote itself: a table of forty-odd keys serialized into XKB
text by hand, self-contained, small enough to diff. It could not be a keyboard layout, and D28
said so -- libxkbcommon belongs with libinput. This slice links it, and `cf.input` becomes what
wlroots' keyboard code is.

**Decision.**

1. **The keymap is compiled from the rules, not written out.** `xkb_keymap_new_from_names` with
   rules `evdev`, model `pc105` and whatever `XKB_DEFAULT_LAYOUT`/`_VARIANT`/`_OPTIONS` say.
   That is the whole point: a user's layout configures this compositor the way it configures
   every other one, and nothing in this tree needs to know that code 21 is `y` here and `z`
   there. The hand-written table is deleted rather than kept as a fallback: two keymaps that
   disagree is exactly the defect the table's own history kept producing (TLDE missing, the
   off-by-eight, the modifier column).

2. **What a client receives is the merged map, serialized by the library.**
   `xkb_keymap_get_as_string` writes the resolved map -- every `include` expanded, four levels
   per key, dead keys and all -- into a sealed memfd the seat already knew how to send (D28).
   The protocol's requirement is that the client needs no access to `/usr/share/X11/xkb`; the
   serialized map is how that stays true, and parsing it back (`keymap-from-string`) is how this
   project checks that the text *is* the keymap (clause 24). On this machine the default map is
   35,757 bytes; the phase-3 hand-written one was about two thousand, and neither number matters
   to a memfd.

3. **A bad layout is two different answers.** `compile-keymap` with names of your own signals
   `keymap-error` when they do not compile -- the mistake is the caller's, and a silent fallback
   would hide a typo in a config. The *session's* keymap (`default-keymap`) falls back to
   `evdev`/`pc105`/`us` with one line on stderr: refusing to start a compositor because
   `XKB_DEFAULT_LAYOUT` has a typo is worse than starting with the default layout. Both behaviours
   are asserted, because they are the two ways this can be wrong.

4. **Keysyms are the index, not names.** A binding is written with a name (`"Tab"`, `"Alt_L"`),
   and the reverse lookup has to answer two things a name-keyed table could not: case
   insensitivity (`"f2"` is `F2`) and shifted keysyms (`"asciitilde"` finds the key that types
   it). So the index is keysym -> keycode, built once by walking the keymap's keycodes and levels
   with the levels *outside* the codes, so a key's unshifted keysym wins over its shifted one.
   This was found by the gate: a name-keyed index passed `"F2"` and failed `"f2"`, which is the
   kind of bug a config file produces on a user's first try.

5. **A key's name comes from its unshifted level.** `key-name-for-code` answers the name a
   binding is written with, and a binding names a key rather than a key-plus-shift. What the key
   *types* in the current state is a different question, and it has its own answer
   (`modifiers-keysym`/`-name`), which is what a client's own keymap does with the code it is
   sent. `keycode` now takes an optional keymap for the same reason: the gate asks a `de` map and
   a `us` map in the same process, and a function that could only ask the ambient one would be
   untestable where it matters.

6. **The masks are the keymap's, and the constants are checked against it.** Shift is bit 0 and
   Mod1 is bit 3 in the standard rules, and a binding table is full of `+MODIFIER-MOD1+`. Rather
   than assume, `keymap-modifier-mask` reads the mask out of the compiled keymap (Mod4 is 64
   because Mod2 and Mod3 sit between), and the module asserts at load time that the four
   constants agree -- a reordered keymap fails at load instead of mis-dispatching every Alt
   binding with no error anywhere.

7. **The state is an `xkb_state`, so the seat reports the library's answer.** Depressed, latched,
   locked and the effective group are `xkb_state_serialize_*` on a state updated per key event.
   Caps Lock is no longer special-cased: the compatibility rules decide, and what they decide is
   *not* what the hand-written table did -- measured against the same keymap from C, a tap's press
   applies the lock and the *second* tap's release clears it, where the old table toggled on the
   press. So the test asserts the contract a person has (one tap locks, the next unlocks) and not
   the intermediate masks, which belong to the library.

8. **The environment claim is tested from outside the process.** libxkbcommon reads
   `XKB_DEFAULT_*` when a keymap is compiled, so a single image cannot show that a layout is the
   session's. Clause 24 runs the same probe twice, with `XKB_DEFAULT_LAYOUT=us` and `=de`, and
   each run is told which letter code 21 must type. That is the cheapest honest test of "the
   layout is not ours" that does not need a second machine.

**Evidence.** `scripts/xkb-gate.sh` (clause 24): **90 checks** in two layouts (45 each), 0
failed. The default keymap serializes to 35,757 bytes, keycodes 9..709; the serialized text
parses back and names all eleven sampled codes identically and still types `A` with Shift held;
`us` types `y` at code 21 and `de` types `z` there and `y` at 44; `Tab` = 15, `F2` = 60,
`f2` = 60, `asciitilde` = 41 in `us`; Shift/Mod1/Mod4 are #x1/#x8/#x40 and `Alt_L` sets exactly
Mod1; a letter repeats and `Control_L` does not; the state reports #x1 depressed after a Shift
press and group 0, and a Caps Lock tap locks and the next unlocks. The seat gate (clause 12) now
has a real client parse a rules-compiled map: `keymap: parses standalone, keycodes 9..709`, key
16 with `unicode: 81` as before, descriptors flat. The focus gate (33 checks), the switcher gate
(75) and tinywl parity (53 + 62) are unchanged -- which is the evidence that the names, the masks
and the bindings still line up, since those gates dispatch Alt+Tab, Alt+F1 and Alt+Esc by name.
Seventeen unit tests replace the eight that pinned the hand-written table, taking the suite from
**413 tests in seventeen suites** to **422**. `libxkbcommon.so.0` becomes a load-time dependency
of `cl-compositor-framework`, beside `libdrm`, `libseat` and `libinput`; the purity clause still
finds no libwayland or libwlroots. What this does not do: no per-device layouts, no
`xkb_state_key_get_utf8` feeding a text-input path, no compose or dead-key handling above the
keymap (a client applies the map itself), no `input-method`, no LED state, and the keymap is
still one per seat rather than one per keyboard. The lesson: **a layout is a fact about the
session, so anything this project says about a key has to be a question to the keymap -- the
moment it is a table here, it is wrong in another country.**
