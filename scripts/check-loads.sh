#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Load every system from a clean image and check the loaded image for
# forbidden shared objects.  This is the cheap half of the purity gate.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

exec sbcl --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --eval '(dolist (name (list "cl-wayland-core" "cl-wayland-client" "cl-wayland-server"
                              "cl-compositor-framework" "cl-tinywl" "cl-umbra"))
            (asdf:load-system name)
            (format t "loaded ~A~%" name))' \
  --eval '(let ((maps (uiop:read-file-string "/proc/self/maps")))
            (dolist (forbidden (list "libwayland" "libwlroots"))
              (when (search forbidden maps)
                (format *error-output* "~&IMPURE: ~A is mapped into the image~%" forbidden)
                (uiop:quit 1))))' \
  --eval '(format t "purity: no libwayland or libwlroots in the image~%")'
