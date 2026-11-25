# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later

.PHONY: check test fuzz loads purity gate clean

check: test fuzz loads purity

test:
	./scripts/run-tests.sh

fuzz:
	./scripts/fuzz.sh 10000

loads:
	./scripts/check-loads.sh

purity:
	./scripts/purity-check.sh

gate:
	./scripts/gate.sh

clean:
	rm -rf ~/.cache/common-lisp/sbcl-*/
