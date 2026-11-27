#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The keymap gate (clause 24): the layout comes from the session, the keymap a
# client receives parses back to itself, and the modifier state is xkbcommon's
# (D57).
#
#   scripts/xkb-gate.lisp   -> the keymap itself: compile, serialize, parse back,
#                              names, masks, repeat, and the state a seat reports
#
# Run twice, because the claim is about the *environment*: a keyboard layout is the
# session's preference, and the library reads XKB_DEFAULT_LAYOUT when the keymap is
# compiled -- so one image cannot see both answers.  Code 21 is `y' in us and `z'
# in de, and each run is told which to expect.
#
# Requires libxkbcommon.so.0 and the system's XKB data (/usr/share/X11/xkb).
# No device, no session and no privileges.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log="$(mktemp "${TMPDIR:-/tmp}/cl-wayland-xkb-gate.XXXXXX")"
cleanup() { rm -f "$log"; }
trap cleanup EXIT

status=0
for pair in "us:y" "de:z"; do
  layout="${pair%%:*}"
  expected="${pair##*:}"
  printf 'xkb-gate: XKB_DEFAULT_LAYOUT=%s\n' "$layout" >> "$log"
  XKB_DEFAULT_LAYOUT="$layout" CL_XKB_EXPECT="$expected" \
    sbcl --noinform --non-interactive --no-userinit --no-sysinit \
      "${sbcl_evals[@]}" \
      --load "$repo_root/scripts/xkb-gate.lisp" >> "$log" 2>&1 || status=1
done

cat "$log"

if [ "$status" -ne 0 ] || grep -q '^  FAIL' "$log"; then
  printf 'xkb-gate: the keymap probe failed\n' >&2
  exit 1
fi
printf 'xkb-gate: %d checks in two layouts (us, de)\n' "$(grep -c '^  ok' "$log")"
exit 0
