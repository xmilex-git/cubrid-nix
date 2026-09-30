#!/usr/bin/env bash
# One CTP shell case, run the way CTP's shell guide runs a single case (section 2.3) and
# CTP's Test.runTestCase_linux runs each case: `sh <case>.sh` in <case>/cases, with
# init_path, CTP_HOME and CUBRID_CHARSET set (ADR 0003 D8). It is not a suite runner.
#   shell-case.sh <install> <case dir> [cubrid-testcases-private-ex checkout]
# <case dir> is relative to the checkout's shell/ (e.g. _01_utility/_17_loaddb/bug_xdbms184)
# or absolute. The checkout defaults to $CUBRID_NIX_TESTCASES_EX.
# What the case writes goes to a fresh directory under .scratch/shell-case: a run directory
# of the install, a copy of CTP and a copy of the case at its path under shell/. The
# checkout and the install stay as they are.
# The case's `init test` and `finish` run `pkill cub` and remove every shared memory
# segment of the user. Where there are namespaces the case gets its own PID, IPC and
# network namespaces. Where there are none it refuses to start while this user has
# CUBRID processes or shared memory segments, or something listens on the conf's ports.
# PASS: <case>.result has an OK line and no NOK line, and afterwards no process, segment
# or listening port of the run is left and no database of the case is registered.
set -euo pipefail
usage="usage: shell-case.sh <install> <case dir> [cubrid-testcases-private-ex checkout]"
install=$(readlink -f "${1:?$usage}")
case_arg=${2:?$usage}
tc=${3:-${CUBRID_NIX_TESTCASES_EX:-}}
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { echo "shell-case: $*" >&2; exit 1; }
[ -n "${CUBRID_NIX_CTP:-}" ] || die "run it in the dev shell (nix develop)"

case "$case_arg" in
  /*) src=$case_arg
      case "$case_arg" in */shell/*) rel=${case_arg##*/shell/} ;; *) rel=$(basename "$case_arg") ;; esac ;;
  *) [ -n "$tc" ] || die "a relative case dir needs the private-ex checkout (third argument)"
     src=$tc/shell/$case_arg rel=$case_arg ;;
esac
src=$(cd "$src" && pwd)
rel=${rel%/}
name=$(basename "$src")
[ -f "$src/cases/$name.sh" ] || die "no $src/cases/$name.sh"

run=$repo/.scratch/shell-case/$name-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$run/shell/$(dirname "$rel")"
env=$("$repo/scripts/rundir.sh" "$install" "$run/CUBRID")
cp -r "$CUBRID_NIX_CTP" "$run/CTP"
cp -r "$src" "$run/shell/$rel"
chmod -R u+w "$run/CTP" "$run/shell"
cases=$run/shell/$rel/cases
conf=$run/CUBRID/conf
ports="$(sed -n 's/^[[:space:]]*cubrid_port_id[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$conf/cubrid.conf" | tail -1)"
ports="${ports:-1523} $(sed -n 's/^[[:space:]]*BROKER_PORT[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$conf/cubrid_broker.conf" | tr '\n' ' ')"
me=$(id -u)
procs() { pgrep -a -u "$me" cub || :; }
# the run's own processes: those whose CUBRID is the run directory
ours() {
  local p
  for p in /proc/[0-9]*; do
    { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -qx "CUBRID=$run/CUBRID" && echo "${p#/proc/}"
  done
  :
}
segments() { ipcs -m | awk -v u="$(id -un)" '$3 == u { print $2 }'; }
listening() { local p; for p in $ports; do ss -Hltn "sport = :$p" | grep -q . && echo "$p"; done; :; }

cat > "$run/run-case.sh" <<'EOF'
# $1 cubrid.env, $2 CTP_HOME, $3 <case>/cases, $4 <case>
. "$1"
export CTP_HOME=$2 init_path=$2/shell/init_path CUBRID_CHARSET=en_US
export PATH=$CTP_HOME/bin:$CTP_HOME/common/script:$PATH
ulimit -c unlimited 2>/dev/null || echo "(ulimit -c unlimited refused: no cores here)"
cd "$3"
echo > "$4.result"
# CTP runs `sh <case>.sh`; the CI images' sh is bash, and init.sh needs bash
exec bash "$4.sh" 2>&1
EOF
args=("$run/run-case.sh" "$env" "$run/CTP" "$cases" "$name")
timeout=${CUBRID_NIX_CASE_TIMEOUT:-1800}

direct=0
if unshare -Urmipnf --mount-proc true 2>/dev/null; then
  mode="own PID, IPC and network namespaces"
  printf '127.0.0.1\t%s localhost\n' "$(hostname)" > "$run/hosts"
  set +e
  timeout "$timeout" unshare -Urmipnf --mount-proc --kill-child bash -c \
    'ip link set lo up && mount --bind "$1" /etc/hosts && mount -t tmpfs tmpfs /dev/shm && shift && exec bash "$@"' \
    _ "$run/hosts" "${args[@]}" > "$run/case.log" 2>&1
  rc=$?
  set -e
else
  direct=1
  mode="direct (no namespaces here)"
  t=$(procs); [ -z "$t" ] || die "this user runs CUBRID processes, which the case's pkill cub would kill:"$'\n'"$t"
  t=$(segments); [ -z "$t" ] || die "this user has shared memory segments, which the case's finish removes: $t"
  t=$(listening); [ -z "$t" ] || die "ports of the run's conf are in use: $t"
  set +e
  timeout "$timeout" bash "${args[@]}" > "$run/case.log" 2>&1
  rc=$?
  set -e
fi

ok=$(grep -c ' : OK' "$cases/$name.result" || :)
nok=$(grep -c ' : NOK' "$cases/$name.result" || :)
result=FAIL
[ "$ok" -gt 0 ] && [ "$nok" -eq 0 ] && [ "$rc" -ne 124 ] && result=PASS
# What the case left behind, which goes now. Only the run's own processes are looked
# at; segments and ports only without namespaces, where the case had none before it.
left=""
t=$(ours); [ -z "$t" ] || { left+=" processes:[$(echo $t)]"; kill -9 $t 2>/dev/null || :; }
if [ "$direct" = 1 ]; then
  t=$(segments); [ -z "$t" ] || { left+=" segments:[$(echo $t)]"; for s in $t; do ipcrm -m "$s" || :; done; }
  t=$(listening); [ -z "$t" ] || left+=" ports:[$(echo $t)]"
fi
t=$(grep -v '^#' "$run/CUBRID/databases/databases.txt" 2>/dev/null | awk 'NF { print $1 }' | tr '\n' ' ' || :)
[ -z "$t" ] || left+=" databases:[${t% }]"
[ -z "$left" ] || result=FAIL

{
  printf 'case\t%s (%s)\n' "$rel" "$(git -C "$src" log -1 --format='%h %cd' --date=short 2>/dev/null || echo 'not a git checkout')"
  printf 'install\t%s\n' "$install"
  printf 'engine\t%s\n' "$(. "$env" && cubrid_rel 2>/dev/null | grep -m1 -o 'CUBRID.*' || echo unknown)"
  printf 'ctp\t%s\n' "${CUBRID_NIX_CTP_REV:-unknown}"
  printf 'mode\t%s\n' "$mode"
  printf 'exit\t%s%s\n' "$rc" "$([ "$rc" -ne 124 ] || echo " (timed out after ${timeout}s)")"
  printf 'result\t%s (OK %s, NOK %s)\n' "$result" "$ok" "$nok"
  printf 'cleanup\t%s\n' "${left:-nothing left}"
  printf 'log\t%s\n' "$run/case.log"
} | tee "$run/verdict.tsv"
[ "$result" = PASS ]
