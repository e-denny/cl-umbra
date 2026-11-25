#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The peer fuzzer: random and adversarial clients against one live display.
#
#   ./scripts/fuzz-client.sh [ITERATIONS] [SEED]
#
# Every case opens a real connection, writes something between garbage and a
# plausible-but-illegal protocol message, reads the reply, and closes.  The
# invariants are in tests/fuzz/client-fuzz.lisp: well-formed replies, no wedge,
# no internal error from our own code, no descriptor leak, no runaway memory, and
# the server still serving well-behaved clients at the end.
#
# A failure prints the seed and the bytes; the seed reproduces it exactly.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

iterations="${1:-1000000}"
seed="${2:-1}"

exec sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --eval '(asdf:load-system "cl-wayland-tests/fuzz-client")' \
  --eval "(uiop:quit (if (wayland.fuzz.client:run :iterations $iterations :seed $seed) 0 1))"
