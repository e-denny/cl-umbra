#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The first phase-1 gate clause: a real libwayland client, `wayland-info`, talks
# to our server and exits 0.
#
# Nothing here is a mock.  The server is started the way a compositor would be
# started, on its own socket in a private runtime directory (scripts/lib.sh);
# wayland-info is the system's own build, with its own libwayland; the server is
# stopped the way a session manager stops one, with SIGTERM, and has to exit
# cleanly and take its socket and lock file with it.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-server.XXXXXX")"
chmod 700 "$runtime_dir"

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

command -v wayland-info >/dev/null 2>&1 || fail "wayland-info is not installed"

demo_server_start "$runtime_dir" "$runtime_dir/server.log" || fail "the demo server did not start"

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
  wayland-info > "$runtime_dir/wayland-info.txt" 2> "$runtime_dir/wayland-info.err"
info_status=$?

demo_server_stop "$runtime_dir/server.log" || { cat "$runtime_dir/server.log" >&2; exit 1; }

[ "$info_status" -eq 0 ] || {
  cat "$runtime_dir/wayland-info.err" >&2
  fail "wayland-info exited $info_status"
}
socket="$(demo_socket_path "$runtime_dir")"
[ ! -e "$socket" ] || fail "the socket survived shutdown"
[ ! -e "$socket.lock" ] || fail "the lock file survived shutdown"

grep -q "wl_compositor" "$runtime_dir/wayland-info.txt" || fail "wl_compositor was not announced"
grep -q "wl_output" "$runtime_dir/wayland-info.txt" || fail "wl_output was not announced"
grep -q "mode:" "$runtime_dir/wayland-info.txt" || fail "the output's initial events did not arrive"

# The gate log is the evidence: what the client saw, and the globals it counted.
cat "$runtime_dir/wayland-info.txt"
printf 'wayland-info: exit 0 against %s, %s globals, shutdown clean\n' \
       "$socket" "$(grep -c '^interface:' "$runtime_dir/wayland-info.txt")"
