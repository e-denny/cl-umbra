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

find_quicklisp() {
  local candidate
  for candidate in "${QUICKLISP_SETUP:-}" \
                   "$HOME/quicklisp/setup.lisp" \
                   "$HOME/Packages/quicklisp/setup.lisp"; do
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
