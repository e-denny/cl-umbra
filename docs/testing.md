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

The scripts go through `wayland.test.runner`, which names the six suites instead of letting
Rove find them from the system. Rove's lookup maps each fasl back to its source, which only
holds when the fasl is in ASDF's user cache; a build with a different output translation (a
cold-cache check, a packager) would otherwise run zero suites and report success. The runner
also fails when a named suite is missing or empty, so "green" always means 112 tests ran.

One workaround is load-bearing: `tests/cl-wayland-tests.asd` unlocks SBCL's `SB-DI` package
before Rove loads, because dissect 20231021 (Rove's failure renderer) interns symbols from it
and SBCL 2.6 locks it. The unlock lives in the test system only, so no shipped system is
affected; remove it when dissect fixes its SBCL backend.

### The phase-0 gate

`scripts/gate.sh` encodes `PLAN.md` §5's exit gate as five clauses it checks rather than
assumes: the unit suite, "every vendored protocol compiles", `demo-globals` against
`wayland-info`, the fuzz harness, and purity (D1). Each prints `PASS`, `FAIL`, `SKIP` (no
session to talk to) or `NOT BUILT`; the exit status is 0 when all pass, 1 when one fails and
2 when a clause has nothing behind it, so a clause that is merely planned can never look
like a green gate. All five pass as of the fuzz harness landing. Failure logs land in a
temporary directory whose path is printed.

Two details worth knowing: the protocol clause compiles all 69 files into throwaway packages
without loading them (duplicate interface versions across the corpus make loading unsafe,
compiling is local), and the demo clause is skipped rather than failed when there is no
`WAYLAND_DISPLAY` socket, so the gate runs headless.

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

`tests/fuzz/fuzz.lisp` (system `cl-wayland-tests/fuzz`, driver `scripts/fuzz.sh
[ITERATIONS] [SEED]`) runs three kinds of case, chosen at random:

| Case | What it feeds | What must hold |
|---|---|---|
| header | random octets, half the time with a plausible header | `decode-header` returns NIL or a header with `size ≥ 8`, `size % 4 = 0`, `size ≤ 65532`, object id ≠ 0; no crash |
| schema | random octets decoded as the arguments of a random message from the loaded protocols | values or a `wayland.wire` condition; never overrun the buffer or loop |
| transport | random writes to one end of a real `socketpair`, `pump` on the other: garbage, truncated messages, whole messages, some with descriptors attached | only whole messages dispatch; the partial tail stays under 2× the maximum message size; the input buffer never exceeds 4× its 64 KiB start; every descriptor the stream delivered is closed |

Hard rules: a case that signals anything other than a `wayland.wire` condition is a
failure; a run that misses its deadline (60 s, or 1 s per 10 000 iterations) is a hang; the
open descriptor count (`/proc/self/fd`) must return to what it was once the harness closes
its own socket pair, pool and buffers. The random source is a seeded xorshift64* in the
harness, not `cl:random`, so a failure prints a seed that reproduces it on any SBCL:

```
./scripts/fuzz.sh 1000000 12345
```

Budget: 10⁶ cases in the phase-0 gate (`scripts/gate.sh`), 10⁴ in `make check`, both well
under three seconds today. Finding so far, on its first run: `wayland.io` queued descriptors
that a rejected stream would discard without closing, so `reset-input-buffer` now closes them
by default.

Not yet: mutating structured messages of a *client* against a *server* (`wl_shm` pool
validation, `(offset, stride, format)` against pool sizes). That arrives with the server in
phase 1, where there is a peer to reject them.

## 5. Interop matrix

| Our role | Peer | What must hold |
|---|---|---|
| server | `wayland-info` | every advertised global, version and event is valid |
| server | `weston-simple-shm` | buffer attach/commit/release, damage, frame callbacks |
| server | `kitty` | keyboard, clipboard-adjacent paths, resize, popups |
| server | GTK4 app | subsurfaces, buffer scale, fractional scale, decoration negotiation |
| server | Qt app | buffer formats, `xdg_popup`, activation |
| server | a dmabuf client | import, modifier negotiation, fallback to shm |
| client | `sway`, `weston` | registry, bind, roundtrip, fd passing, seat events |
| both | ourselves (nested) | each side exercises the other; the nested compositor is a test |

The matrix is a script, not a checklist: `scripts/interop.sh <server> <client>` starts the
pair on a private socket, runs a scenario, and diffs the observed client log against
expectations.

What runs today without a session: `tests/unit/client.lisp` puts a socket pair in place of a
compositor and asserts the bytes the client writes (`get_registry`, `bind`'s four wire
arguments) and what it makes of the bytes a compositor would write (globals, `delete_id`,
`wl_display.error`, a message split across two writes, an event carrying a server-allocated
`new_id`). `demo-globals` against the live session is the one check that needs a real peer;
it is compared with `wayland-info` by diff, not by eye.

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
