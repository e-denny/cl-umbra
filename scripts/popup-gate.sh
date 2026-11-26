#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The popup gate: a real libwayland client opens menus on our compositor.
#
#   tests/c-client/wayland-popup-client.c -> the client (compiled here)
#   scripts/popup-gate.lisp               -> compositor, injected input, pixels
#
# The client is a real libwayland client with its own xdg-shell, generated from our
# vendored xdg-shell.xml by wayland-scanner at gate time.  It asks for two menus with
# different positioners, one of which the compositor has to flip back inside the
# output; the gate asserts the configure it got, the pixels that follow from it, and
# dismissal by Escape and by a click outside.
#
# Requires cc, wayland-scanner, wayland-client headers and libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-popup.XXXXXX")"
chmod 700 "$runtime_dir"
client="$runtime_dir/wayland-popup-client"
log="$runtime_dir/gate.log"

cleanup() { rm -rf "$runtime_dir"; }
trap cleanup EXIT

fail() {
  printf 'popup-gate: %s\n' "$*" >&2
  [ -f "$log" ] && tail -n 40 "$log" | sed 's/^/  /' >&2
  exit 1
}

command -v cc >/dev/null 2>&1 || fail "no C compiler; the gate client needs one"
command -v wayland-scanner >/dev/null 2>&1 || fail "no wayland-scanner; xdg-shell's client code is generated from it"
pkg-config --exists wayland-client 2>/dev/null || fail "no wayland-client development files"
pkg-config --exists pixman-1 2>/dev/null || fail "no libpixman development files"

wayland-scanner client-header \
  "$repo_root/protocols/wayland-protocols/stable/xdg-shell/xdg-shell.xml" \
  "$runtime_dir/xdg-shell-client-protocol.h" || fail "wayland-scanner could not generate xdg-shell's header"
wayland-scanner private-code \
  "$repo_root/protocols/wayland-protocols/stable/xdg-shell/xdg-shell.xml" \
  "$runtime_dir/xdg-shell-protocol.c" || fail "wayland-scanner could not generate xdg-shell's code"

cc -std=c11 -Wall -Wextra -Werror -Wno-missing-field-initializers \
   -I"$runtime_dir" \
   -o "$client" "$repo_root/tests/c-client/wayland-popup-client.c" \
   "$runtime_dir/xdg-shell-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) \
   || fail "the popup gate client did not compile"

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
  POPUP_CLIENT="$client" CL_WAYLAND_ROOT="$repo_root" \
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/popup-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

[ "$status" -eq 0 ] || fail "a client's popup was not placed, drawn or dismissed"

printf 'popup-gate: %s checks passed\n' "$(grep -ac '^  ok   ' "$log")"
