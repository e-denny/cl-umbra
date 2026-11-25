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
- Client id reuse is now *lowest free id* rather than most-recently-released, which is what
  `docs/protocol-layer.md` §8 already claimed. Traces read like libwayland's.
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
