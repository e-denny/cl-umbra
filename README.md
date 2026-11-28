# cl-umbra

A Wayland stack written in Common Lisp, from the socket up.

The repository is named for where the stack is going: `cl-umbra`, a daily-driver compositor.
Everything that makes it possible is here too — the protocol implementation, the server, the
compositor framework, and a tinywl port — as the six systems below.

**Status: phase 0, phase 1, phase 2a, phase 2b, phase 3a, phase 3b, phase 3c, phase 3d,
phase 3e, phase 3f, phase 3g, phase 3i and phase 3's exit gate — `cl-tinywl` — passing, plus
the first three slices of phase 4 (the DRM card, its connectors and a dumb buffer, D54; the
screen: master, a mode, page flips and the restore, D55; and the seat plus libinput's devices
and decode path, D56), the keymap of the fourth (libxkbcommon, D57), its frame: the scene --
cursor included -- rendered into the scanout at the driver's pitch (D58), and the VT: the card
opened through a seat, a frame flipped on it, and the screen given back and retaken across a VT
switch (4d-3, walked on the hardware on 2026-11-27: D60).**
`./scripts/gate.sh` checks twenty-five clauses. Phase 0: the unit suite (492 tests, nineteen suites), every vendored protocol compiling,
`demo-globals` against a live compositor, 10⁶ decoder fuzz cases. Phase 1: `wayland-info` —
the system's own libwayland client — exits 0 against *our* server; 10k connect/disconnect
cycles leave the descriptor count and resident set flat; 10⁶ adversarial client connections
neither crash, wedge, leak nor get a malformed reply; and an independent libwayland C client
binds, destroys and re-binds across versions. Phase 2a: a libwayland shared-memory client
draws a known pattern through our headless compositor, gets its frame callback, and the
captured frame matches pixel for pixel (with a PNG screenshot to prove it). Phase 2b: the
same kind of real client draws at buffer scale 1 and 2 on scale-1 and scale-2 outputs and with
90- and 180-degree transforms, and every quadrant lands where the scale and the transform say;
a scene of opaque and translucent rectangles is then moved a few pixels at a time and the
incrementally repainted frame must equal a full repaint of the same scene pixel for pixel, with
the damage smaller than the output (damage tracking, buffer age, opaque culling, buffer scale
and transform: D48, D49, D50). Phase 3:
`weston-simple-shm` — a real xdg-shell client — binds `xdg_wm_base`, is configured, acks our
serial, commits a buffer and draws a window through us; the gate checks the frame's pixels,
answers our ping, and confirms the client never sees a protocol error. Phase 3b:
`weston-eventdemo` is focused, sent a keymap and typed at — the gate requires the *client's own
output* to show our injected motion, button, scroll and keys, including keycode 16 translated
to "Q" with the shift mask, and a libxkbcommon probe parses the keymap we actually sent.
Phase 3c: two real windows are placed at (0,0) and (32,32); hovering one moves the pointer
without moving the keys, clicking moves the keyboard and the `activated` configure, both
windows are drawn where they were placed, and the cursor's own pixels are composited last at
the pointer's position. Phase 3d: a real client asks to be moved with the serial from a button
event we sent, is dragged and stops on the release; a right-drag becomes a `configure` of the
size the drag implies; Alt+F1 cycles the bottom window to the top and Alt+Esc stops the loop.
Phase 3e: our compositor runs *inside* our compositor — one image, two sockets — with a real
`weston-eventdemo` inside the nested session; the parent sees a titled, activated window, its
frame is the nested compositor's own frame pixel for pixel, and a pointer motion and a key
injected into the parent come out of the client at the same coordinates with the same modifier
mask. Phase 3's exit gate is the tinywl parity script, run **twice**: `cl-tinywl` is driven by
hand with two real clients — click to focus, typing to the focused window only, Alt+left to
drag, Alt+right to resize from the edge under the pointer, Alt+F1 to cycle, Alt+Esc to close the
clients and quit — once with its output in memory and once nested inside another compositor,
with the client's own `WAYLAND_DEBUG` stream checked for an ordered, acked configure. Phase 3f
puts menus through it (positioners, flipping a menu back inside the output, Escape and a
click-away that is swallowed). Phase 3g keeps a focus stack, so a closing window hands the keys
to the window that was focused before it. Phase 3i draws that stack: `Alt+Tab` opens an overlay
of window titles in a built-in 5x7 font, Tab walks it, releasing Alt focuses and raises the row
that was showing, Escape and a click cancel it, and the frame it leaves is byte-identical to a
full repaint (D51). A row carries a picture of its window, taken once when the overlay opens
(D52), and a resize keeps the dragged edge under the pointer instead of a round trip behind it
(D53). Phase 4's first half is the DRM card: resources, connectors, encoders, CRTCs, mode
choice and scanout-sized dumb buffers, checked against `/sys` and painted through the pixman
target without DRM master, so the hardware path can be gated on a machine whose session owns
the display (D54). Purity (no
libwayland, no wlroots) runs over all of it. The gate exits 0.

Three roadmap quality items are still open and are not gate clauses: fixed-size in/out
rings, `WAYLAND_DEBUG`-compatible tracing, and surplus-descriptor detection (which needs a
protocol layer that knows a message's descriptor count).

What exists:

- `cl-wayland-core` — `wayland.wire` (framing and argument codec), `wayland.ffi` (sockets,
  `sendmsg`/`recvmsg` with `SCM_RIGHTS`, lock files, `SO_PEERCRED`), `wayland.object` (one
  object table and both id namespaces, shared by both ends), `wayland.io` (flush and pump,
  descriptors, partial messages), `wayland.reactor` (epoll, timers, idles, posted commands,
  signals), `wayland.protocol` (the 69-file XML corpus, checked against `wayland-scanner`)
  and `wayland.codegen` (schema to Lisp, generated at build time).
- `cl-wayland-client` — connect, proxies and ids, `get_registry`, `bind`, `sync` roundtrip,
  hooks or methods on the generated event functions, and since phase 3e the requests a
  compositor needs when *it* is a client: surfaces and regions, shm pools and buffers with real
  descriptor sending, seat devices, and the xdg-shell toplevel handshake (`ping` answered by
  the library). `demo-globals` prints the live session's globals in `wayland-info`'s format,
  byte-identical.
- `cl-wayland-server` — the socket with its lock file and permissions, accept with peer
  credentials, `wl_display` and both id ranges, globals and version-negotiated `bind`,
  `wl_display.sync`, the error policy, flush batching with backpressure, and idempotent
  teardown. Phase 2a added `wl_shm` (pools, buffers, two formats, the validation a malicious
  client would otherwise turn into a read of our memory) and the `wl_compositor`/`wl_surface`
  state machine (attach, damage, frame, commit, destroy). Phase 3 added `xdg-shell` v1 —
  `xdg_wm_base` with ping/pong, the `xdg_surface` configure/ack handshake with real serial
  bookkeeping, and `xdg_toplevel` with title, app id, size hints and a configure carrying a
  complete state array. Popups, positioners and decoration negotiation are deliberately absent
  and answer `implementation`. Phase 3b added `wl_seat` (v4) with `wl_pointer`, `wl_keyboard`
  and a generated XKB keymap, explicit focus that activates the focused toplevel, `wl_region`,
  `wl_compositor` v3, and `wl_shm_pool.resize`. Phase 3c added the scene: nodes with positions
  and stacking, hit testing that honours input regions, a cascade placement policy behind
  `cf:on-new-toplevel`, and a built-in cursor composited last. The demo server offers two dummy
  globals so `wayland-info` has something true to print.
- `cl-compositor-framework` — a pixman renderer (the reference), a headless compositor that
  draws committed surfaces into an in-memory target and offers `wl_compositor`, `wl_shm`,
  `wl_output`, `xdg_wm_base` and `wl_seat`, `read-pixels`, a PNG writer, `cf.input`
  (generated keymaps, keycodes, modifier state), `cf.scene` (buffer/rect/image nodes, hit
  testing, a software cursor), `cf.grab`, `cf.keybindings`, and `cf.backend.nested` (our
  compositor as a client of another one: its frame goes into the parent's shm buffer, its input
  comes from the parent's seat), and `cf.backend.drm` (the card: connectors, encoders, CRTCs,
  mode choice and dumb buffers, everything KMS allows without owning the screen, plus a
  `drm-scanout` that takes master, programs a CRTC, flips two buffers and restores what it
  found -- D55), `cf.session` (libseat as an availability machine: enable/disable callbacks,
  device open and close, the disable acknowledged, a VT switch asked for -- D56) and
  `cf.backend.libinput` (udev or path contexts, one flat event stream decoded into the seat:
  evdev codes named through `cf.input`, pointer deltas accumulated and clamped into the
  output, buttons and scroll, devices tracked by sysname -- D56). `cf.input` is libxkbcommon
  since 4d: the keymap is compiled from the session's rules and serialized for clients, names,
  codes and modifier masks are the keymap's answers, and the state behind `wl_keyboard.modifiers`
  is an `xkb_state` (D57). `xdg_popup` and
  `xdg_positioner` are implemented (menus,
  tooltips, their grabs and their dismissal), a focus stack decides who gets the keys when a
  window closes, `cf.switcher` draws that stack as an `Alt+Tab` overlay (`cf.font` is a 5x7
  bitmap font with a validated table of printable ASCII), and the renderer tracks damage, applies
  buffer scale and the eight buffer
  transforms, and culls what an opaque window hides. What is left of phase 4 is tinywl on
  DRM and a cursor in the scanout buffer (4d); GPU rendering is phase 5.

## What this is

Six systems, built in order, each useful on its own:

| System | Role | Analogue it replaces | Phase |
|---|---|---|---|
| `cl-wayland-core` | Wire format, fd passing, protocol schema + code generation, object model, event loop | libwayland's guts, wayflan's wire/scanner | 0 |
| `cl-wayland-client` | Client-side display and proxies | libwayland-client | 0, 3 |
| `cl-wayland-server` | Display, globals, resources, clients, serials, error policy | libwayland-server | 1 |
| `cl-compositor-framework` | Backends, renderers, scene graph, seat/input, output, shell protocol state machines | **wlroots** | 2-5 |
| `cl-tinywl` | The tutorial compositor: one file of policy over the framework, and a launcher | tinywl | 3 |
| `cl-umbra` | A compositor for daily use | Umbriel / niri / sway | 6-7 |

Two build-time systems sit beside those six: `cl-wayland-asdf` (the
`:wayland-protocol` component type) and `cl-wayland-protocols` (its generated output).

Dependency direction is strictly one-way:

```
cl-wayland-core
   ├── cl-wayland-client
   └── cl-wayland-server
          └── cl-compositor-framework   (also depends on cl-wayland-client: nested)
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
./scripts/gate.sh                       # every gate clause, phases 0-3
TEST_VERBOSE=1 ./scripts/run-tests.sh   # list every assertion instead of dots
```

Each probe also runs alone: `scripts/run-tests.sh`, `scripts/check-loads.sh`,
`scripts/purity-check.sh`, `scripts/wayland-info-server.sh` (a real client against our
server), `scripts/c-probe.sh` (an independent libwayland C client), `scripts/fuzz-client.sh`
(adversarial clients) and `scripts/soak.sh` (10k connections; `SOAK_CYCLES` overrides). The runtime dependency list is SBCL plus CFFI — CFFI is for libc
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

## Hello, keys

The phase-3b gate, in one command: `weston-eventdemo` is focused and typed at through a real
keymap, and its printed events — coordinates, button codes, unicode code points, modifier
masks — are the assertions.

```
./scripts/seat-gate.sh
```

## Hello, windows

The phase-3 gate, in one command: `weston-simple-shm` — a real xdg-shell client with its own
libwayland — opens a window through our compositor, is configured and acknowledged, and draws.
The gate checks pixels, ping/pong and the object lifetimes.

```
./scripts/xdg-shell-gate.sh
```

## Hello, drag

The phase-3d gate, in one command: a client compiled at gate time (with xdg-shell generated by
`wayland-scanner`) asks to be moved with a serial from a real button event, is dragged by
injected motion, stops when the button comes up, and is configured to a new size when it asks
to be resized. Alt+F1 and Alt+Esc are asserted in the same run.

```
./scripts/grab-gate.sh
```

## Hello, tinywl

The phase-3 exit gate, in one command: `cl-tinywl` itself, run twice. A real `weston-eventdemo`
and a compiled xdg-shell client are placed, focused, typed at, dragged, resized, cycled and
closed; then the same scenario runs with tinywl nested inside another compositor and the input
injected into the *parent*.

```
./scripts/tinywl-parity.sh     # both runs;  ./scripts/gate.sh runs it as clause 16
./scripts/render-gate.sh       # scale, transform, damage;  clause 19
```

Run it as a compositor, with a client of your own — as a window inside the session you
are already in:

```
./scripts/tinywl.sh --nested --launch weston-terminal
```

Menus: no client installed here opens a popup (weston-terminal has no menus, kitty needs
EGL), so `./scripts/popup-demo.sh --size 1024x640` runs the same session with
`tests/c-client/wayland-popup-client.c` compiled and launched -- left-click anywhere in the
window and the menu appears at the pointer; Escape or a click outside dismisses it.

`--launch CMD` starts a client *inside* the session immediately, and again on
**Alt+Shift+Return** — it sets the child's `WAYLAND_DISPLAY` to tinywl's own socket, which
is the one thing a client started from a shell cannot do for itself in a nested session.
`--size WxH` defaults to 1280x800 and the nested output also follows the parent's
`xdg_toplevel.configure`, so a tiling parent decides (D37). `--scale N` renders at *N*
device pixels per layout pixel: `--scale 2` is what a HiDPI output wants, and a nested session
tells its parent the same scale so the window stays the layout size it asked for while the
pixels are twice as dense (D49) — text is drawn at the output's density instead of being
upscaled by the parent. `--help` lists the rest,
`--headless` renders into memory instead (needs `--display`, because `wayland-0` is the
session's own socket), and `--parent PATH` points at a compositor that is not
`WAYLAND_DISPLAY`. `scripts/tinywl.sh` is only a launcher: it loads ASDF, Quicklisp and
`cl-tinywl` and calls `(tinywl:main)`, because a bare `sbcl` has none of them. The policy
itself is `cl-tinywl/src/tinywl.lisp`: a class, two methods and six functions, no framework
changes.

| Chord | Does |
|---|---|
| `Alt+Shift+Return` | start a terminal (`tinywl:*terminal-command*`) |
| `Alt+left` drag | move the window under the pointer |
| `Alt+right` drag | resize it from the edge under the pointer |
| `Alt+Tab` | open the switcher: the focus stack, one row per window, one selected |
| `Alt+Shift+Tab` | the same, opened on the window that has the keys now |
| `Alt+F1` | send the bottom window (in draw order) to the front and focus it |
| `Alt+Esc` | ask every client to close, then quit |

`Alt+Tab` is a *hold-and-release* switcher: Tab walks the list (Shift walks back), releasing
Alt takes the row the bar is on and raises it, and Escape or a click cancels it. One tap and
release still lands on the window it always did — the overlay changes what you see, not what
the key means.

From a REPL, the same session is three forms:

```lisp
(defvar *s* (tinywl:start :mode :nested :width 1024 :height 640))
(tinywl:run *s*)
(tinywl:stop *s*)
```

## Hello, nested

The phase-3e gate, in one command: our compositor inside our compositor inside one image, with
a real `weston-eventdemo` inside *that*. The parent's frame is compared with the nested
compositor's own target, and motion and keys injected into the parent are asserted from the
client's output. No display, no hardware, no session.

```
./scripts/nested-gate.sh
```

## Hello, pointer

The phase-3c gate, in one command: two `weston-simple-shm` windows are placed, the pointer is
moved over one and clicked, the keyboard and the `activated` configure follow the click, and the
frame contains the cursor's own pixels at the pointer's position.

```
./scripts/scene-gate.sh
```

## Hello, pixels

The phase-2a gate, in one command: a libwayland shared-memory client draws a known pattern
through our headless compositor, and the frame is checked pixel by pixel and written out as a
PNG.

```
./scripts/headless-frame.sh
```

From the REPL, the same compositor is a few lines:

```lisp
(defvar *c* (cf:make-headless-compositor :width 512 :height 512))
(wayland.server:run (cf:compositor-display *c*))     ; serve clients
(cf:frame-pixel *c* 10 20)                           ; one pixel, 0xAARRGGBB
(cf:write-frame-png *c* "/tmp/frame.png")
```

It offers `wl_compositor`, `wl_shm`, `wl_output` and `xdg_wm_base`, so a real client can open
a window on it. From the REPL, the demo server without the compositor:

```lisp
(defvar *display* (wayland.server:make-demo-display :display-name "wayland-0"))
(wayland.server:run *display*)          ; Ctrl-C or (wayland.reactor:request-stop ...)
(wayland.server:close-display *display*)
```

## License

GPL-3.0-or-later. See [`DECISIONS.md`](DECISIONS.md) D13 for what that does and does not
cover: the framework and compositors are copyleft, Wayland clients that connect to them are
not derived works, and vendored protocol XML retains its MIT/HPND license.
