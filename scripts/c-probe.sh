#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The independent C client (phase-1 gate, third clause of four): a libwayland
# client that binds, round-trips, destroys, and re-binds across versions, and
# that proves wl_display.delete_id arrived by getting the released id back.
#
# The probe is compiled here, into a temporary directory, against the system's
# libwayland-client.  It is the *peer*, not the product: it links libwayland on
# purpose, and everything we ship refuses to (D1).  Requires `cc` and the
# wayland-client development headers.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-cprobe.XXXXXX")"
chmod 700 "$runtime_dir"
probe="$runtime_dir/wayland-probe"

cleanup() {
  if [ -n "$demo_server_pid" ] && kill -0 "$demo_server_pid" 2>/dev/null; then
    kill -KILL "$demo_server_pid" 2>/dev/null
  fi
  rm -rf "$runtime_dir"
}
trap cleanup EXIT

fail() {
  printf 'gate: %s\n' "$*" >&2
  exit 1
}

command -v cc >/dev/null 2>&1 || fail "no C compiler; the probe needs one"
pkg-config --exists wayland-client 2>/dev/null || fail "no wayland-client development files"

# Deliberately strict: the probe is a test fixture and should compile clean.
cc -std=c11 -Wall -Wextra -Werror \
   -o "$probe" "$repo_root/tests/c-client/wayland-probe.c" \
   $(pkg-config --cflags --libs wayland-client) \
   || fail "the C probe did not compile"

demo_server_start "$runtime_dir" "$runtime_dir/server.log" || fail "the demo server did not start"

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 "$probe"
probe_status=$?

demo_server_stop "$runtime_dir/server.log" || { cat "$runtime_dir/server.log" >&2; exit 1; }

socket="$(demo_socket_path "$runtime_dir")"
[ ! -e "$socket" ] || fail "the socket survived shutdown"
[ ! -e "$socket.lock" ] || fail "the lock file survived shutdown"

[ "$probe_status" -eq 0 ] || fail "the C probe exited $probe_status"

printf 'c-probe: bind/destroy/rebind across versions, released id reused, server clean\n'
