#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The page-flip demo (D55): two dumb buffers, three hundred frames, every flip
# retired by a real vblank, and the CRTC put back the way it was found.
#
#   scripts/drm-demo.sh                       vkms, 300 frames, 5 seconds
#   scripts/drm-demo.sh --frames 600          twice as long
#   scripts/drm-demo.sh --mode 1024x768       ask for a size the connector offers
#   scripts/drm-demo.sh --connector Virtual-1
#   scripts/drm-demo.sh --card /dev/dri/card0 # a real card: set
#                                             # CL_DRM_MODESET_ALLOW=1 too
#
# By default it will only take a virtual card (vkms), because taking a real one
# takes the screen somebody is looking at.  Run it inside a text console, or with
# vkms loaded (`sudo modprobe vkms'), and nothing visible is disturbed.
#
# Exit status: 0 frames flipped and the card given back, 1 something failed,
# 2 no card this program is willing to take.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  sed -n '4,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --frames)    export CL_DRM_DEMO_FRAMES="${2:?--frames needs a number}"; shift 2 ;;
    --card)      export CL_DRM_DEMO_CARD="${2:?--card needs a path}"; shift 2 ;;
    --connector) export CL_DRM_DEMO_CONNECTOR="${2:?--connector needs a name}"; shift 2 ;;
    --mode)      export CL_DRM_DEMO_MODE="${2:?--mode needs WxH}"; shift 2 ;;
    --help|-h)   usage; exit 0 ;;
    *)           printf 'drm-demo: unknown option %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

exec sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/drm-demo.lisp"
