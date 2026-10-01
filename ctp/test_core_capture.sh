#!/usr/bin/env bash
# Regression test of ctp_run.sh's setup_core_capture (ADR 0003 D13): every form of
# /proc/sys/kernel/core_pattern, and a file that is missing or cannot be read, under the
# runner's own `set -euo pipefail`. The function is taken from ctp_run.sh as it is, with
# the file's path pointed at a fixture; the runner's globals start as ctp_run.sh sets them.
#   test_core_capture.sh     one line per case; the exit status is the number of failures
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$here/../.scratch/test-core-capture
mkdir -p "$work"
fn=$(sed -n '/^setup_core_capture() {$/,/^}$/p' "$here/ctp_run.sh")
[ -n "$fn" ] || { echo "setup_core_capture not found in ctp_run.sh" >&2; exit 1; }
failures=0

# name, fixture (text, or <missing>, <eacces>, <directory>), expected CORE_MODE|CORE_DIR
check() {
  local name=$1 fixture=$2 want=$3 f=$work/$1 got rc
  rm -rf "${f:?}"
  case "$fixture" in
    "<missing>") ;;
    "<eacces>")
      if [ "$(id -u)" = 0 ]; then echo "SKIP  $name (root reads a mode-000 file)"; return; fi
      printf '/var/tmp/core.%%e\n' > "$f"; chmod 000 "$f" ;;
    "<directory>") mkdir "$f" ;;
    *) printf '%s\n' "$fixture" > "$f" ;;
  esac
  rc=0
  got=$(bash -euo pipefail -c '
    info() { :; }; warn() { :; }; err() { :; }
    CORE_MODE="none"; CORE_DIR=""
    eval "$1"
    setup_core_capture
    printf "%s|%s" "$CORE_MODE" "$CORE_DIR"' _ "${fn//\/proc\/sys\/kernel\/core_pattern/$f}") || rc=$?
  if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then
    echo "PASS  $name -> $got"
  else
    echo "FAIL  $name -> '${got}' (exit $rc), want '$want'"
    failures=$((failures + 1))
  fi
  [ ! -e "$f" ] || chmod -R u+rwx "$f"
}

check missing     "<missing>"                              "none|"
check eacces      "<eacces>"                               "none|"
check directory   "<directory>"                            "none|"
check empty       ""                                       "none|"
check pipe        "|/usr/lib/systemd/systemd-coredump %P"  "pipe|"
check absolute    "/var/tmp/cores/core.%e.%p.%h.%t"        "path|/var/tmp/cores"
check relative    "core.%e.%p"                             "relative|"
exit "$failures"
