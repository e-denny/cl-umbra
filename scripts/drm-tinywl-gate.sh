#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The VT gate (clause 25): a card taken through a seat, a frame the kernel retires,
# and the screen given back (4d-3).
#
#   scripts/drm-tinywl-gate.lisp  -> the probe: open a libseat session, take a virtual
#                                    card through it, adopt the descriptor without
#                                    opening the path, program a mode, render a scene
#                                    with the cursor in the scanout and flip it, then
#                                    restore the CRTC and hand the descriptor back
#
# A seat another compositor owns is a SKIP, not a failure -- libseat reports ENOSYS
# over logind's EBUSY (D56 §4) -- so this clause is safe to run inside a working
# session.  Taking a *real* card takes the same two settings clause 22 needs:
#
#   default                      -> vkms only; exit 77 (SKIP) when it is not loaded
#   CL_DRM_MODESET_CARD=/dev/dri/card0 CL_DRM_MODESET_ALLOW=1
#                                -> that card, because two settings are a decision
#   CL_DRM_SWITCH_VT=N           -> also switch to VT N and back (a manual round trip)
#
# The honest run is from a text console with nobody else on the seat, which is what
# docs/testing.md §11's checklist is for.  Requires libseat.so.1, libdrm.so.2 and
# libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log="$(mktemp "${TMPDIR:-/tmp}/cl-wayland-drm-tinywl-gate.XXXXXX")"
cleanup() { rm -f "$log"; }
trap cleanup EXIT

sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/drm-tinywl-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

case "$status" in
  0)  exit 0 ;;
  77) exit 77 ;;
  *)  printf 'drm-tinywl-gate: the probe failed\n' >&2
      tail -n 40 "$log" >&2
      exit 1 ;;
esac
