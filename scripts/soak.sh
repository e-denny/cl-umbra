#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The phase-1 soak clause: SOAK_CYCLES (default 10000) connect/disconnect cycles
# against the demo server, with flat descriptor count and a flat resident set.
# scripts/soak.lisp holds the cycles and the measurements.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The soak file needs the reactor, the server and the demo, and nothing else.
exec sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --eval "(asdf:initialize-source-registry '(:source-registry (:tree \"$repo_root/\") :ignore-inherited-configuration))" \
  --eval '(asdf:load-system "cl-wayland-server")' \
  --load "$repo_root/scripts/soak.lisp"
