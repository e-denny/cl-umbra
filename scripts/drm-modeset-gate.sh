#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The DRM modeset gate (clause 22): master, SETCRTC, page flips, vblank events and
# the state put back (D55).
#
#   scripts/drm-modeset-gate.lisp  -> the probe: take a card, program a CRTC with
#                                     the connector's preferred mode, paint two
#                                     dumb buffers through the renderer, flip three
#                                     frames and wait for each completion, then
#                                     restore the CRTC and drop master
#
# This is the clause that changes a screen, so it only changes a virtual one
# unless a person names a real card:
#
#   default                      -> vkms only; exit 77 (SKIP) when it is not loaded
#   CL_DRM_MODESET_CARD=/dev/dri/card0 CL_DRM_MODESET_ALLOW=1
#                                -> that card, because two settings are a decision
#
# A card another master is presenting on answers EBUSY to SET MASTER, which is
# reported as SKIP: the live session's card refuses by itself.
#
# Requires libdrm.so.2 and libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log="$(mktemp "${TMPDIR:-/tmp}/cl-wayland-drm-modeset-gate.XXXXXX")"
cleanup() { rm -f "$log"; }
trap cleanup EXIT

sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/drm-modeset-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

case "$status" in
  0)  exit 0 ;;
  77) exit 77 ;;
  *)  printf 'drm-modeset-gate: the probe failed\n' >&2
      tail -n 40 "$log" >&2
      exit 1 ;;
esac
