# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later

.PHONY: check test loads purity clean

check: test loads purity

test:
	./scripts/run-tests.sh

loads:
	./scripts/check-loads.sh

purity:
	./scripts/purity-check.sh

clean:
	rm -rf ~/.cache/common-lisp/sbcl-*/
