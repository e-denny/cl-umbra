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
- `weston-eventdemo` — a client that prints the keys and pointer events it receives, and takes
  `--title=`; the seat, focus and switcher gates name it (a switcher row is only identifiable
  if the client gave its window a title).
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

The scripts go through `wayland.test.runner`, which names the eighteen suites instead of letting
Rove find them from the system. Rove's lookup maps each fasl back to its source, which only
holds when the fasl is in ASDF's user cache; a build with a different output translation (a
cold-cache check, a packager) would otherwise run zero suites and report success. The runner
also fails when a named suite is missing or empty, so "green" always means 451 tests ran.

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
    right edge where it was while the left one follows the pointer (D42); the *headless* run then
    takes a third drag grabbed at that left border and asserts the thing a hand feels (D53): one
    motion with no answer yet leaves the node's left edge at the pointer (x 40) while its content is
    still the size the client last committed (220), and once the client answers with the 200 the
    drag asked for the anchored right edge is still exactly where it was (240). A drag past the
    output's corner stops with the window flush against it while the pointer goes where the device
    says, and
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

Phase 2b (rendering) adds the nineteenth:

19. **Scale, transform, damage and opaque culling** (`scripts/render-gate.sh`,
    `scripts/render-gate.lisp`, `tests/c-client/wayland-scale-client.c`). A compiled
    libwayland client draws one 64x32 buffer of four coloured quadrants and decides its own
    `wl_surface.set_buffer_scale` and `set_buffer_transform`; the gate reads the frame back at
    the device coordinates each case implies. At buffer scale 1 on a scale-1 output the quadrants
    are 32x16 each and 2048 device pixels are drawn. On a *scale-2* output the same buffer is
    magnified to 128x64 — the far device corner is the buffer's last pixel, the pixel past it is
    background. At buffer scale 2 on a scale-2 output it is 1:1 again: 64x32 device pixels for a
    32x16 layout, so a HiDPI client that drew at the output's scale is copied, not resampled.
    Transform 90 (counter-clockwise) draws 32x64 with the buffer's right column on top — green
    above red, white beside blue — and transform 180 turns it end for end; both are checked as
    four quadrant samples plus an out-of-bounds pixel. The pointer is drawn 32x32 device pixels
    on a scale-2 output (its body's white at device (12,16) from logical (5,5)), and a *nested*
    session at scale 2 is checked from its parent's side: the parent's server saw
    `buffer_scale 2`, a 200x160 buffer for a 100x80 layout, and the window drawn at 100x80 layout
    pixels. Then, with no client at all, a scene of two opaque rectangles and a translucent veil
    is moved five times; the last frame must repaint less than the whole output (60x41 of
    120x90), at least one frame must be partial, and — the invariant the whole slice rests on —
    the incrementally painted frame must equal a full repaint of the same scene *pixel for
    pixel* (`cf:frame-octets` on both sides), with `cf:invalidate-output` producing exactly that
    full repaint. Unit tests (`tests/unit/render.lisp`, suite 12, 22 tests) cover what the gate cannot
    isolate: region union/intersect/subtract/translate, the eight transform matrices as numbers,
    a scaled bitmap's blocks, a 64x32 buffer at scale 2 being a 32x16 *window* to hit testing,
    the damage a moved node reports, an opaque window uncovering what it hid, the blend of a
    premultiplied translucent rectangle, and the nested backend's buffer-age arithmetic (a slot
    nobody has seen, a slot that missed one frame, one that missed a full frame, one whose
    missing frame was never recorded, and a history that keeps two frames and reuses two
    regions).

The visible switcher (phase 3i) adds the twentieth:

20. **Alt+Tab, drawn** (`scripts/switcher-gate.sh`, `scripts/switcher-gate.lisp`). Three
    independent `weston-eventdemo` clients -- separate processes, separate connections, their own
    libwayland -- are started with `--title=ALPHA`, `--title=BETA` and `--title=GAMMA` against
    *cl-tinywl* at scale 2, so the gate drives the port's own keymap rather than a function. The
    stack after three maps reads (GAMMA BETA ALPHA). Alt+Tab opens the overlay and the frame that
    holds it repaints the whole output (the draw list's order changed); the panel's colour is
    read three pixels inside its top-left corner and the outline's one pixel outside it, both at
    the coordinates `cf.switcher:switcher-layout` gives; the selection bar is found on row 0 and
    the panel colour on rows 1 and 2, at a point inside the panel's right edge. Each row also has
    a *picture* of its window (D52): three snapshot nodes, the window's shape fitted inside the box
    (60x48 of a 500x400 window), and **148 of 148** sampled opaque pixels of every row equal to the
    picture's own octets at the coordinates the layout gives -- the right picture, in the right
    place, at the size it was taken -- with 16, 16 and 17 distinct colours, so they are pictures
    and not flat fills. Each row's text is measured inside the panel and its own column only -- so
    a window that happens to contain the text colour cannot vote -- and must end on the last
    device pixel of the last glyph: 58, 46 and 58 device pixels for ALPHA, BETA and GAMMA, ending
    at 907, 895 and 907, one picture column further right than before. That is a width only that
    title produces, in the row only the focus stack puts it in, at the scale the output
    advertised. A Tab then moves the bar and the frame damages `(674 444 250 208)` -- two rows,
    not the output -- and two more steps wrap back to the first row; a pointer moving over the
    clients for 0.8 s leaves the pictures the same vectors and still on the screen, because a
    picture is a snapshot and not a live view. Releasing Alt closes the overlay, leaves no
    overlay nodes, focuses and raises ALPHA as the frontmost scene child, rotates the history to
    (ALPHA GAMMA BETA) exactly as one tap of the cycle always did, and the frame it leaves is
    **byte-identical to a full repaint** (`cf:frame-octets` on both sides), so nothing stale hid
    under the overlay. Escape cancels and is consumed (Alt is down, and Alt+Escape quits) without
    moving the keyboard; a pointer press cancels the overlay and is then delivered as the click
    it was; a point inside the panel hit-tests to the window under it and never to the overlay;
    Alt+Shift+Tab opens on the last row -- the window that has the keys -- and committing that
    row leaves the focus where it was; and all three clients are still connected at the end. A
    final section puts the overlay one compositor deeper: a nested tinywl at scale 2 inside a
    scale-1 headless parent, two clients inside it, Alt+Tab injected into the *inner* compositor --
    the panel is in the inner frame and in the parent's own frame at the coordinate the scale
    mapping implies, a picture is in the inner frame at its own device coordinate, and the release
    closes it inside and leaves no overlay nodes. 75 checks.
    Thirty-six unit tests (`tests/unit/switcher.lisp`, suite 13) pin what a gate cannot isolate: the
    font's 95 glyphs and their shape (a malformed glyph is a load-time error), text width as
    `6n-1`, a raster's premultiplication, its 2x2 blocks at scale 2 and the gap column between
    glyphs, the fallback glyph, `truncate-text`'s ellipsis, a text node's layout size against its
    device raster, the overlay between the windows and the cursor, the overlay never hit-tested
    and never adopted by the tree, `window-title`'s title → app-id → nothing order, the listing
    order, walking without touching the stack or the stacking order, wrapping both ways, the bar
    following the selection, a 60-character title cut rather than widening the panel, a nameless
    client getting a stand-in row, one window opening nothing, Alt+Tab through the real key path
    (press and release consumed, `consumed-keys` left empty, focus untouched), a modifier press
    that cancels nothing, the release that commits and raises, Escape, a click, idempotent
    cancel/commit, a window that vanished while the overlay was up, a compositor with no
    switcher binding still cycling the stack as D45 says, and -- for the pictures (D52) -- the
    box fit and its never-upscale rule, a picture row's extra height with the titles still in
    one column, a 16x8 window's own two flat halves at scale 1 and at scale 2, the title-only
    layout when nothing has pixels, `set-node-size` resizing a rectangle and refusing a client's
    buffer, and a test that rewrites a client's pixels after the overlay opens and finds the
    stored picture and the drawn frame unchanged (the fixture maps a memfd so the test can play
    the client).

Phase 4's first half adds the twenty-first:

21. **The DRM card, its connectors and a dumb buffer** (`scripts/drm-gate.sh`,
    `scripts/drm-gate.lisp`). No clients, no pixels on screen, no mode set: this is the half of
    KMS that works while somebody is using the machine (D54), and the clause is built to prove
    that about itself. The probe opens `/dev/dri/cardN` read-write and checks the driver name
    against `/sys/class/drm/cardN/device/uevent`, the DRM version's shape, that the device was
    opened **without** DRM master, and that it has dumb buffers and PRIME. It then enumerates
    resources, connectors, encoders and CRTCs, and compares every connector against the kernel's
    own view in `/sys/class/drm/cardN-<connector>`: the same connector names, the same plug
    state, a mode count that is at most sysfs's (sysfs prints the connector's whole table,
    `GETCONNECTOR` the probed subset) with every mode libdrm reports being a size sysfs lists,
    totals larger than visible sizes and refreshes between 20 and 240 Hz (a swapped or misread
    field lands here), the preferred mode present in both, and every connector's encoder id and
    encoder's CRTC id naming objects from the same enumeration. Each CRTC's current scanout is
    read, which is the state the next slice has to restore. Then, per connected connector: a
    dumb buffer at the picked mode, checked for a pitch of at least 4 x width and a size of at
    least pitch x height, mapped, painted through the pixman target the frame will use
    (background, then a rectangle at the origin), read back at three pixels, given a framebuffer
    id by `ADDFB`, released by `RMFB`, and destroyed. Finally the claims that make it safe to run
    on a working desktop: the connector state from sysfs is **identical** before and after, the
    device still reports that it was never master, and the descriptor count is flat. On the
    machine this was written on: 37 checks, `card1` (`amdgpu` 3.64.0) with 4 CRTCs, `DP-1`
    disconnected, `HDMI-A-1` connected at 600x340 mm, 29 modes of which the preferred is
    3840x2160 at 594000 kHz (60.000 Hz), a 3840x2160 dumb buffer at pitch 15360 and 33177600
    bytes, and framebuffer 158 added and removed. Two shapes of card were found to need
    stating rather than assuming: a writeback connector (`cardN-Writeback-M`) is in `/sys` and
    not in `GETRESOURCES` at all -- writeback is configured through atomic properties -- so it is
    excluded from the comparison by name, and a virtual card's uevent names a faux device
    (`faux_driver` for `vkms`) so the driver-name comparison is exempted only for a virtual
    driver, with the `/sys` name printed instead. When more than one card has a connector, the
    clause probes the real one first and says which it did not probe. No card, or a card this user was not given
    (`EACCES`), exits 77 and the gate reports **SKIP** rather than failing: neither is a defect
    in the code, and a gate that goes red on a machine without `/dev/dri` teaches people to
    ignore it. Twenty-two unit tests (`tests/unit/drm.lisp`, suite 14) pin the parts a card cannot isolate: refresh arithmetic in integer millihertz, mode
    choice as a total order, connector naming and status, pixel addressing through a padded
    pitch over a real memfd, and -- through a recording device -- the arguments of `CREATE_DUMB`
    and `ADDFB` and the release order `RMFB -> munmap -> DESTROY_DUMB`.

Phase 4's second half adds the twenty-second:

22. **The screen: master, a mode, three flips and the state put back**
    (`scripts/drm-modeset-gate.sh`, `scripts/drm-modeset-gate.lisp`). The clause that changes a
    display, and therefore a clause about *which* display: by default only a virtual card --
    `vkms`, which is a real KMS driver with a connector, modes, page flips and vblank and no
    screen on the other end -- and a real card only when a person names it with
    `CL_DRM_MODESET_CARD` *and* allows it with `CL_DRM_MODESET_ALLOW=1`. The driver is asked
    through libdrm rather than `/sys`, because vkms presents as a faux device and its uevent
    says `faux_driver`. The probe records the state at open (on a free primary node the kernel
    makes the first opener master, so that is recorded and not asserted), takes master, opens a
    scanout, and checks that two buffers exist and that `GETCRTC` now reports our framebuffer
    and the mode we set; it paints both mappings through the pixman target and reads them back
    at the driver's pitch; it flips three times and requires each completion to be the
    kernel's -- our CRTC id, our user-data, and sequence numbers and vblank timestamps that
    only go forward. Then it closes the scanout and checks the debt was paid: master dropped,
    the CRTC scanning the framebuffer and mode it had before, the descriptor closed, the
    descriptor count flat and the sysfs connector state **identical**. On the machine this was
    written on, against `card0` = vkms 1.0.0 on a VT the session had been paused off: 31
    checks, 1 CRTC, `Virtual-1` connected with 34 modes and a preferred 1024x768 at 60.004 Hz,
    vkms's own framebuffer 55 at load, two buffers at pitch 4096 (framebuffers 57 and 58),
    sequences 83407/83408/83409 retired 16.6 ms apart, restore to framebuffer 55, and 300
    frames in the demo at a mean 16.65 ms (60.1 Hz) with 300 contiguous sequence numbers.
    With D58 the clause also renders a **scene** -- cursor included -- into the scanout
    buffer at the driver's pitch, checks the pointer's pixels are in the buffer and the padding
    was not written, and presents that frame; the hardware-free half of the same claim (a padded
    memfd instead of a dumb buffer) is the `wayland.test.drm-frame` suite, six tests.
    Four answers are **SKIP** and not failure: no `vkms`, no connected connector, `EACCES` on
    `SET MASTER` (it is a privileged ioctl, so the clause wants root), and `EBUSY` because
    another master owns the card. The last one is not hypothetical: on this machine, loading
    vkms made the live compositor claim the card, and the clause refused it -- which is the
    behaviour the skip exists for. Thirty-eight unit tests (`tests/unit/drm-modeset.lisp`,
    suite 15) pin what a card cannot isolate: a mode written into the ABI struct and read back
    field for field, the event parser (several events per read, a partial record, an unknown
    kind, a corrupt length), the scanout's order of operations on a recording device
    (`take master -> save -> create -> map -> ADDFB -> SETCRTC`, and `restore -> RMFB ->
    munmap -> DESTROY_DUMB -> drop master`), `EBUSY` leaving nothing allocated, a half-built
    scanout undoing itself, and a restore that names the connectors or switches the CRTC off.
    Three more in the render suite cover the defect this slice found: a rectangle that starts
    left of the target, above it, or entirely outside it is clipped in `fill-rect` rather than
    handed to pixman, which wrote before the mapping and faulted; the test maps a guard page in
    front of the target and checks it afterwards.

Phase 4's third slice adds the twenty-third:

23. **The seat, the devices and the decode chain** (`scripts/input-gate.sh`,
    `scripts/input-gate.lisp`). Three parts, for three different reasons to fail. *The seat*:
    `cf.session` opens logind's seat for this session through libseat and reports its fd, its
    name and its availability; on a machine somebody is using, logind has already given control
    of that session to the running compositor and the open is refused, which the clause reports
    as a **SKIP** with the errno rather than as a failure -- D55's policy for a card another
    master holds, applied to a session another client controls. (libseat's own report is the
    *last* backend's errno: seatd's socket is absent here, logind answers `EBUSY` to
    `TakeControl`, and the no-op fallback turns that into `ENOSYS`, which is why the clause
    names both.) *The devices*: every `/dev/input/event*` is handed to a libinput path context,
    dispatched, and checked -- each opened device announced exactly once, named by the kernel,
    given the framework's defaults (tap-to-click, natural scrolling), at least one of them a
    keyboard, and the process's descriptor count identical afterwards. libinput refuses devices
    it has nothing to do with, so "opened 9 of 18 nodes" is the expected shape and each refusal
    is reported rather than counted as a defect. *The chain*: raw events -- what a device would
    have produced -- go through the decoder into a **real compositor's** seat, where evdev code
    60 must fire an `F2` binding (the join from code to keysym name to keybinding), a
    5000-pixel motion must land on column 799 rather than somewhere past it and come back from
    the edge on the next event, a wheel tick must deliver exactly one axis event (the legacy
    `POINTER_AXIS` is deliberately not decoded, or every scroll would be doubled), and an
    unnamed key (240) must be counted as unknown rather than dropped. On the machine this was
    written on: 34 checks, 1 skip (the seat), 18 event nodes present and 9 accepted by libinput
    -- `Power Button`, `IKBC USB Keyboard` and its consumer/system/mouse siblings, the mouse,
    and the WMI hotkeys. A virtual keyboard written through `/dev/uinput` was considered and
    **not** used: it would prove the round trip, and it would also appear in the live session as
    a real keyboard, so a test key would be typed into whatever window has focus. The chain
    covers the same translation with none of that reach. Twelve unit tests in
    `tests/unit/session.lisp` (the `wayland.test.session` suite) pin the availability machine against a recording seat
    -- enable during open, dispatch once, a hook that runs after the state changes, a device
    refused on a disabled seat, closes before the acknowledgement, a failing close counted,
    a second `close` doing nothing -- and sixteen in `tests/unit/libinput.lisp` (`wayland.test.libinput`) pin
    what no device can isolate: type classification, the deliberate absence of 403, the evdev
    code to keysym name join in both directions, clamping at the edge and not only at the
    report, absolute devices, unknown keys, scroll sources, device tracking by sysname, and a
    sink that signals not stopping the decoder.

Phase 4's fourth slice starts with the keymap, and adds the twenty-fourth:

24. **The keymap: compiled from the session's rules, and the same key somewhere else**
    (`scripts/xkb-gate.sh`, `scripts/xkb-gate.lisp`). Run **twice**, with
    `XKB_DEFAULT_LAYOUT=us` and `=de`, because the claim is about the environment: libxkbcommon
    reads `XKB_DEFAULT_*` when a keymap is compiled, so one image cannot see both answers. Code
    21 types `y` in `us` and `z` in `de`, and each run is told which to expect; the same code
    typing a different letter in the two runs is the evidence that a layout is the session's
    preference and not this build's. Inside each run: the serialized text parses back into a map
    that names every sampled code the same way and whose state still types `A` with Shift held
    (the only honest check that what a client receives is the keymap we think we compiled); the
    keycode range covers every code `wl_keyboard.key` can carry (9..709 on this machine, since
    modern keymaps include HID usages past evdev's 255); a binding's name finds its code, a
    shifted keysym finds the key that types it, and a name the layout does not have is an error;
    the four modifier masks equal the constants binding tables are written with; a letter repeats
    and `Control_L` does not; and the state reports what a seat reports -- Shift depressed after a
    press, `A` for code 30 with Shift held, group 0, and a Caps Lock tap locking with the next
    tap unlocking. 45 checks per layout, **90 in two**. The clause needs no device, no session and
    no privileges, and clause 12 is where a *real client* parses the keymap fd we send -- it now
    parses a rules-compiled map and reports `keycodes 9..709`. Seventeen unit tests in
    `tests/unit/input.lisp` pin the same ground with the API rather than a client: the default
    keymap compiles and serializes once, a layout the rules do not have is signalled by
    `compile-keymap` while `default-keymap` falls back and still names `Tab`, `us` and `de` differ
    on the same code, names round-trip through the library, `xkb-keycode` is evdev + 8, the masks
    are the keymap's, the state tracks what is held, and `key-name-for-code` answers from the
    unshifted level and returns `NIL` for a code the layout has nothing for.

Phase 4's fifth slice is the VT, and it adds the twenty-fifth:

25. **A card taken through a seat** (`scripts/drm-tinywl-gate.sh`,
    `scripts/drm-tinywl-gate.lisp`). The join 4d-3 makes: `libseat` opens the card,
    `cf.backend.vt` adopts the descriptor *without* opening the node, a scene with the
    cursor in it is rendered into the scanout buffer and flipped, the kernel retires
    the flip, and a disable restores the CRTC and hands the descriptor back.
    **Measured on real hardware on 2026-11-27**: 13 checks on the base run, **19** with
    `CL_DRM_SWITCH_VT=1` -- `3840x2160` on `HDMI-A-1`, `SET MASTER` refused with
    `EACCES` (and the mode programmed, flipped and restored anyway: D60), `flip
    sequence 702`, pitch `15360`, descriptors `14 -> 14` and `15 -> 15`, and the switch
    disabling the seat, giving the screen back, then enabling it again with the output
    taking the screen by itself. Two
    things make it safe on a working machine, and both are skips rather than
    failures: which card it may take is clause 22's two-setting decision (a virtual
    driver, or `CL_DRM_MODESET_CARD` **and** `CL_DRM_MODESET_ALLOW=1`), and a seat
    another compositor owns answers `ENOSYS` through libseat's no-op backend over
    logind's `EBUSY` (D56 §4). The seat is checked **first**, because it is the part
    only a VT can answer: on a machine whose session is somebody else's, the clause
    skips with the errno's meaning in a sentence instead of looking at cards that
    could never be opened. With the seat: the output comes up enabled, the seat
    reports exactly one device open (it opened it, not this process), the descriptor
    is master (`SET MASTER` is per-fd, not privileged -- the first opener of a free
    card becomes master, D55), there are two buffers, the compositor's preparer and
    presenter are the module's, one frame is drawn and presented, and the completion
    is the kernel's own `flip-complete` event for this CRTC with a sequence number.
    Closing the output restores the CRTC's framebuffer and mode, the descriptor count
    is flat, and the seat is closed afterwards. `CL_DRM_SWITCH_VT=N` also switches to
    VT N and back, which is the manual round trip of §11 performed by the probe; with
    it unset the clause says that a VT switch is a person's decision and moves on.
    Seven unit tests in `tests/unit/drm-modeset.lisp` drive the same enable/disable
    machine with a recording seat and a recording card: a seat-enabled output opens
    its card through the seat and programs the screen, a disable restores before it
    gives the descriptor back, a VT switch disables and re-enables by itself with the
    same connector and mode, a failed enable gives the descriptor back and leaves no
    hook behind, a disabled output refuses to draw, closing twice is quiet, and a
    closed output is not brought back by a later enable. `tests/unit/session.lisp` adds
    the hook list -- more than one module wants the same enable, the order is the order
    added, one failure does not stop the next, and a hook can be removed by the module
    that added it -- and `tests/unit/drm.lisp` adds three for the descriptor: adopting a
    seat's descriptor without opening a path, closing the adopted descriptor when the
    adoption fails, and refusing something that is not a descriptor. `tests/unit/tinywl.lisp`
    adds the command line: `--drm` with `--card` and `--connector` reaches `start` as
    `:mode :drm` and the two names, and a card option with no value is an error.

    Nine more tests in the same suite are the VT output's damage history (D61): five pin
    the age arithmetic (a buffer nobody has painted, one that missed one frame and owes
    that frame's change, one that missed a wholesale repaint, one whose missing frame was
    never recorded, and a history that keeps two entries and reuses its regions), and four
    draw real frames into a `pixel-screen-device` -- a recording card whose dumb buffers
    are memfds with 16 bytes of padding per row, and whose flips always retire. The
    claims a full repaint would hide are the ones asserted: the first two frames are full
    and the third is not, a sentinel painted into the buffer before the frame survives
    everywhere the frame did not damage, the box the pointer left holds no arrow, a frame
    with nothing to show does not flip but still takes a frame number, and a VT switch
    forgets every buffer.

    A clause cannot answer D61 itself: it renders one frame, and one frame is always full,
    so the per-buffer history looks exactly like a full repaint from inside this clause.
    `scripts/damage-probe.sh` (`scripts/damage-probe.lisp`) is the measurement instead --
    the same seat-taken card, eight frames with a moving pointer, and a sentinel read back
    out of the buffer the frame did not damage. It lives on §11's checklist rather than in
    the gate because it wants a console and a card it may take. **Walked 2026-11-27** on
    `card1` at `3840x2160`: 30 checks, 0 failed; two full frames, then a steady frame that
    repainted **896 of 8,294,400 pixels**, an idle frame that repainted exactly the change
    it owed (36x16, inside the 56x16 box it had been shown), an idle frame that did not
    flip but took a frame number, a sentinel that survived at (10,2150), and the CRTC's
    framebuffer, mode and descriptor count (`14 -> 14`) put back.

All twenty-five clauses pass. Two details worth knowing: the protocol clause
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

Not yet covered *by the fuzzers* -- the requests themselves are implemented and gated: the
protocol content of phases 2b and later (`wl_region`, `set_buffer_transform`,
`set_buffer_scale`, `wl_shm_pool.resize`) has no hand-written case here yet, and nothing that
needs `xdg-shell` has one either.

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
  subsurface offsets, popup positioning, cursor composite, letterboxing. Clause 19 covers the
  scale, transform and damage-only-repaint behaviours as assertions rather than hashes (a
  hash tells you it changed, an assertion tells you which quadrant moved); the single PNG it
  writes is evidence, not a comparison.
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

Preconditions the automated clauses cannot arrange for themselves:

- [ ] the person running it is in the `input` group *and the shell is newer than the
      `usermod`* (group membership is applied at login; the input clause says which it found)
- [ ] a free VT with a getty, for anything that owns the screen (4b's page flips take master;
      4c's seat reports `EBUSY` while a compositor holds the session)

- [x] TTY start, clean exit, no leaked fds (`ls /proc/<pid>/fd | wc -l`):
      `./scripts/tinywl.sh --drm` from the console, `Alt+Esc` to leave, then check that the
      console text came back (clause 25 is the automated half of this, and it is the half that
      can skip). **Walked 2026-11-27**: a real desktop on `HDMI-A-1` at 3840x2160 with real
      libinput, `Alt+Esc` back to the console, no descriptor left behind
- [ ] the same, killed with `SIGTERM` (`kill <pid>`): the screen is restored by the signal path,
      which is D59 §7's other exit
- [x] `CL_DRM_SWITCH_VT=1 ./scripts/drm-tinywl-gate.sh` from the console: the probe switches
      away, sees the seat disabled, switches back and sees the output enabled again.
      **Walked 2026-11-27**, 19 checks, 0 failed
- [x] the damage history on a card (D61):
      `CL_DRM_MODESET_CARD=/dev/dri/card1 CL_DRM_MODESET_ALLOW=1 ./scripts/damage-probe.sh`
      from the console. **Walked 2026-11-27**: 30 checks, 0 failed -- two full frames, then a
      steady frame repainting 896 of 8,294,400 pixels, an idle frame repainting exactly the
      change it owed and the next one not flipping at all, the sentinel intact at (10,2150),
      and the CRTC and the descriptor count (`14 -> 14`) given back
- [x] the VT keys with a compositor holding the keyboard: `Ctrl+Alt+F1` away from
      `cl-tinywl`, `Ctrl+Alt+F2` back to it, window still open. **Walked 2026-11-27** (it
      did not work at first -- libinput grabs the keyboard, so the compositor has to bind
      the sequence: D60)
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
