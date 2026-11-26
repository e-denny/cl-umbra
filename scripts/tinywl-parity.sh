#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The phase-3 exit gate: the tinywl parity script, run twice (PLAN.md §5).
#
#   tests/c-client/wayland-move-client.c -> the second window (compiled here)
#   scripts/tinywl-parity.lisp           -> the run, once per mode
#
# A real application and a real client, driven by hand: click to focus, typing to
# the focused window only, Alt+left to move, Alt+right to resize from the edge,
# Alt+F1 to cycle, Alt+Esc to quit -- once with tinywl's output in memory and input
# injected, once with the output inside another compositor.  The same run twice,
# because a compositor whose behaviour changes when it is nested is one whose policy
# is in the wrong layer.
#
# The second window is a libwayland client compiled at gate time from our vendored
# xdg-shell.xml; it links libwayland-client on purpose (it is the peer, not the
# product).
#
# Requires cc, wayland-scanner, wayland-client headers, weston-eventdemo and
# libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-tinywl.XXXXXX")"
chmod 700 "$runtime_dir"
client="$runtime_dir/wayland-move-client"
log_headless="$runtime_dir/headless.log"
log_nested="$runtime_dir/nested.log"
png_headless="$runtime_dir/headless.png"
png_nested="$runtime_dir/nested.png"

cleanup() { rm -rf "$runtime_dir"; }
trap cleanup EXIT

fail() {
  printf 'tinywl-parity: %s\n' "$*" >&2
  for log in "$log_headless" "$log_nested"; do
    [ -f "$log" ] && { printf '  --- %s ---\n' "$(basename "$log")" >&2
                       tail -n 40 "$log" | sed 's/^/  /' >&2; }
  done
  exit 1
}

command -v cc >/dev/null 2>&1 || fail "no C compiler; the second window needs one"
command -v wayland-scanner >/dev/null 2>&1 || fail "no wayland-scanner; xdg-shell's client code is generated from it"
pkg-config --exists wayland-client 2>/dev/null || fail "no wayland-client development files"
pkg-config --exists pixman-1 2>/dev/null || fail "no libpixman development files"
command -v weston-eventdemo >/dev/null 2>&1 || fail "weston-eventdemo is not installed; it is the window that reports keys"

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
   || fail "the second window did not compile"

# png_validate FILE: the frame is an artefact a person may look at, so it has to be
# a real PNG and not 512 KiB of pixels with a signature.
png_validate() {
  python3 - "$1" <<'PY'
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
}

run_mode() {                            # mode log png
  local mode="$1" log="$2" png="$3"
  XDG_RUNTIME_DIR="$runtime_dir" \
    TINYWL_MODE="$mode" \
    TINYWL_CLIENT=weston-eventdemo \
    TINYWL_SECOND_CLIENT="$client" \
    FRAME_PNG="$png" \
    sbcl --noinform --non-interactive --no-userinit --no-sysinit \
    "${sbcl_evals[@]}" \
    --load "$repo_root/scripts/tinywl-parity.lisp" > "$log" 2>&1
  local status=$?
  cat "$log"
  [ "$status" -eq 0 ] || fail "the $mode run failed"
  grep -q '^tinywl-parity: .* run passed$' "$log" || fail "the $mode run did not report a verdict"
  [ -s "$png" ] || fail "the $mode run wrote no screenshot"
  png_validate "$png" || fail "the $mode screenshot is not a valid PNG"
}

printf '\nthe tinywl parity script: a target in memory, input injected\n\n'
run_mode headless "$log_headless" "$png_headless"

printf '\nthe tinywl parity script: a window inside another compositor\n\n'
run_mode nested "$log_nested" "$png_nested"

# The summary the gate prints: one line per clause per mode, taken from the run
# itself rather than restated here, so the gate cannot claim more than the run did.
for log in "$log_headless" "$log_nested"; do
  mode="$(grep -a -o 'ok   \[[a-z]*\]' "$log" | head -n 1 | sed 's/ok *\[//; s/\]//')"
  printf 'tinywl-parity: %-8s %s checks, %s\n' "$mode" \
         "$(grep -ac '^  ok   ' "$log")" \
         "$(grep -a '^descriptors:' "$log" | tail -n 1)"
done

printf 'tinywl-parity: two runs (headless, nested), each with two real clients and six clauses\n'
