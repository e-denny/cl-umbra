#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The first phase-1 gate clause: a real libwayland client, `wayland-info`, talks
# to our server and exits 0.
#
# Nothing here is a mock.  The server is started the way a compositor would be
# started, on its own socket in a private runtime directory; wayland-info is the
# system's own build, with its own libwayland; the server is stopped the way a
# session manager stops one, with SIGTERM, and has to exit cleanly and take its
# socket and lock file with it.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-server.XXXXXX")"
chmod 700 "$runtime_dir"
socket="$runtime_dir/wayland-0"
server_pid=""

cleanup() {
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    kill -KILL "$server_pid" 2>/dev/null
  fi
  rm -rf "$runtime_dir"
}
trap cleanup EXIT

fail() {
  printf 'gate: %s\n' "$*" >&2
  exit 1
}

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
  sbcl --noinform --non-interactive --no-userinit --no-sysinit \
  "${sbcl_evals[@]}" \
  --eval '(asdf:load-system "cl-wayland-server/demo")' \
  --eval '(wayland.server.demo:toplevel)' \
  > "$runtime_dir/server.log" 2>&1 &
server_pid=$!

# The socket appearing is the server's own announcement that it is ready; the
# timeout is generous because a cold image has to compile the protocol system.
for _ in $(seq 1 600); do
  [ -S "$socket" ] && break
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 0.1
done
[ -S "$socket" ] || { cat "$runtime_dir/server.log" >&2; fail "the server never created $socket"; }
[ -f "$socket.lock" ] || fail "the server did not create $socket.lock"

XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
  wayland-info > "$runtime_dir/wayland-info.txt" 2> "$runtime_dir/wayland-info.err"
info_status=$?

kill -TERM "$server_pid" 2>/dev/null
wait "$server_pid" 2>/dev/null
server_status=$?

[ "$info_status" -eq 0 ] || {
  cat "$runtime_dir/wayland-info.err" >&2
  fail "wayland-info exited $info_status"
}
[ "$server_status" -eq 0 ] || {
  cat "$runtime_dir/server.log" >&2
  fail "the server exited $server_status on SIGTERM"
}
[ ! -e "$socket" ] || fail "the socket survived shutdown"
[ ! -e "$socket.lock" ] || fail "the lock file survived shutdown"

grep -q "wl_compositor" "$runtime_dir/wayland-info.txt" || fail "wl_compositor was not announced"
grep -q "wl_output" "$runtime_dir/wayland-info.txt" || fail "wl_output was not announced"
grep -q "mode:" "$runtime_dir/wayland-info.txt" || fail "the output's initial events did not arrive"

# The gate log is the evidence: what the client saw, and the globals it counted.
cat "$runtime_dir/wayland-info.txt"
printf 'wayland-info: exit 0 against %s, %s globals, shutdown clean\n' \
       "$socket" "$(grep -c '^interface:' "$runtime_dir/wayland-info.txt")"
