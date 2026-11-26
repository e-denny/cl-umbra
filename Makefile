# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later

.PHONY: check test fuzz fuzz-client loads purity server c-probe frame xdg seat scene soak gate clean

check: test fuzz fuzz-client loads purity server c-probe frame xdg seat scene

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

# The expensive half: 10k connect/disconnect cycles.  SOAK_CYCLES overrides.
soak:
	./scripts/soak.sh

gate:
	./scripts/gate.sh

clean:
	rm -rf ~/.cache/common-lisp/sbcl-*/
