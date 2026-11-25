# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later

.PHONY: check test fuzz loads purity server soak gate clean

check: test fuzz loads purity server

test:
	./scripts/run-tests.sh

fuzz:
	./scripts/fuzz.sh 10000

loads:
	./scripts/check-loads.sh

purity:
	./scripts/purity-check.sh

# The cheap half of the phase-1 gate: a real wayland-info against our server.
server:
	./scripts/wayland-info-server.sh

# The expensive half: 10k connect/disconnect cycles.  SOAK_CYCLES overrides.
soak:
	./scripts/soak.sh

gate:
	./scripts/gate.sh

clean:
	rm -rf ~/.cache/common-lisp/sbcl-*/
