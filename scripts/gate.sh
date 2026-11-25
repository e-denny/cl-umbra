#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The phase-0 gate (PLAN.md §5): the claims that must hold before phase 1
# starts.  Each clause is checked, not asserted, and a clause with nothing
# behind it says so instead of passing quietly.
#
# Exit status:
#   0  every clause passed
#   1  a clause failed
#   2  no clause failed, but at least one has nothing behind it yet, so the
#      gate is not met (no clause is in that state today; the machinery stays
#      for the clauses later phases will add)
#
# Clauses:
#   1. the unit suite is green (Rove, six suites)
#   2. every vendored protocol XML generates Lisp that compiles (69 files)
#   3. demo-globals prints the live session's globals, and they match
#      wayland-info (skipped, not failed, when there is no session)
#   4. the fuzz harness feeds 10^6 random cases through the decoder with no
#      crash, hang, unbounded allocation or descriptor leak
#   5. purity: no libwayland or libwlroots in the loaded image (D1)
#
# Logs land in a temporary directory that is printed when something fails.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log_dir="$(mktemp -d "${TMPDIR:-/tmp}/cl-wayland-gate.XXXXXX")"
passed=0
failed=0
skipped=0
todo=0

report() {                              # status name detail
  printf '  %-11s %-24s %s\n' "$1" "$2" "$3"
}

pass() { report PASS "$1" "$2"; passed=$((passed + 1)); }
fail() {
  report FAIL "$1" "$2"
  failed=$((failed + 1))
  printf '               log: %s\n' "$3"
  tail -n 25 "$3" | sed 's/^/               /'
}
skip() { report SKIP "$1" "$2"; skipped=$((skipped + 1)); }
not_implemented() { report 'NOT BUILT' "$1" "$2"; todo=$((todo + 1)); }

gb() {                                  # gb LOGFILE command...
  local log="$1"; shift
  "$@" >"$log" 2>&1
}

printf '\nphase 0 gate: protocol core and a hello-world client\n\n'

# 1. Unit suite ------------------------------------------------------------
if gb "$log_dir/tests.log" "$repo_root/scripts/run-tests.sh"; then
  pass 'unit suite' "$(grep -aE '[0-9]+ suites?,' "$log_dir/tests.log" | tail -n 1)"
else
  fail 'unit suite' 'the Rove suite is not green' "$log_dir/tests.log"
fi

# 2. Every vendored protocol compiles --------------------------------------
if gb "$log_dir/protocols.log" sbcl --non-interactive --no-userinit --no-sysinit \
     "${sbcl_evals[@]}" \
     --eval '(asdf:load-system "cl-wayland-protocols")' \
     --load "$repo_root/scripts/gate-protocols.lisp" \
     --eval '(uiop:quit (if (wayland.gate.protocols:compile-all) 0 1))'; then
  pass 'protocols compile' "$(grep -a 'protocols\? compiled' "$log_dir/protocols.log" | tail -n 1)"
else
  fail 'protocols compile' 'a vendored protocol did not compile' "$log_dir/protocols.log"
fi

# 3. demo-globals against the live session ---------------------------------
wayland_socket() {
  local name="${WAYLAND_DISPLAY:-wayland-0}"
  case "$name" in
    /*) printf '%s\n' "$name" ;;
    *)  printf '%s\n' "${XDG_RUNTIME_DIR:-/nonexistent}/$name" ;;
  esac
}
socket="$(wayland_socket)"
if ! command -v wayland-info >/dev/null 2>&1; then
  skip 'demo-globals' 'wayland-info is not installed, so there is nothing to compare with'
elif [ ! -S "$socket" ]; then
  skip 'demo-globals' "no session at $socket"
elif gb "$log_dir/demo.log" sbcl --noinform --non-interactive --no-userinit --no-sysinit \
       "${sbcl_evals[@]}" \
       --eval '(asdf:load-system "cl-wayland-client/demo")' \
       --eval '(uiop:quit (wayland.client.demo:run :error-stream *error-output*))'; then
  grep -a "^interface: '" "$log_dir/demo.log" > "$log_dir/demo-globals.txt"
  wayland-info 2>/dev/null | grep -a "^interface: '" > "$log_dir/wayland-info.txt"
  if diff -u "$log_dir/wayland-info.txt" "$log_dir/demo-globals.txt" > "$log_dir/demo.diff"; then
    pass 'demo-globals' "$(wc -l < "$log_dir/demo-globals.txt" | tr -d ' ') globals, byte-identical to wayland-info"
  else
    fail 'demo-globals' 'output differs from wayland-info' "$log_dir/demo.diff"
  fi
else
  fail 'demo-globals' 'demo-globals did not exit cleanly' "$log_dir/demo.log"
fi

# 4. Fuzz harness ----------------------------------------------------------
if gb "$log_dir/fuzz.log" "$repo_root/scripts/fuzz.sh" 1000000; then
  pass 'fuzz harness' "$(grep -a '[0-9]* cases:' "$log_dir/fuzz.log" | tail -n 1 | sed 's/^ *//')"
else
  fail 'fuzz harness' 'a fuzz case crashed, hung, leaked or broke an invariant' "$log_dir/fuzz.log"
fi

# 5. Purity ----------------------------------------------------------------
if gb "$log_dir/purity.log" "$repo_root/scripts/purity-check.sh"; then
  pass 'purity' 'no libwayland or libwlroots in the image'
else
  fail 'purity' 'the loaded image links a forbidden library' "$log_dir/purity.log"
fi

# Verdict ------------------------------------------------------------------
printf '\n  %d passed, %d failed, %d skipped, %d not built\n' \
       "$passed" "$failed" "$skipped" "$todo"
if [ "$failed" -gt 0 ]; then
  printf '  phase 0 gate: FAILED\n\n'
  printf '  logs: %s\n\n' "$log_dir"
  exit 1
elif [ "$todo" -gt 0 ]; then
  printf '  phase 0 gate: NOT MET (%d clause(s) unimplemented)\n\n' "$todo"
  rm -rf "$log_dir"
  exit 2
else
  printf '  phase 0 gate: PASSED\n\n'
  rm -rf "$log_dir"
  exit 0
fi
