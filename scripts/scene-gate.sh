#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The scene v0 gate: placement, hit testing, click to focus, and a drawn cursor.
#
#   /usr/bin/weston-simple-shm   -> two clients (a system binary, run twice)
#   scripts/scene-gate.lisp      -> compositor, injected pointer, assertions, PNG
#
# The clients are real xdg-shell clients with their own libwayland; nothing here
# is a mock.  What this clause adds over the xdg-shell one is that there is more
# than one window and input, so "which window is that" has an answer.
#
# Requires weston-simple-shm and libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-scene.XXXXXX")"
chmod 700 "$runtime_dir"
frame="$runtime_dir/frame.png"
log="$runtime_dir/gate.log"

cleanup() { rm -rf "$runtime_dir"; }
trap cleanup EXIT

fail() {
  printf 'scene-gate: %s\n' "$*" >&2
  [ -f "$log" ] && tail -n 40 "$log" | sed 's/^/  /' >&2
  exit 1
}

client="$(command -v weston-simple-shm 2>/dev/null)"
[ -n "$client" ] || fail "weston-simple-shm is not installed; it is the client this gate needs"
pkg-config --exists pixman-1 2>/dev/null || fail "no libpixman development files"

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
  WESTON_CLIENT="$client" FRAME_PNG="$frame" CL_WAYLAND_ROOT="$repo_root" \
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/scene-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

[ "$status" -eq 0 ] || fail "the scene gate failed"
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

printf 'scene-gate: %s\n' "$(grep -a '^window B:' "$log" | tail -n 1)"
printf 'scene-gate: %s\n' "$(grep -a '^configure: ' "$log" | tail -n 1)"
printf 'scene-gate: %s\n' "$(grep -a '^cursor: ' "$log" | tail -n 1)"
printf 'scene-gate: two windows, click to focus and a drawn cursor, screenshot %s bytes\n' \
       "$(stat -c %s "$frame")"
