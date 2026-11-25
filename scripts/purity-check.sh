#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Edgar Denny
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Purity check, decision D1: the stack speaks the Wayland wire protocol itself.
# Nothing we build may link, load or map libwayland or wlroots, in any form.
#
#   purity-check.sh                     scan the sources
#   purity-check.sh --binary PATH       also check an ELF file (ldd, nm -D)
#   purity-check.sh --pid PID           also check a live process (/proc/PID/maps)
#
# The source scan is a heuristic: it flags foreign-loading forms whose text
# names a forbidden library on the same line.  Comments and documentation may
# name these libraries freely -- they are what we are replacing.  The exact
# check is the binary/process probe, and scripts/check-loads.sh probes the
# loaded Lisp image.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
forbidden='libwayland|libwlroots'
status=0
binary=""
pid=""

usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'IMPURE: %s\n' "$*" >&2
  status=1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --binary)
      [ $# -ge 2 ] || { echo "--binary needs a path" >&2; exit 2; }
      binary="$2"; shift 2 ;;
    --pid)
      [ $# -ge 2 ] || { echo "--pid needs a process id" >&2; exit 2; }
      pid="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# 1. Sources: no foreign-loading form may name these libraries.
hits="$(grep -rInE --include='*.lisp' --include='*.asd' \
          '\b(load-foreign-library|define-foreign-library|load-shared-object|dlopen)\b' \
          "$root" 2>/dev/null | grep -E "$forbidden" || true)"
if [ -n "$hits" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && fail "foreign library load in source: $line"
  done <<EOF
$hits
EOF
fi

# 2. A binary: no dynamic dependency, no exported Wayland entry points.
if [ -n "$binary" ]; then
  if [ ! -f "$binary" ]; then
    echo "no such file: $binary" >&2
    exit 2
  fi
  count="$(ldd "$binary" 2>/dev/null | grep -cE "$forbidden")"
  [ "$count" -gt 0 ] && fail "$binary links a forbidden library (ldd)"
  count="$(nm -D "$binary" 2>/dev/null | grep -cE '\bwl_display_(connect|create|add_global)\b|\bwlr_')"
  [ "$count" -gt 0 ] && fail "$binary exports or imports libwayland/wlroots symbols"
fi

# 3. A live process: nothing forbidden may be mapped into it.
if [ -n "$pid" ]; then
  if [ ! -r "/proc/$pid/maps" ]; then
    echo "cannot read /proc/$pid/maps" >&2
    exit 2
  fi
  count="$(grep -cE "$forbidden" "/proc/$pid/maps")"
  [ "$count" -gt 0 ] && fail "process $pid maps a forbidden library"
fi

if [ "$status" -eq 0 ]; then
  echo "purity: ok"
else
  echo "purity: FAILED" >&2
fi
exit "$status"
