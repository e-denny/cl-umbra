#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The switcher gate (clause 20): three real clients, Alt+Tab held down, and the
# overlay read back pixel by pixel.
#
#   /usr/bin/weston-eventdemo  -> three independent clients, titled ALPHA, BETA and
#                                 GAMMA, so a row can be identified by its title
#   scripts/switcher-gate.lisp -> the tinywl compositor, injected keys, the overlay
#
# The clients are system binaries with their own libwayland: they are the peers, not
# the product.  Each is a separate process on its own connection, so "three windows"
# is three clients and not one client's idea of three.
#
# The overlay is read back as pixels because every claim about a switcher is
# ultimately a claim about what is on the screen: that the panel is above the
# windows, that the bar is on the selected row, and that each row's text is the
# window's own title at the output's scale.  The frame is also compared with a full
# repaint after the overlay goes away, so a stale rectangle cannot hide there.
#
# Requires weston-eventdemo and libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-switcher.XXXXXX")"
chmod 700 "$runtime_dir"
log="$runtime_dir/gate.log"

cleanup() { rm -rf "$runtime_dir"; }
trap cleanup EXIT

fail() {
  printf 'switcher-gate: %s\n' "$*" >&2
  for file in "$log" "$runtime_dir"/[ABC].log; do
    [ -f "$file" ] && { printf '  --- %s ---\n' "$(basename "$file")" >&2
                        tail -n 20 "$file" | sed 's/^/  /' >&2; }
  done
  exit 1
}

client="$(command -v weston-eventdemo 2>/dev/null)"
[ -n "$client" ] || fail "weston-eventdemo is not installed; it is the client this gate needs"
pkg-config --exists pixman-1 2>/dev/null || fail "no libpixman development files"

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
  WESTON_CLIENT="$client" SWITCHER_LOG_DIR="$runtime_dir" CL_WAYLAND_ROOT="$repo_root" \
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/switcher-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

[ "$status" -eq 0 ] || fail "the switcher did not open, walk, commit or clean up"
[ -s "$log" ] || fail "the gate wrote no log"

printf 'switcher-gate: %s checks passed\n' "$(grep -ac '^  ok   ' "$log")"
