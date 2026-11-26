#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The phase-3 nested gate: our compositor inside our compositor, with a real
# client inside that.  Both compositors run in one image on two sockets, so the
# clause needs no display, no hardware and no session.
#
#   scripts/nested-gate.lisp  -> parent compositor, nested backend, assertions
#   weston-eventdemo          -> the client inside the nested session
#
# The client is a system binary and its output is read from a pty; nothing about
# the nested session is mocked.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-nested.XXXXXX")"
chmod 700 "$runtime_dir"
frame="$runtime_dir/frame.png"
log="$runtime_dir/gate.log"

cleanup() { rm -rf "$runtime_dir"; }
trap cleanup EXIT

fail() {
  printf 'gate: %s\n' "$*" >&2
  [ -f "$log" ] && tail -n 60 "$log" | sed 's/^/  /' >&2
  exit 1
}

client="$(command -v weston-eventdemo || true)"
[ -n "$client" ] || fail "weston-eventdemo is not installed; the nested gate needs a real client"

XDG_RUNTIME_DIR="$runtime_dir" \
  NESTED_CLIENT="$client" FRAME_PNG="$frame" \
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/nested-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

[ "$status" -eq 0 ] || fail "the nested session gate failed"
[ -s "$frame" ] || fail "no screenshot of the parent's frame was written"

python3 - "$frame" <<'PY' || fail "the parent's screenshot is not a valid PNG"
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

printf 'nested-gate: %s\n' "$(grep -a '^frames presented' "$log" | tail -n 1)"
printf 'nested-gate: %s, screenshot %s bytes\n' \
  "$(grep -a '^pixel grid' "$log" | tail -n 1)" "$(stat -c %s "$frame")"
