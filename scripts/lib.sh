#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Shared environment for the scripts here: where the checkout is, and where
# CFFI comes from.  CFFI is the one external dependency of cl-wayland-core
# (sockets, sendmsg/recvmsg, memfd); it is pulled from Quicklisp, or qlot once
# the qlfile pins it.
#
#   QUICKLISP_SETUP   override the Quicklisp setup.lisp path

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The clause that takes the screen has to run as root, because SET MASTER is a
# privileged ioctl even on a virtual card; under sudo, $HOME is root's and the
# person's Quicklisp is somewhere else.  SUDO_USER's home is searched for that
# reason and only for that reason: dropping to root should not mean installing a
# second copy of CFFI.
find_quicklisp() {
  local sudo_home="" candidate
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  fi
  for candidate in "${QUICKLISP_SETUP:-}" \
                   "$HOME/quicklisp/setup.lisp" \
                   "$HOME/Packages/quicklisp/setup.lisp" \
                   ${sudo_home:+"$sudo_home/quicklisp/setup.lisp"} \
                   ${sudo_home:+"$sudo_home/Packages/quicklisp/setup.lisp"}; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

quicklisp_setup="$(find_quicklisp || true)"
if [ -z "$quicklisp_setup" ]; then
  cat >&2 <<'MESSAGE'
error: Quicklisp not found.  cl-wayland-core needs CFFI for sockets and file
       descriptor passing.  Install Quicklisp, or point QUICKLISP_SETUP at its
       setup.lisp, or run `qlot install` to vendor the dependencies.
MESSAGE
  exit 1
fi

# Hermetic: no user init files, nothing inherited, only this checkout on the
# source registry -- plus Quicklisp, which supplies CFFI.
sbcl_evals=(
  --eval '(require :asdf)'
  --eval "(asdf:initialize-source-registry '(:source-registry (:tree \"$repo_root/\") :ignore-inherited-configuration))"
  --eval "(load \"$quicklisp_setup\")"
)

# ---------------------------------------------------------------------------
# A demo server for the phase-1 gate clauses
# ---------------------------------------------------------------------------
#
# Both phase-1 clauses need the same thing: our server listening on its own
# socket in a private runtime directory, started the way a session manager starts
# a compositor, and stopped the way one stops it.  Keeping the start/stop here
# means the clauses cannot drift in how they launch it.

demo_server_pid=""

demo_socket_path() { printf '%s/wayland-0' "$1"; }

# demo_server_start RUNTIME_DIR LOG
#   Sets demo_server_pid.  Fails with the server's log on stderr if the socket
#   never appears, and checks that the pid holding the socket lock is the pid we
#   started: a clause that kills the wrong process proves nothing.
demo_server_start() {
  local runtime_dir="$1" log="$2" socket
  socket="$(demo_socket_path "$runtime_dir")"
  XDG_RUNTIME_DIR="$runtime_dir" WAYLAND_DISPLAY=wayland-0 \
    sbcl --noinform --non-interactive --no-userinit --no-sysinit \
    "${sbcl_evals[@]}" \
    --eval '(asdf:load-system "cl-wayland-server/demo")' \
    --eval '(wayland.server.demo:toplevel)' \
    > "$log" 2>&1 &
  demo_server_pid=$!
  # The socket appearing is the server's own announcement that it is ready; the
  # timeout is generous because a cold image compiles the protocol system first.
  for _ in $(seq 1 600); do
    [ -S "$socket" ] && break
    kill -0 "$demo_server_pid" 2>/dev/null || break
    sleep 0.1
  done
  if [ ! -S "$socket" ]; then
    cat "$log" >&2
    return 1
  fi
  if [ -f "$socket.lock" ]; then
    local lock_pid
    lock_pid="$(tr -d ' \n' < "$socket.lock")"
    if [ "$lock_pid" != "$demo_server_pid" ]; then
      printf 'gate: the lock file names pid %s, but the server we started is %s\n' \
             "$lock_pid" "$demo_server_pid" >&2
      return 1
    fi
  fi
  return 0
}

# demo_server_stop LOG
#   SIGTERM, then require a clean exit and the removal of socket and lock.
demo_server_stop() {
  local log="$1" status=0
  [ -n "$demo_server_pid" ] || return 0
  kill -TERM "$demo_server_pid" 2>/dev/null
  wait "$demo_server_pid" 2>/dev/null || status=$?
  demo_server_pid=""
  if [ "$status" -ne 0 ]; then
    printf 'gate: the server exited %s on SIGTERM; it must stop cleanly\n' "$status" >&2
    tail -n 20 "$log" >&2
    return 1
  fi
  return 0
}
