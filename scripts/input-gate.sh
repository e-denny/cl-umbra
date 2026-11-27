#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The input gate (clause 23): the seat, the devices and the decode chain (D56).
#
#   the seat      logind's seat for this session, opened through libseat.  On a
#                 machine somebody is using, one client already holds control and
#                 the open is refused -- a SKIP with the errno, not a failure
#   the devices   every /dev/input/event* opened by libinput, named, configured and
#                 closed again with no descriptor leaked.  Needs the `input' group
#                 in the effective set; SKIP without it
#   the chain     a raw evdev event through the decoder into a real compositor:
#                 code 60 fires the F2 binding, a 5000-pixel motion clamps to the
#                 last pixel, an unnamed key is reported.  Always runs
#
# Nothing here grabs a device and nothing presses a key on the live session: the
# session keeps its keyboard for the whole clause.  Exit status: 0 pass, 1 fail,
# 77 nothing at all could be checked.
#
# Requires libinput.so.10; libudev is needed only for a udev context, which this
# clause does not use -- it adds devices by path, which is also what a machine
# without udev would do.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The `input' group may be granted in /etc/group while this shell still carries the
# group set from before the change -- the state a person is in between the usermod
# and the next login.  newgrp gives the probe a fresh set without asking anybody to
# log out; the flag stops it from happening twice.
if [ "${1:-}" != "--in-group" ] && command -v newgrp >/dev/null 2>&1; then
  input_gid="$(getent group input 2>/dev/null | cut -d: -f3 || true)"
  if [ -n "${input_gid:-}" ] && ! grep -q "^Groups:.*[[:space:]]${input_gid}\([[:space:]]\|$\)" /proc/self/status; then
    printf 'exec "%s" --in-group\nexit\n' "$0" | newgrp input
    exit $?
  fi
fi

# The chain's compositor needs a display socket of its own; the live session's
# wayland-0 is somebody else's.
runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-input.XXXXXX")"
log="$(mktemp "${TMPDIR:-/tmp}/cl-wayland-input-gate.XXXXXX")"
cleanup() { rm -rf "$runtime_dir"; rm -f "$log"; }
trap cleanup EXIT

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/input-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

case "$status" in
  0)  exit 0 ;;
  77) exit 77 ;;
  *)  printf 'input-gate: the probe failed\n' >&2
      tail -n 40 "$log" >&2
      exit 1 ;;
esac
