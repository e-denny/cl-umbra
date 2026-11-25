#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the test suite from a clean image: no user init, no Quicklisp, nothing
# but the checkout on the source registry.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec sbcl --non-interactive --no-userinit --no-sysinit \
  --eval '(require :asdf)' \
  --eval "(asdf:initialize-source-registry
            '(:source-registry (:tree \"$root/\") :ignore-inherited-configuration))" \
  --eval '(asdf:load-system "cl-wayland-tests")' \
  --eval '(uiop:quit (wayland.test:run-all))'
