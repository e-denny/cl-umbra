#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The rendering gate: damage, buffer scale, buffer transform and opaque culling.
#
#   tests/c-client/wayland-scale-client.c -> the client (compiled here)
#   scripts/render-gate.lisp              -> compositors at scale 1 and 2, pixels
#
# A real libwayland client draws one four-quadrant buffer with a buffer scale and a
# buffer transform it is told to use.  The gate runs it against a scale-1 output, a
# scale-2 output (buffer scale 1: the client is magnified) and a scale-2 output with
# buffer scale 2 (1:1, the case that makes a HiDPI session crisp), then repeats with
# a 90-degree counter-clockwise and a 180-degree transform and checks which quadrant
# ended up where.
#
# The second half is a scene with no client at all: it moves opaque and translucent
# rectangles a few pixels at a time, then compares the incrementally repainted frame
# with a full repaint of the same scene, pixel for pixel.
#
# Requires cc, wayland-client headers and libpixman.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-render.XXXXXX")"
chmod 700 "$runtime_dir"
client="$runtime_dir/wayland-scale-client"
log="$runtime_dir/gate.log"
frame="$runtime_dir/frame.png"

cleanup() { rm -rf "$runtime_dir"; }
trap cleanup EXIT

fail() {
  printf 'render-gate: %s\n' "$*" >&2
  [ -f "$log" ] && tail -n 60 "$log" | sed 's/^/  /' >&2
  exit 1
}

command -v cc >/dev/null 2>&1 || fail "no C compiler; the gate client needs one"
pkg-config --exists wayland-client 2>/dev/null || fail "no wayland-client development files"
pkg-config --exists pixman-1 2>/dev/null || fail "no libpixman development files"

cc -std=c11 -Wall -Wextra -Werror \
   -o "$client" "$repo_root/tests/c-client/wayland-scale-client.c" \
   $(pkg-config --cflags --libs wayland-client) \
   || fail "the scale client did not compile"

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
  RENDER_CLIENT="$client" FRAME_PNG="$frame" CL_WAYLAND_ROOT="$repo_root" \
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --load "$repo_root/scripts/render-gate.lisp" > "$log" 2>&1
status=$?

cat "$log"

[ "$status" -eq 0 ] || fail "the frame did not match what scale, transform and damage say"
[ -s "$frame" ] || fail "no screenshot was written"

printf 'render-gate: %s checks passed, screenshot %s bytes\n' \
       "$(grep -ac '^  ok   ' "$log")" "$(stat -c %s "$frame")"
