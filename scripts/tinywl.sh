#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run cl-tinywl.  This is the launcher the manual test needs: a bare `sbcl` has no
# ASDF, no Quicklisp and no CL-TINYWL, so "load the system, then call TINYWL:MAIN"
# is four forms to get wrong before anything appears on screen.
#
#   ./scripts/tinywl.sh --nested --size 1024x640
#   ./scripts/tinywl.sh --help
#
# Arguments go to TINYWL:MAIN unchanged.  With --nested the parent is
# WAYLAND_DISPLAY (a name in XDG_RUNTIME_DIR is resolved, see
# TINYWL:PARENT-SOCKET-PATH); the session's own socket is tinywl-1 unless --display
# says otherwise, and clients connect to it with WAYLAND_DISPLAY=tinywl-1.
#
# Exit status is TINYWL:MAIN's: 0 after Alt+Esc or the parent closing our window, 2
# for a bad command line.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The arguments are baked into the eval as Lisp strings, because SBCL leaves its own
# "--" in *posix-argv* and TINYWL:MAIN would then read it as an option of ours.
lisp_arguments=""
for argument in "$@"; do
  escaped="${argument//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  lisp_arguments="$lisp_arguments \"$escaped\""
done

exec sbcl --noinform --non-interactive \
  "${sbcl_evals[@]}" \
  --eval '(asdf:load-system "cl-tinywl")' \
  --eval "(uiop:quit (tinywl:main (list$lisp_arguments)))"
