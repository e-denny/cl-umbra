#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the test suite from a clean image.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

exec sbcl --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --eval '(asdf:load-system "cl-wayland-tests")' \
  --eval '(uiop:quit (wayland.test:run-all))'
