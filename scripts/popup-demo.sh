#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# A manual test for popups: build a client that opens menus, then start a nested
# tinywl session with it as the launched client.
#
#   ./scripts/popup-demo.sh                       # 1024x640 nested window
#   ./scripts/popup-demo.sh --size 800x600        # arguments go to TINYWL:MAIN
#
# None of the clients installed on this machine opens a popup (weston-terminal has
# no menus and kitty needs EGL), so the only way to see a menu by hand is a client
# that asks for one.  tests/c-client/wayland-popup-client.c is that client: it is a
# real libwayland client with its own xdg-shell, compiled here against xdg-shell
# generated from our vendored XML by wayland-scanner.
#
# Left-click anywhere inside the window and the menu appears *there* (1x1 anchor
# rectangle at the pointer); Escape or a click outside dismisses it.  Clicking near
# the window's bottom-right corner on a small output makes the compositor flip the
# menu back inside, which is the same code the gate exercises with fixed anchors.
#
# The client is built into a temporary directory and removed on exit.  Requires cc,
# wayland-scanner, wayland-client headers and a live session (WAYLAND_DISPLAY) for
# --nested.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-popup-demo.XXXXXX")"
cleanup() { rm -rf "$build_dir"; }
trap cleanup EXIT

command -v cc >/dev/null 2>&1 || { echo "error: no C compiler" >&2; exit 1; }
command -v wayland-scanner >/dev/null 2>&1 || { echo "error: no wayland-scanner" >&2; exit 1; }

wayland-scanner client-header \
  "$repo_root/protocols/wayland-protocols/stable/xdg-shell/xdg-shell.xml" \
  "$build_dir/xdg-shell-client-protocol.h" || exit 1
wayland-scanner private-code \
  "$repo_root/protocols/wayland-protocols/stable/xdg-shell/xdg-shell.xml" \
  "$build_dir/xdg-shell-protocol.c" || exit 1

cc -std=c11 -Wall -Wextra -Werror -Wno-missing-field-initializers \
   -I"$build_dir" \
   -o "$build_dir/wayland-popup-client" \
   "$repo_root/tests/c-client/wayland-popup-client.c" \
   "$build_dir/xdg-shell-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) || exit 1

# --launch takes one executable, not a command line (tinywl:main's rule, D14), so the
# flag goes in a one-line wrapper rather than in the argument.
cat > "$build_dir/launch-popup" <<WRAPPER
#!/bin/sh
exec "$build_dir/wayland-popup-client" --follow-pointer
WRAPPER
chmod +x "$build_dir/launch-popup"

printf 'popup-demo: built %s\n' "$build_dir/wayland-popup-client"
printf 'popup-demo: left-click in the window for a menu at the pointer; Escape dismisses it\n'
"$repo_root/scripts/tinywl.sh" "$@" --launch "$build_dir/launch-popup"
