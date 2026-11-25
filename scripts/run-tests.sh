#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the test suite (Rove) from a clean image.  Exit status is the verdict, so
# `make check` and CI see a failing assertion as a failing command.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Colour is for humans at a terminal; logs and CI get plain text.
color_eval=""
if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then
  color_eval='(setf rove:*enable-colors* nil)'
fi

exec sbcl --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --eval '(asdf:load-system "cl-wayland-tests")' \
  ${color_eval:+--eval "$color_eval"} \
  --eval '(wayland.test.runner:main)'
