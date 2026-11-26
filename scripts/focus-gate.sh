#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The focus stack gate (clause 18): three real clients, Alt+Tab, and a window
# closing.
#
#   /usr/bin/weston-simple-shm   -> three independent clients
#   scripts/focus-gate.lisp      -> compositor, injected keys, the stack
#
# The clients are system binaries with their own libwayland: they are the peers, not
# the product.  Each is a separate process on its own connection, so "which window
# has the keyboard" is not one client's internal state.
#
# Requires weston-simple-shm and libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-focus.XXXXXX")"
chmod 700 "$runtime_dir"
log="$runtime_dir/gate.log"

cleanup() { rm -rf "$runtime_dir"; }
trap cleanup EXIT

fail() {
  printf 'focus-gate: %s\n' "$*" >&2
  for file in "$log" "$runtime_dir"/[ABC].log; do
    [ -f "$file" ] && { printf '  --- %s ---\n' "$(basename "$file")" >&2
                        tail -n 20 "$file" | sed 's/^/  /' >&2; }
  done
  exit 1
}

client="$(command -v weston-simple-shm 2>/dev/null)"
[ -n "$client" ] || fail "weston-simple-shm is not installed; it is the client this gate needs"
pkg-config --exists pixman-1 2>/dev/null || fail "no libpixman development files"

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
  WESTON_CLIENT="$client" FOCUS_LOG_DIR="$runtime_dir" CL_WAYLAND_ROOT="$repo_root" \
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/focus-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

[ "$status" -eq 0 ] || fail "a window was not focused, cycled or handed on"
[ -s "$log" ] || fail "the gate wrote no log"

printf 'focus-gate: %s checks passed\n' "$(grep -ac '^  ok   ' "$log")"
