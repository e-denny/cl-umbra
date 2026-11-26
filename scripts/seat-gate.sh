#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The phase-3b gate: seats and input.
#
#   /usr/bin/weston-simple-shm          -> the client (a system binary)
#   scripts/seat-gate.lisp              -> compositor, focus, injected input
#   tests/c-client/xkb-keymap-probe.c   -> parses the keymap we actually sent
#
# Two independent proofs, on purpose:
#
#   the driver  proves the *chain*: focus, enter, keymap fd, key, exit 0;
#   the probe   proves the *artifact*: the keymap text, parsed by libxkbcommon
#               with no default includes, translates keycode 1 to Escape and
#               Shift+q to Q.
#
# The probe links libxkbcommon and the client links libwayland; both are peers,
# not the product (D1, D28). Requires cc, xkbcommon and libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-seat.XXXXXX")"
chmod 700 "$runtime_dir"
probe="$runtime_dir/xkb-keymap-probe"
keymap="$runtime_dir/keymap.xkb"
frame="$runtime_dir/frame.png"
log="$runtime_dir/gate.log"

cleanup() { rm -rf "$runtime_dir"; }
trap cleanup EXIT

fail() {
  printf 'seat-gate: %s\n' "$*" >&2
  [ -f "$log" ] && tail -n 40 "$log" | sed 's/^/  /' >&2
  exit 1
}

# weston-eventdemo prints what it received (keysyms, modifiers, coordinates); it
# is the client that makes this gate's assertions about a *client's* view.
client="$(command -v weston-eventdemo 2>/dev/null)"
[ -n "$client" ] || fail "weston-eventdemo is not installed; it is the client this gate needs"
command -v cc >/dev/null 2>&1 || fail "no C compiler; the keymap probe needs one"
pkg-config --exists xkbcommon 2>/dev/null || fail "no libxkbcommon development files"
pkg-config --exists pixman-1 2>/dev/null || fail "no libpixman development files"

cc -std=c11 -Wall -Wextra -Werror \
   -o "$probe" "$repo_root/tests/c-client/xkb-keymap-probe.c" \
   $(pkg-config --cflags --libs xkbcommon) \
   || fail "the keymap probe did not compile"

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
  SEAT_CLIENT="$client" KEYMAP_FILE="$keymap" FRAME_PNG="$frame" \
  CL_WAYLAND_ROOT="$repo_root" \
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/seat-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

[ "$status" -eq 0 ] || fail "the seat gate failed"
[ -s "$keymap" ] || fail "no keymap was written"
[ -s "$frame" ] || fail "no screenshot was written"

# Keycode 1 is Escape; 16 is q (Shift -> Q); 41 is the key between Escape and 1
# (grave, shifted asciitilde -- it was missing from the table until 3h); 42 is
# Shift_L; 103 is Up.  A key the keymap does not know translates as MISSING and
# fails the probe, which is how a missing row is caught rather than typed around.
"$probe" "$keymap" 1 16 41 42 103 > "$runtime_dir/probe.log" 2>&1 \
  || { cat "$runtime_dir/probe.log" >&2; fail "the keymap we sent does not parse or translate"; }
cat "$runtime_dir/probe.log"

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

printf 'seat-gate: %s\n' "$(grep -a '^seat ' "$log" | tail -n 1)"
printf 'seat-gate: %s\n' "$(grep -a 'client printed: key key: 16' "$log" | tail -n 1 | sed 's/^ *ok *client printed: //')"
printf 'seat-gate: %s\n' "$(grep -a '^descriptors: ' "$log" | tail -n 1)"
printf 'seat-gate: %s\n' "$(grep -a '^keymap: parses' "$runtime_dir/probe.log" | tail -n 1)"
