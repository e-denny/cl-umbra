# Testing

A compositor fails in ways that are hard to see: a wrong serial opens no window, an
unreleased buffer freezes one client, a bad damage region shows a smeared frame for one
refresh. The test strategy is therefore layered, and each layer exists because it catches a
class of bug the others cannot.

---

## 1. Layers

| Layer | Catches | Runs in | Cost |
|---|---|---|---|
| Unit (codec, schema, regions, ids) | arithmetic and encoding mistakes | anywhere | ms |
| Property/fuzz (decoder, pool validation) | crashes, overreads, leaks | anywhere | seconds |
| Client loopback (socket pair standing in for a compositor) | client dispatch, ids, roundtrip, event decoding | anywhere | ms |
| Trace replay (recorded `WAYLAND_DEBUG`) | divergence from libwayland behaviour | anywhere | seconds |
| Interop (real clients against our server; our client against real servers) | protocol conformance | needs a session | minutes |
| Golden image (headless render → PNG hash) | rendering, damage, transforms, scale | anywhere, no GPU | seconds |
| Scripted end-to-end (headless compositor + client + assertions) | policy: focus, move, resize, workspace switching | anywhere | minutes |
| Config and control (reader safety, schema, reload atomicity, eval-channel limits) | the entire user-facing control surface | anywhere | seconds |
| Soak/chaos (kill clients, exhaust fds, long runs) | lifetime bugs | dedicated machine | hours |
| Manual hardware (TTY, VT switch, hotplug, suspend) | driver/session integration | real machine | per phase |

## 2. Fixtures and tools

Installed for testing only (never linked by our binaries):

- `weston` + `weston-simple-shm` — the canonical shm client.
- `wayland-utils` (`wayland-info`) — global dump and protocol inventory.
- `kitty`, `foot` — real terminal clients.
- A GTK4 app and a Qt app — toolkit conformance.
- `sway` or `weston` as reference servers for our client.
- `xwayland-satellite` + an X client (phase 6 tail).

Recorded traces are committed under `tests/fixtures/traces/` with the exact client version in
a sidecar file, because traces are only comparable against known-good versions.

### Running the suite

Tests run on [Rove](https://github.com/fukamachi/rove) (D17). One test file is one package is
one Rove suite:

```
./scripts/run-tests.sh                      # everything; exit status is the verdict
TEST_VERBOSE=1 ./scripts/run-tests.sh       # every assertion and its form
(wayland.test.runner:run-all)               # same from a REPL (:style :spec lists assertions)
(rove:run-suite 'wayland.test.wire)         # one file
(rove:run-test 'wayland.test.wire::header-only)
```

`asdf:test-system "cl-wayland-tests"` works too, for anyone who prefers to drive it from
ASDF. Assertions are Rove's own: `(ok FORM "description")` for a predicate, and
`(ok (signals FORM 'condition-type))` for an expected error; a failure prints the test name,
the assertion, its source location and the arguments' values.

The scripts go through `wayland.test.runner`, which names the nine suites instead of letting
Rove find them from the system. Rove's lookup maps each fasl back to its source, which only
holds when the fasl is in ASDF's user cache; a build with a different output translation (a
cold-cache check, a packager) would otherwise run zero suites and report success. The runner
also fails when a named suite is missing or empty, so "green" always means 201 tests ran.

Two suites test the two ends of our own stack. `wayland.test.client` drives the client against
a socket pair it writes bytes into by hand. `wayland.test.server` starts a real display on a
real socket in a private directory and puts either our client or a hand-written peer on the
other end:

- **Our client, pumped.** Neither side may block, so the client's reactor gets a 1 ms
  repeating timer that runs one server cycle; an ordinary `(roundtrip client)` then drives
  both ends, and registry order, bind validation, initial-event ordering and version gating
  are checked through the public client API.
- **A raw peer, for illegal requests.** Unknown object ids, unknown opcodes, a `new_id`
  already in use or in the server's range, a version above the global's, a request above the
  resource's version, and a request with no handler (`implementation`) are each written to
  the wire directly, and the test reads the server's `wl_display.error` reply field by field.
- **The transport itself.** Peer credentials, `CLOEXEC` on accepted descriptors, the accept
  budget, a half-written message kept as a partial tail, 50 connect/disconnect cycles with a
  flat descriptor count, and backpressure: queue more than a socket buffer, check the interest
  dropped to write-only, drain it, check reading came back.
- **Seats and input.** Nine `wl_seat` tests: the name-then-capabilities order on bind; a
  keymap arriving as a descriptor that maps to exactly the bytes the seat was given (and
  `repeat_info` after it); `missing_capability` for a seat that never had the capability;
  `wl_seat.release` refused at version 4; a key reaching only the focused keyboard, with the
  enter/modifiers/key/modifiers order; pointer enter/motion/button/axis/leave with the fixed
  coordinates and the serials a client needs for grabs; a region's union and difference; a
  region snapshotted at commit and outliving its object; and a pool that grows, refuses to
  shrink, and refuses to grow past its file.
- **The scene.** Eighteen tests: stacking and raising, node-local coordinates through a nested
  group, an invisible node taking nothing, a buffer node being exactly its buffer (size, edges,
  and "no buffer is not a window"), an input region deciding what a surface takes (`nil` for the
  whole surface, `:empty` for click-through, a rectangle list with an exclusive far edge), node
  removal and repositioning, and — against a real headless compositor — the cursor's pixels at
  the pointer, the old place cleaned up after a move, the cursor not being hit-testable, a
  hidden cursor not being drawn, rectangles drawn in stacking order, and a target that survives a
  full GC (D35: pixman holds the address, so the pixels are not a Lisp vector). The same file covers
  grabs and keybindings: a move grab following the pointer's delta and ending exactly once, a
  resize grab asking once per distinct size (with the edge arithmetic tested on its own), Alt+Esc
  stopping the reactor, Alt+F1 cycling and focusing, and an unbound key being left alone. Plus,
  in `wayland.test.server`, a region destroyed before the commit it belongs to, serial validity
  over the recent window, and the move-request rule (our serial *and* the focus).
- **The client's own requests.** Twenty-nine `wayland.test.client` tests. The phase-3e ones pin
  the wire the nested backend depends on: `create_surface`/`create_region` id allocation and
  parent-version inheritance; the `wl_surface` request opcodes and argument order (attach with a
  buffer id and an offset, damage, `frame`'s `new_id`, a `nil` input region as a *null id*,
  `set_buffer_scale`, commit); that `wl_shm.create_pool` carries exactly one descriptor as
  ancillary data, spends no octets on it, and that the descriptor names the same file as the
  client's mapping (written through one, read through the other); that pixel access checks
  bounds, that fills clip, and that a buffer larger than its pool, a short stride and a
  misaligned stride are all refused before anything is written; that `attach` accepts the
  client-buffer struct; the four `wl_seat` factories and the device releases; the xdg-shell
  handshake's arguments; and that a `ping` produces a `pong` with the same serial after one
  dispatch and one flush.
- **The shell's refusals.** Eight `xdg-shell` tests drive the same raw peer through the v1
  handshake and through every way a client can get it wrong: a second role, a second
  `xdg_surface` on one `wl_surface`, a buffer before the initial ack, an ack for a serial we
  never sent, both destruction-order errors, and a request we deliberately do not implement
  (positioners). Two more follow the happy path: map, frame callback after presentation rather
  than at commit, `attach(nil)` unmapping, and the buffer coming back; and a ping answered with
  its own serial. A test that found nothing to read also found something: `wl_surface.attach`
  is opcode 1, not 0 — opcode 0 is `destroy`.

Those fixtures bind `wayland.server:*log-level*` to `:warn`: the assertions are the evidence,
and 50 connect/disconnect log lines are not.

One workaround is load-bearing: `tests/cl-wayland-tests.asd` unlocks SBCL's `SB-DI` package
before Rove loads, because dissect 20231021 (Rove's failure renderer) interns symbols from it
and SBCL 2.6 locks it. The unlock lives in the test system only, so no shipped system is
affected; remove it when dissect fixes its SBCL backend.

### The gates

`scripts/gate.sh` encodes `PLAN.md` §5's exit gates as clauses it checks rather than assumes.
Each prints `PASS`, `FAIL`, `SKIP` (no session to talk to) or `NOT BUILT`; the exit status is
0 when all pass, 1 when one fails and 2 when a clause has nothing behind it, so a clause that
is merely planned can never look like a green gate. Failure logs land in a temporary directory
whose path is printed.

Phase 0 (protocol core and a hello-world client), five clauses: the unit suite, "every
vendored protocol compiles", `demo-globals` against the live session, the fuzz harness, and
purity (D1).

Phase 1 (server core), four clauses — the first two from the slice that built the server,
the last two added once there was something to attack:

1. **`wayland-info` against our server** (`scripts/wayland-info-server.sh`). The demo server is
   started on its own socket in a private runtime directory, `wayland-info` — the system's own
   build, with its own libwayland — runs against it and must exit 0, the output must name both
   demo globals and the output's mode, the server must exit 0 on `SIGTERM`, and its socket
   and lock file must be gone afterwards. This is the first clause in the project that puts a
   real libwayland peer on the other end.
2. **Soak** (`scripts/soak.sh`, `scripts/soak.lisp`). 10k connect/disconnect cycles, each
   asking for the registry and a sync, half of them closing mid-exchange. Descriptor count
   must be identical before and after, the resident set must not grow by more than 2 MiB, and
   no client or object may survive its connection. `SOAK_CYCLES` overrides the count; 1000
   runs in well under a second, 10k in about half a second, so the gate runs the full 10k.

3. **The peer fuzzer** (`scripts/fuzz-client.sh`): 10⁶ adversarial connections, with the
   invariants in §4.2. This is the "fuzz client cannot crash or wedge the server" clause that
   `PLAN.md` asked for; it did not exist when the server first landed, and the gate said so
   instead of ticking it.
4. **An independent C client** (`scripts/c-probe.sh`, `tests/c-client/wayland-probe.c`): a
   libwayland client that binds `wl_output` at version 3, checks the initial events and their
   order, calls `wl_output_release`, and then proves `wl_display.delete_id` arrived the only
   way a client can: the released id comes back on a later bind. It also binds at version 1
   and checks that no newer event reaches it, and binds and destroys `wl_compositor`. The
   probe is compiled into a temporary directory and linked against the system's
   libwayland-client on purpose: it is the peer, not the product, and D1 applies to what we
   ship.

Purity runs last, after both phases' clauses, because it is a standing constraint rather than
a phase deliverable.

Phase 2a (shared memory and the first pixels) adds one clause:

10. **The headless frame** (`scripts/headless-frame.sh`, `tests/c-client/wayland-shm-client.c`,
    `scripts/headless-gate.lisp`). A libwayland client binds `wl_compositor` and `wl_shm`,
    writes a known 64x32 pattern into a memfd (left half opaque red, right half opaque blue),
    creates a pool and a buffer from it, attaches the buffer at (10,20), damages it, asks for a
    frame callback and commits. The driver runs the compositor's reactor until the client
    exits — which it only does when the callback arrives, i.e. after the frame is presented —
    then checks nine pixels: the pattern, its four edges and the background. It also writes a
    PNG and validates its chunks and CRCs. `weston-simple-shm` is not the client here -- it
    needs `xdg-shell`, and the place for a client that needs a window is clause 11.

Phase 3 (xdg-shell toplevels) adds one clause:

11. **A real xdg-shell client** (`scripts/xdg-shell-gate.sh`, `scripts/xdg-shell-gate.lisp`).
    `weston-simple-shm` -- the client the phase-2 plan always wanted, with its own libwayland
    and its own idea of a window -- binds `xdg_wm_base`, creates an `xdg_surface` and an
    `xdg_toplevel`, commits without a buffer, receives our `xdg_toplevel.configure` (0×0, empty
    states) and `xdg_surface.configure`, acks the serial, attaches a shm buffer and draws. The
    driver asserts: a configure was sent *and acked*; the toplevel mapped; a title arrived; the
    initial configure was 0×0 with no states; `xdg_wm_base.ping` we sent came back as `pong`;
    the client is still connected (no `wl_display.error` in either direction); the frame has
    more than a thousand drawn pixels and more than eight distinct colours inside the window
    rect and none outside it; and teardown leaves no clients or objects. A PNG is written and
    validated. The client is a redraw loop, so the gate *ends* it with `SIGTERM` and checks
    that it stopped -- "exits 0 by itself" would be a claim about weston, not about us.

Phase 3b (seats and input) adds one more:

12. **Seats and input, against a real client** (`scripts/seat-gate.sh`,
    `scripts/seat-gate.lisp`, `tests/c-client/xkb-keymap-probe.c`). `weston-eventdemo` — a
    real client with its own libwayland and its own xkbcommon — is started on a pty (so its
    stdio is line-buffered and its output can be read as evidence), maps a window, and is
    focused by the compositor. The gate then injects pointer motion to (50, 60), a left button
    press and release, a vertical scroll of 15, and Shift followed by q, and requires the
    *client's own output* to contain: the enter ("focus x: 0, y: 0"), the motion with those
    coordinates, the button with code 272 at (50, 60), the axis with value 15.000000, and
    `key key: 16, unicode: 81, state: pressed, modifiers: 0x1` — keycode 16 translated through
    the keymap we sent into "Q", with the shift mask our modifiers event reported. It also
    checks the seat's state (capabilities, keymap, focus, keyboard objects with enter), that
    the toplevel was configured `activated`, that the keymap we sent parses standalone
    (`XKB_CONTEXT_NO_DEFAULT_INCLUDES`) and translates keycode 1 to Escape and Shift+q to Q,
    that the keymap descriptor we created is closed after it travelled, and that teardown
    leaves nothing behind.

Phase 3c (the scene) adds the thirteenth:

13. **Two windows, hit testing, click to focus and a cursor** (`scripts/scene-gate.sh`,
    `scripts/scene-gate.lisp`). Two independent `weston-simple-shm` clients — each with its own
    libwayland and its own object ids — map a toplevel each. The gate asserts the cascade put
    them at (0,0) and (32,32) with non-zero buffers; that the second one took the keyboard when
    it mapped and the hover did *not* take it away; that hovering window A moved the pointer
    focus while the keyboard stayed on B; that clicking A moved the keyboard, configured A
    `activated` and B without states, and that clicking B moved both back; that hit testing
    finds A at (5,5), B at (37,37) and nothing at (500,500); that both windows' pixels are drawn
    where they were placed; and that the cursor's opaque black tip and opaque white body are the
    exact pixels at the pointer's position, which is only true if it is composited last.
    Hit-testing with two redrawing clients is also what proved stacking had to stop following
    commit order, and the input region the client destroys immediately is what proved regions
    are copied at request time (D31.3, D31.5).

Phase 3d (grabs and keybindings) adds the fourteenth:

14. **A real client is moved and resized by serial** (`scripts/grab-gate.sh`,
    `tests/c-client/wayland-move-client.c`, `scripts/grab-gate.lisp`). The client is compiled at
    gate time with xdg-shell's client code generated by `wayland-scanner` from our vendored XML.
    It maps a window, and on a left-button press calls `xdg_toplevel.move(seat, serial)` with the
    serial from the button event the compositor sent; the gate drags and asserts the window's
    node moved by exactly the pointer's delta and its pixels moved with it; it releases and
    asserts the grab is gone *and* that a further motion does nothing; it right-drags and asserts
    `configure 240x180` arrived from a 200x150 window and a (40,30) drag; and a second right-drag
    that would leave the 512x512 output asks for `configure 482x472` — the window's anchored
    top-left is (30,40), so the bottom-right edge stops at the output's border (D46); a second
    and a drag whose pointer goes *past* the bottom edge while still moving in x configures
    `320x472` and then `420x472` — the far axis clamped, the near one still tracking (D47) — before
    both reach the edge at `482x472`; a second window is started so that Alt+F1 has somewhere to
    go, and the gate asserts the bottom window came to the top and took the keyboard; Alt+Esc must
    stop the reactor. Unit tests cover what
    the gate cannot: an invented serial and a real serial without focus are both refused, a
    grab's second ending is a no-op, the resize bounds themselves (four edges, a drag with no
    bound, and a client minimum larger than the output), and the axis independence — a drag past
    one edge that keeps tracking the other, the cursor staying where the device put it, and a
    `leave` ending the grab where a coordinate would not.

Phase 3e (the client library and a nested session) adds the fifteenth:

15. **Our compositor inside our compositor, with a real client inside that**
    (`scripts/nested-gate.sh`, `scripts/nested-gate.lisp`). One image, two sockets: a parent
    headless compositor, a nested backend connected to it as a *client* (the completed client
    library: surface, pool, two shm buffers, attach/commit, seat devices, the xdg-shell
    handshake), and `weston-eventdemo` running against the nested compositor's own socket. The
    gate asserts: the parent sees a mapped, titled ("cl-umbra nested"), app-id'd and
    activated xdg_toplevel, and its keyboard focus is our nested surface; the parent's frame
    equals the nested compositor's own target at five sample points *and* has content of its
    own (the parent's own cursor is parked in a corner, because it is not part of the nested
    output); a pointer motion injected into the parent reaches the client inside the nested
    session as a motion at the same coordinates; Shift+q injected into the parent arrives as
    keycode 16 with unicode 81 and modifier mask 0x1; the pointer, key and keymap counters on
    the backend are non-zero and the parent's keymap descriptor (7065 octets) crossed the
    boundary; teardown removes the parent's toplevel, empties its client list, and leaves the
    descriptor count where it started. A PNG of the parent's frame is written and validated —
    it shows the inner client's window inside the inner session's output.

Phase 3's exit gate adds the sixteenth, and it is the one clause that is a *script run
twice*:

16. **The tinywl parity script, headless and nested** (`scripts/tinywl-parity.sh`,
    `scripts/tinywl-parity.lisp`, `tests/c-client/wayland-move-client.c`). Two real
    libwayland clients — `weston-eventdemo` (which prints every key it receives and every
    size it is configured to) and the compiled move client (a uniform `#xFF3C8C3C`
    window) — are driven by hand through cl-tinywl: click to focus, typing, Alt+left drag,
    Alt+right resize, Alt+F1, Alt+Esc. The assertions are the ones `PLAN.md` §5 lists: both
    windows land at (0,0) because that is what tinywl.c places (the framework's cascade is
    overridden on purpose), the top window's pixels are there and the lower one's come back
    when it is dragged aside, the click moves the keyboard, the focused client prints
    `key key: 16, unicode: 81` while the unfocused one prints nothing further, the drag
    moves the node by the pointer's delta and stops on the release, Alt+right at the corner
    produces `resize width: 240, height: 180` in the *client's* output and a 240x180 buffer, a
    second drag grabbed at the window's *left* border asks for `resize width: 220` and leaves the
    right edge where it was while the left one follows the pointer (D42), a drag past the output's
    corner stops with the window flush against it while the pointer goes where the device says, and
    a drag whose pointer leaves the output ends instead of dragging on unseen (D43), Alt+F1 raises
    the bottom window, and Alt+Esc sends `xdg_toplevel.close` to both clients and stops the loop
    with no `wl_display.error` anywhere. On the decorated window both runs then require a resize
    to be arithmetic in *window geometry*: a 50-pixel left drag asks for 692 of 742, the visible
    right edge (node x + geometry x + geometry width) is unchanged, and the client's own 2-pixel
    frame is the only difference left (D43). One client runs with
    `WAYLAND_DEBUG=1` and its coloured log (ANSI escapes stripped) is checked for an ordered
    `get_registry` → `configure` → `ack_configure`. The whole scenario then runs a second
    time with tinywl *nested* inside a headless parent, injecting input into the parent, which
    exercises the same policy through `cf.backend.nested`'s translation; the nested run also
    checks that the parent ends with no window and no clients of ours. Both runs also press
    `Alt+Shift+Return` and require a *new* client on tinywl's own display with a mapped window
    (`weston-terminal`, which is what a launcher has to get right), and the nested run configures
    the nested toplevel from the parent side (`request-toplevel-size 800x600`) and requires the
    inner output, the scene and a fresh presented frame to follow it with the window inside still
    drawn (D37). The nested run also asks for three frames and requires the target a presenter is
    handed to hold non-background pixels at each of them — the frame is drawn before it is
    committed, which is what a parent compositing that shared buffer at its own moment needs
    (D38). Finally, the pixel at the parked pointer has one expected answer per mode: the white
    cursor body in the headless run (this session draws it) and the background in the nested one
    (the parent draws the pointer, and a second arrow at the same spot is a wrong picture, D39).
    The same point also asks the scene about the *client's* cursor image: a real `weston-terminal`
    names two cursor surfaces, and neither may have a scene node — a roleless surface given one is
    a stray cursor stuck at the output's origin (D40). And the pointer's picture follows the
    client: over the terminal's text area the scene's cursor image is the one that client
    installed, with its hotspot, and the nested run requires the parent to be told to draw no
    pointer while we draw the client's (a 1x1 transparent image) and, at a bare-output spot where
    there is no client image, this session's own arrow to be drawn while the parent stays blanked —
    one pointer shows at all times (D41, revised).

Popups and positioners add the seventeenth:

17. **A menu, placed by its positioner, dismissed by the user** (`scripts/popup-gate.sh`,
    `scripts/popup-gate.lisp`, `tests/c-client/wayland-popup-client.c`). A compiled libwayland
    client draws a 300x200 window and opens menus the way a menu does:
    `create_positioner` → `set_size` / `set_anchor_rect` / `set_anchor` / `set_gravity` /
    `set_constraint_adjustment` → `get_popup` → `grab(seat, serial)` → initial commit → ack →
    attach. The output is 320x240, deliberately barely larger than the window. The gate
    injects the presses and asserts, from its own state and from the pixels: the first menu's
    configure is `(30 30 120 80)` -- the anchor point of `(10 10 20 20)` with bottom-right
    gravity, which is arithmetic, not a number the client sent -- and its magenta pixels are at
    (35,35) and (145,105) with the window's green around them; the grabbed popup owns the
    pointer (`cf.grab:popup-grab`); Escape dismisses it (popup_done, and the grab ends); a
    second menu anchored at the window's bottom-right corner would leave the output, so the
    compositor **flips** it and the configure is `(170 110 120 80)`, with the requested place
    (305,205) still empty -- which proves the constraint box the framework supplied is the
    output expressed in the parent's window-geometry space; and a press outside the menu
    dismisses it *and* is swallowed, so the client's own log shows no click for a menu that had
    already closed. A second scenario runs the *same* binary with `--follow-pointer` -- the mode
    `scripts/popup-demo.sh` uses for a manual test, where the menu is anchored at the pointer
    rather than at one of the two fixed anchors -- and requires a click at (77, 63) to produce
    `(78 64 120 80)` (a 1x1 anchor rectangle at that point, bottom-right anchor and gravity),
    its pixels inside, and Escape to dismiss it. Unit tests cover what a real client cannot
    easily ask for: an incomplete positioner, a popup that would be its own parent or whose
    parent has no role, no parent at all, a grab after mapping, a grab the compositor cannot
    honour (which dismisses the popup), and destroying a popup that is not the topmost. Two
    framework tests pin the placement rules: a menu is not a window to cycle, and a menu follows
    the window it belongs to and stays above it.

Phase 3g (the focus stack) adds the eighteenth:

18. **Three windows, Alt+Tab, and a window closing** (`scripts/focus-gate.sh`,
    `scripts/focus-gate.lisp`). Three *independent* `weston-simple-shm` clients — separate
    processes, separate connections, their own libwayland — map a window each on an 800x600
    output and are moved to (0,0), (150,0) and (300,0), so a click can name one unambiguously
    while the overlaps are there to raise into. The gate asserts: the last window to map has the
    keyboard and the stack reads (C B A), with only C configured `activated`; Alt+Tab focuses the
    *least* recently focused window (A), raises it (checked as the frontmost scene child),
    configures A `activated` and C not, and rotates the stack to (A C B); three more presses visit
    B and C and wrap to A; a click at (280,10) focuses B and moves it to the front of the stack
    *without* raising it, because raising is the compositor's policy and not the framework's; and
    closing B (`xdg_toplevel.close`) hands the keys to A, configures A `activated`, drops B's node
    and takes B out of the stack; two windows toggle, and one window makes Alt+Tab a no-op.
    Seven unit tests pin the rules the gate cannot isolate: the push order with no duplicates, a
    popup pushing the window it belongs to (and never entering itself), a roleless surface never
    entering, a rotating cycle that wraps and raises, two windows toggling, a closed window handing
    the keys on down to the last one, and an empty cycle.

The nested run of clause 16 also takes space *away*: after growing the nested output to
800x600 it configures it to 400x300 and requires every live window to satisfy the clamp
invariant (`x` in `[0, W-w]` for a window that fits, `[W-w, 0]` for one larger than the output)
— a shrunken output used to leave its windows half outside it and unreachable (D37's open
question, closed by D46) — then puts the space back.

All eighteen clauses pass. Two details worth knowing: the protocol clause
compiles all 69 files into throwaway packages without loading them (duplicate interface
versions across the corpus make loading unsafe, compiling is local), and the demo clause is
skipped rather than failed when there is no `WAYLAND_DISPLAY` socket, so the gate runs
headless apart from that one clause.

## 3. Wire codec

- **Byte-exact vectors**: hand-written expected bytes for every argument type, including
  padding and the size/opcode split.
- **Roundtrip property**: encode → decode → equal, over generated values with boundary sizes
  (0, 1, 3, 4, 4095, 65536), null vs non-null objects, fds.
- **Oracle**: for each vendored protocol, generate C with `wayland-scanner` in a test script
  and compare opcode numbers, signatures and interface versions against our tables. Cheap,
  and catches schema-parser regressions immediately.
- **Trace replay**: decode a real client's messages and assert the resulting call sequence.

## 4. Fuzzing

Two fuzzers, asking different questions. Both share one seeded random source
(`tests/fuzz/rng.lisp`, xorshift64*, not `cl:random`) so a seed means the same thing in
either, and both print the seed first because the seed is the whole bug report.

### 4.1 The decoder fuzzer

`scripts/fuzz.sh [ITERATIONS] [SEED]` (`tests/fuzz/fuzz.lisp`, system
`cl-wayland-tests/fuzz`): does garbage either decode or get rejected, without overrunning,
looping, allocating unboundedly or leaking a descriptor? It runs in-process over a socket
pair. Three kinds of case, chosen at random:

| Case | What it feeds | What must hold |
|---|---|---|
| header | random octets, half the time with a plausible header | `decode-header` returns NIL or a header with `size ≥ 8`, `size % 4 = 0`, `size ≤ 65532`, object id ≠ 0; no crash |
| schema | random octets decoded as the arguments of a random message from the loaded protocols | values or a `wayland.wire` condition; never overrun the buffer or loop |
| transport | random writes to one end of a real `socketpair`, `pump` on the other: garbage, truncated messages, whole messages, some with descriptors attached | only whole messages dispatch; the partial tail stays under 2× the maximum message size; the input buffer never exceeds 4× its 64 KiB start; every descriptor the stream delivered is closed |

Hard rules: a case that signals anything other than a `wayland.wire` condition is a failure;
a run that misses its deadline (60 s, or 1 s per 10 000 iterations) is a hang; the open
descriptor count (`/proc/self/fd`) must return to what it was once the harness closes its own
socket pair, pool and buffers.

```
./scripts/fuzz.sh 1000000 12345
```

Budget: 10⁶ cases in the gate, 10⁴ in `make check`, both well under three seconds today.
Finding so far, on its first run: `wayland.io` queued descriptors that a rejected stream
would discard without closing, so `reset-input-buffer` now closes them by default.

### 4.2 The peer fuzzer

`scripts/fuzz-client.sh [ITERATIONS] [SEED]` (`tests/fuzz/client-fuzz.lisp`, system
`cl-wayland-tests/fuzz-client`): can a *client* make the server crash, wedge, leak, or answer
with a malformed message? Every case is one real connection to a live demo display, and the
cases are the protocol-level counterpart of the table above:

| Case | What it sends |
|---|---|
| garbage | 1–400 random octets |
| plausible | 1–4 well-framed messages from real schemas, with random objects, opcodes and arguments; half the time truncated mid-message |
| abusive | one specific illegality: `sync`/`get_registry` with a `new_id` of 1, 0 or a server id; an opcode no interface has; a real registry followed by a `bind` with a wrong interface, a wrong name or an impossible version; junk inside a message's declared size |
| bad size | a valid message whose size field says zero, a non-multiple of four, more than it carries, or less than a header |
| tiny | 0–32 octets, often not even a header |

The invariants are the interesting part, and they are asserted rather than inspected:

1. **well-formed replies** — every message the server writes parses, the sizes cover the
   stream exactly, and there is at most one `wl_display.error`, on `wl_display`;
2. **no wedge** — after the client closes, the server must have dropped it, checked after
   every case;
3. **no internal error** — the server's log is captured at `:error` for the whole run. A
   client fault is a protocol error; a Lisp error from our own code is a bug, and a client
   must not be able to cause one;
4. **across the run** — identical descriptor count, resident-set growth under 32 MiB, and a
   well-behaved client still gets its globals and a `sync` callback at the end and every 1000
   cases.

10⁶ connections take about 42 s here, so the gate runs the full million. The hang detector is
the same `sb-ext:with-timeout` watchdog as the decoder fuzzer.

Descriptors: the fuzzer's "plausible" case picks real requests, and since phase 2a
`wl_shm.create_pool` is one of them, so a real descriptor rides along with a random message
(its other arguments are nonsense, which is the point). What is still not covered is a
descriptor arriving on a request that declares none — surplus-fd detection, a phase-0
leftover that now has a place to be tested.

Not yet covered: the protocol content of phases 2b and later (regions, transforms, buffer
scale, pool resize), and anything that needs `xdg-shell`.

## 5. Interop matrix

| Our role | Peer | What must hold |
|---|---|---|
| server | `wayland-info` | every advertised global, version and event is valid — **passes** (`scripts/wayland-info-server.sh`) |
| server | our own C probe (`tests/c-client`) | bind, destroy, re-bind across versions; `delete_id` at the right time — **passes** (`scripts/c-probe.sh`) |
| server | the peer fuzzer | no crash, wedge, leak or malformed reply under 10⁶ adversarial connections — **passes** (`scripts/fuzz-client.sh`) |
| server | `weston-simple-shm` | buffer attach/commit/release, damage, frame callbacks, `xdg-shell` v1 -- **passes** (`scripts/xdg-shell-gate.sh`) |
| server | `weston-eventdemo` | `wl_seat` v4, keymap fd + `repeat_info`, focus, key/button/motion/axis events, translation to the right unicode -- **passes** (`scripts/seat-gate.sh`) |
| server | `kitty` | keyboard, clipboard-adjacent paths, resize, popups |
| server | GTK4 app | subsurfaces, buffer scale, fractional scale, decoration negotiation |
| server | Qt app | buffer formats, `xdg_popup`, activation |
| server | a dmabuf client | import, modifier negotiation, fallback to shm |
| client | our own server (the nested backend) | surface + shm pool + buffers + attach/commit, the xdg-shell handshake, seat devices and keymap fd -- **passes** (`scripts/nested-gate.sh`) |
| client | `sway`, `weston` | registry, bind, roundtrip, fd passing, seat events |
| both | ourselves (nested) | each side exercises the other; the nested compositor is a test |

The matrix is a script, not a checklist: `scripts/interop.sh <server> <client>` starts the
pair on a private socket, runs a scenario, and diffs the observed client log against
expectations.

What runs today without a session: `tests/unit/client.lisp` puts a socket pair in place of a
compositor and asserts the bytes the client writes (`get_registry`, `bind`'s four wire
arguments) and what it makes of the bytes a compositor would write (globals, `delete_id`,
`wl_display.error`, a message split across two writes, an event carrying a server-allocated
`new_id`). `tests/unit/server.lisp` puts our client — or a hand-written peer — on the other
side of a real display. `demo-globals` against the live session is the one check that needs a
foreign compositor; it is compared with `wayland-info` by diff, not by eye.

Rows that still have nothing behind them are the protocol content of phases 2 and later: the
toolkits, dmabuf, and our client as a *window on a live foreign compositor* (the nested backend
is proven against our own server in one image; running it on the user's session needs a window
there, which is a separate authorized step). The peer fuzzer and the C probe cover the
*transport* half of the server's obligations, not the compositor's.

## 6. Golden images

The headless backend plus the pixman renderer gives deterministic pixels:

```
scene fixture → render → read-pixels → PNG → hash
```

- Compare with a tolerance (per-pixel delta and a percentage of differing pixels), never
  exact equality across pixman versions.
- One fixture per behaviour, not per protocol: opaque stacking, alpha blending, buffer
  scale 2, fractional scale 1.5, output transform 90/180/270, damage-only repaint,
  subsurface offsets, popup positioning, cursor composite, letterboxing.
- Every fixture also runs through the GL renderer in phase 5 and must match within tolerance;
  that is the acceptance test for "the GPU path is correct".

## 7. Scripted end-to-end

A test compositor (headless backend, synthetic input) plus a scripted helper client that can
be told to attach buffers of known colours and to record the events it receives:

1. Map two windows, assert stacking and focus.
2. Click the lower one, assert focus change and `set_activated` on both.
3. Drag: assert motion is consumed by the compositor (grab) and the window moved.
4. Resize from each edge and corner: assert configure size and geometry.
5. Alt+F1: assert focus cycle and restacking.
6. Popup: assert grab, outside click dismisses, `popup_done` delivered.
7. Workspace switch: assert only the active workspace's surfaces get frame callbacks.
8. Client destroyed mid-grab: assert grab ends, no dangling surface.
9. Config: reload a broken config, assert nothing changed; reload a good one, assert exactly
   the intended change.
10. Control: forms over the eval channel match on-screen state; the same call from a
    binding, a script and the REPL is one code path; a runaway form hits the deadline.

These are the tests that would have caught tinywl's own shortcuts.

## 8. Purity check

The project's central claim is "no libwayland, no wlroots". Verify mechanically:

```sh
# 1. link-time: nothing in ldd output
ldd ./cl-tinywl | grep -E 'libwayland|libwlroots' && exit 1
# 2. load-time: nothing dlopen'd
grep -E 'libwayland|libwlroots' /proc/self/maps && exit 1
# 3. symbol-time
nm -D ./cl-tinywl | grep -E 'wl_display_create|wlr_backend_autocreate' && exit 1
```

Runs in CI for every phase-0+ commit. It is the one test that cannot be waived.

## 9. Performance

Benchmarks with explicit thresholds; a regression fails the build.

| Benchmark | Metric | Threshold |
|---|---|---|
| encode/decode small message | ns/message | encode < 150, decode < 1000 |
| dispatch a pointer motion | µs, bytes consed | < 2 µs, 0 consed |
| frame with 1 / 5 / 20 surfaces at 1080p | CPU ms/frame | 1.5 / 4 / 12 |
| 4K frame, 1 opaque client | CPU ms/frame | < 5 |
| idle compositor | CPU % | < 1 |
| roundtrip latency | µs | < 200 |
| 100 idle clients | RSS | flat over 10k cycles |

Allocation is measured, not assumed: `sb-ext:get-bytes-consed` around a fixed interaction,
asserted zero in steady state for the input, commit and render paths.

## 10. CI

- Linux x86-64, SBCL versions current and previous.
- Jobs: `unit`, `fuzz (10⁴)`, `schema-oracle`, `golden`, `e2e-headless`, `purity`,
  `perf` (tolerant), `nightly-soak`, `nightly-fuzz (10⁶)`.
- No GPU and no session required for any of the above: headless + pixman is the default
  renderer in CI, which is a direct payoff of the shm-first decision (D3).
- A separate, optional, self-hosted job runs the DRM backend with a dummy/VKMS device
  (`vkms` gives a virtual KMS device — useful for page-flip tests without a monitor).

## 11. Manual hardware checklist (per phase 4+)

- [ ] TTY start, clean exit, no leaked fds (`ls /proc/<pid>/fd | wc -l`)
- [ ] VT switch away and back ×20
- [ ] unplug/replug output ×10, with windows on it
- [ ] suspend/resume ×5
- [ ] lid close/open (if laptop)
- [ ] 8-hour soak with an animating client
- [ ] client kill -9 during drag, during resize, during a popup grab
- [ ] fill the disk / exhaust fds / fork bomb a client, then disconnect it

## 12. Debugging aids to build early

- `WAYLAND_DEBUG`-compatible tracing (so existing tooling and habits work).
- A message dump in both directions with object interface names and decoded args.
- Per-client log prefixes with pid; per-resource ids in every protocol error.
- A `(cf:dump-state)` that prints clients, resources, surfaces, outputs, seats, grabs and
  scene tree — the thing you want in a bug report.
- A frame-timing histogram per output (render time, vblank delta, missed frames).
