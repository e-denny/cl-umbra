#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The grabs and keybindings gate.
#
#   tests/c-client/wayland-move-client.c  -> the client (compiled here)
#   scripts/grab-gate.lisp                -> compositor, injected pointer and keys
#
# The client is a real libwayland client with its own xdg-shell, generated from
# our vendored xdg-shell.xml by wayland-scanner at gate time.  It asks to be moved
# and resized with the serials we issued to it; the gate asserts the window's
# position, its pixels, the configure a resize produces, Alt+F1 cycling and
# Alt+Esc stopping.  It links libwayland-client on purpose: it is the peer, not
# the product.
#
# Requires cc, wayland-scanner, wayland-client headers, weston-simple-shm and
# libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-grab.XXXXXX")"
chmod 700 "$runtime_dir"
client="$runtime_dir/wayland-move-client"
frame="$runtime_dir/frame.png"
log="$runtime_dir/gate.log"

cleanup() { rm -rf "$runtime_dir"; }
trap cleanup EXIT

fail() {
  printf 'grab-gate: %s\n' "$*" >&2
  [ -f "$log" ] && tail -n 40 "$log" | sed 's/^/  /' >&2
  exit 1
}

command -v cc >/dev/null 2>&1 || fail "no C compiler; the gate client needs one"
command -v wayland-scanner >/dev/null 2>&1 || fail "no wayland-scanner; xdg-shell's client code is generated from it"
pkg-config --exists wayland-client 2>/dev/null || fail "no wayland-client development files"
pkg-config --exists pixman-1 2>/dev/null || fail "no libpixman development files"
command -v weston-simple-shm >/dev/null 2>&1 || fail "weston-simple-shm is not installed; it is the second window"

wayland-scanner client-header \
  "$repo_root/protocols/wayland-protocols/stable/xdg-shell/xdg-shell.xml" \
  "$runtime_dir/xdg-shell-client-protocol.h" || fail "wayland-scanner could not generate xdg-shell's header"
wayland-scanner private-code \
  "$repo_root/protocols/wayland-protocols/stable/xdg-shell/xdg-shell.xml" \
  "$runtime_dir/xdg-shell-protocol.c" || fail "wayland-scanner could not generate xdg-shell's code"

cc -std=c11 -Wall -Wextra -Werror -Wno-missing-field-initializers \
   -I"$runtime_dir" \
   -o "$client" "$repo_root/tests/c-client/wayland-move-client.c" \
   "$runtime_dir/xdg-shell-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) \
   || fail "the move gate client did not compile"

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
  MOVE_CLIENT="$client" FRAME_PNG="$frame" CL_WAYLAND_ROOT="$repo_root" \
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/grab-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

[ "$status" -eq 0 ] || fail "the grabs gate failed"
[ -s "$frame" ] || fail "no screenshot was written"

python3 - "$frame" <<'PY' || fail "the screenshot is not a valid PNG"
import struct, sys, zlib
path = sys.argv[1]
data = open(path, 'rb').read()
assert data[:8] == b'\x89PNG\r\n\x1a\n', 'bad signature'
pos, chunks = 8, []
while pos < len(data):
    length = struct.unpack('>I', data[pos:pos+4])[0]
    kind = data[pos+4:pos+8]
    body = data[pos+8:pos+8+length]
    crc = struct.unpack('>I', data[pos+8+length:pos+12+length])[0]
    assert crc == zlib.crc32(kind + body) & 0xFFFFFFFF, 'bad CRC in %r' % kind
    chunks.append(kind)
    pos += 12 + length
assert chunks[0] == b'IHDR' and chunks[-1] == b'IEND', chunks
print('png: %d bytes, chunks %s' % (len(data), b' '.join(chunks).decode()))
PY

printf 'grab-gate: %s\n' "$(grep -a 'the drag moved' "$log" | tail -n 1 | sed 's/^ *//')"
printf 'grab-gate: %s\n' "$(grep -a 'configured the client for' "$log" | tail -n 1 | sed 's/^ *//')"
printf 'grab-gate: %s\n' "$(grep -a 'alt+F1 focused' "$log" | tail -n 1 | sed 's/^ *//')"
printf 'grab-gate: %s\n' "$(grep -a 'alt+Esc asked' "$log" | tail -n 1 | sed 's/^ *//')"
printf 'grab-gate: a real client was moved and resized by serial, screenshot %s bytes\n' \
       "$(stat -c %s "$frame")"
