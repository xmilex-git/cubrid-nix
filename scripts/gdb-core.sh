#!/usr/bin/env bash
# gdb on a core of a CUBRID program, offline (ADR 0001 D10; never attached to a live
# server): threads, every thread's backtrace, and the crashing thread's frames with
# their locals. The core may come from another machine (ADR 0003 D9) as long as the
# install's files are the ones that wrote it: their build IDs are compared.
#   gdb-core.sh <install> <core> <results dir>
# PASS: the core's build ID is the program's, the backtraces name CUBRID functions with
# their source file and line, and at least one CUBRID frame shows a local variable.
set -euo pipefail
usage="usage: gdb-core.sh <install> <core> <results dir>"
inst=$(readlink -f "${1:?$usage}")
core=$(readlink -f "${2:?$usage}")
R=${3:?$usage}
mkdir -p "$R"
[ -n "${CUBRID_CI_SNAPSHOT:-}" ] || { echo "run it in the dev shell (nix develop)" >&2; exit 1; }

# the program that wrote the core, from its note
exe=$(file -b "$core" | sed -n "s/.*execfn: '\([^']*\)'.*/\1/p")
prog=$inst/bin/$(basename "${exe:-cub_server}")
[ -x "$prog" ] || { echo "gdb-core: $prog is not in the install" >&2; exit 1; }

gdb -batch -ex 'info threads' -ex 'thread apply all bt 12' "$prog" "$core" > "$R/gdb-threads-bt.txt" 2>&1 || :
gdb -batch -ex 'bt full 12' "$prog" "$core" > "$R/gdb-bt-full.txt" 2>&1 || :

want=$(readelf -n "$prog" | awk '/Build ID/ { print $3 }')
threads=$(grep -c '^Thread ' "$R/gdb-threads-bt.txt" || :)
named=$(grep -cE '^#[0-9]+ .* at [^ ]*/src/[^ ]+:[0-9]+$' "$R/gdb-threads-bt.txt" || :)
locals=$(awk '/^#[0-9]+ .* at [^ ]*\/src\// { f = 1; next } /^#/ { f = 0 } f && /^        [a-z_A-Z][a-zA-Z0-9_]* = / && !/<optimized out>/' \
  "$R/gdb-bt-full.txt" | wc -l)
mismatch=$(grep -c 'warning: .*build.id\|does not match core file\|core file may not match' "$R/gdb-threads-bt.txt" || :)
verdict=PASS
[ "$threads" -gt 0 ] && [ "$named" -gt 0 ] && [ "$locals" -gt 0 ] && [ "$mismatch" -eq 0 ] || verdict=FAIL
{
  printf 'core\t%s (%s)\n' "$core" "$(file -b "$core" | cut -c1-120)"
  printf 'program\t%s (build ID %s)\n' "$prog" "$want"
  printf 'threads\t%s\n' "$threads"
  printf 'cubrid frames with file:line\t%s\n' "$named"
  printf 'locals shown in the crashing thread\t%s\n' "$locals"
  printf 'build ID warnings\t%s\n' "$mismatch"
  printf 'result\t%s\n' "$verdict"
} | tee "$R/gdb-verdict.tsv"
[ "$verdict" = PASS ]
