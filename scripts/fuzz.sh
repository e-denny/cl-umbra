#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Feed the decoder random octets: budget for a commit, and the gate's 10^6.
#
#   scripts/fuzz.sh [ITERATIONS] [SEED]
#
# Exit status is the verdict.  A failure prints the seed, which reproduces it
# exactly: scripts/fuzz.sh ITERATIONS SEED.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

iterations="${1:-10000}"
seed="${2:-1}"

exec sbcl --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --eval '(asdf:load-system "cl-wayland-tests/fuzz")' \
  --eval "(uiop:quit (if (wayland.fuzz:run :iterations $iterations :seed $seed) 0 1))"
