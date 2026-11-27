#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The damage history measured on a card (D61).  Clause 25 renders one frame, and one
# frame is always full, so it cannot answer this: scripts/damage-probe.lisp flips a
# short sequence, prints each frame's damage box, and reads a sentinel back out of the
# buffer the frame did not damage.
#
#   default                      -> vkms only; exit 77 (SKIP) when it is not loaded
#   CL_DRM_MODESET_CARD=/dev/dri/cardN CL_DRM_MODESET_ALLOW=1
#                                -> that card, because two settings are a decision
#
# The honest run is from a text console whose login owns the seat (docs/testing.md
# §11's checklist), not from inside a compositor that owns the machine.  Requires
# libseat.so.1, libdrm.so.2 and libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log="$(mktemp "${TMPDIR:-/tmp}/cl-wayland-damage-probe.XXXXXX")"
cleanup() { rm -f "$log"; }
trap cleanup EXIT

sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/damage-probe.lisp" > "$log" 2>&1
status=$?

cat "$log"

case "$status" in
  0)  exit 0 ;;
  77) exit 77 ;;
  *)  printf 'damage-probe: the probe failed\n' >&2
      tail -n 40 "$log" >&2
      exit 1 ;;
esac
