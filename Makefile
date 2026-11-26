# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later

.PHONY: check test fuzz fuzz-client loads purity server c-probe frame xdg seat scene grab nested popup focus render switcher tinywl soak gate clean

check: test fuzz fuzz-client loads purity server c-probe frame xdg seat scene grab nested popup focus render switcher tinywl

test:
	./scripts/run-tests.sh

fuzz:
	./scripts/fuzz.sh 10000

# Adversarial clients against a live server; 10^4 here, 10^6 in the gate.
fuzz-client:
	./scripts/fuzz-client.sh 10000

loads:
	./scripts/check-loads.sh

purity:
	./scripts/purity-check.sh

# The cheap half of the phase-1 gate: a real wayland-info against our server.
server:
	./scripts/wayland-info-server.sh

# An independent libwayland client: bind, destroy, re-bind across versions.
c-probe:
	./scripts/c-probe.sh

# A libwayland shm client draws through the headless compositor; pixels checked.
frame:
	./scripts/headless-frame.sh

# weston-simple-shm, a real xdg-shell client, draws a window through us.
xdg:
	./scripts/xdg-shell-gate.sh

# weston-eventdemo reports the keys and pointer events we inject, through a real
# keymap; a libxkbcommon probe parses the keymap we sent.
seat:
	./scripts/seat-gate.sh

# Two real windows: placement, hit testing, click to focus, a drawn cursor.
scene:
	./scripts/scene-gate.sh

# A real client asks to be moved and resized with our serials; Alt+F1/Alt+Esc.
grab:
	./scripts/grab-gate.sh

# Our compositor inside our compositor, with a real client inside that: two
# sockets, one image, pixels and input crossing both.
nested:
	./scripts/nested-gate.sh

# Buffer scale, buffer transform, damage and opaque culling: a real client at
# scale 1 and 2, then an incremental frame that must equal a full one.
render:
	./scripts/render-gate.sh

# A real client opens menus: a positioner's answer, the flipped constrained one,
# pixels, Escape, and a click outside that dismisses without reaching the client.
popup:
	./scripts/popup-gate.sh

# Three real windows: Alt+Tab in focus order, a click, and a window closing.
focus:
	./scripts/focus-gate.sh

# Three real windows and the visible Alt+Tab overlay: pixels, damage, Escape, a click,
# and the frame after the commit compared with a full repaint.
switcher:
	./scripts/switcher-gate.sh

# Run tinywl itself (a manual test; --nested puts it in the current session).
tinywl-run:
	./scripts/tinywl.sh --nested --size 1024x640

# tinywl itself: the parity script, run headless and nested, with two real clients.
tinywl:
	./scripts/tinywl-parity.sh

# The expensive half: 10k connect/disconnect cycles.  SOAK_CYCLES overrides.
soak:
	./scripts/soak.sh

gate:
	./scripts/gate.sh

clean:
	rm -rf ~/.cache/common-lisp/sbcl-*/
