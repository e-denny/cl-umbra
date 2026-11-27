#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The DRM gate (clause 21): a real card, its connectors, a mode, and a
# scanout-sized dumb buffer -- with no setcrtc and no DRM master (D54).
#
#   scripts/drm-gate.lisp   -> the probe: libdrm's view against sysfs's, then one
#                              dumb buffer per connected connector, painted with
#                              pixman and read back
#
# No screenshots, no clients, no mode set: this clause is about the card being
# readable and its memory being ours, which is the half of KMS that can be
# checked while somebody is using the machine.  It is also the half that can be
# skipped honestly: exit status 77 means "no card, or no permission", which the
# gate reports as SKIP and not as a failure.
#
# Requires libdrm.so.2 and libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log="$(mktemp "${TMPDIR:-/tmp}/cl-wayland-drm-gate.XXXXXX")"
cleanup() { rm -f "$log"; }
trap cleanup EXIT

sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/drm-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

case "$status" in
  0)  exit 0 ;;
  77) exit 77 ;;
  *)  printf 'drm-gate: the probe failed\n' >&2
      tail -n 40 "$log" >&2
      exit 1 ;;
esac
