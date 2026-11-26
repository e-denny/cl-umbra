#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The phase-2a gate: a libwayland shm client draws through the headless
# compositor, and the frame is checked pixel by pixel.
#
#   tests/c-client/wayland-shm-client.c  -> client (compiled here)
#   scripts/headless-gate.lisp           -> compositor, render, assertions, PNG
#
# The client links libwayland-client on purpose; it is the peer, not the product.
# Requires cc, wayland-client headers and libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-headless.XXXXXX")"
chmod 700 "$runtime_dir"
client="$runtime_dir/wayland-shm-client"
frame="$runtime_dir/frame.png"
log="$runtime_dir/gate.log"

cleanup() { rm -rf "$runtime_dir"; }
trap cleanup EXIT

fail() {
  printf 'gate: %s\n' "$*" >&2
  [ -f "$log" ] && tail -n 40 "$log" | sed 's/^/  /' >&2
  exit 1
}

command -v cc >/dev/null 2>&1 || fail "no C compiler; the gate client needs one"
pkg-config --exists wayland-client 2>/dev/null || fail "no wayland-client development files"
pkg-config --exists pixman-1 2>/dev/null || fail "no libpixman development files"

cc -std=c11 -Wall -Wextra -Werror \
   -o "$client" "$repo_root/tests/c-client/wayland-shm-client.c" \
   $(pkg-config --cflags --libs wayland-client) \
   || fail "the shm gate client did not compile"

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
  HEADLESS_CLIENT="$client" FRAME_PNG="$frame" CL_WAYLAND_ROOT="$repo_root" \
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/headless-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

[ "$status" -eq 0 ] || fail "the headless frame gate failed"
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

printf 'headless-frame: %s\n' "$(grep -a 'frame .* rendered' "$log" | tail -n 1)"
printf 'headless-frame: pixel checks passed, screenshot %s\n' "$(stat -c %s "$frame") bytes"
