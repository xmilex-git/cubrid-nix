#!/usr/bin/env bash
# gdb on a kernel-written core of a running cub_server (ADR 0001 D10). The server runs
# in a private namespace: its ports stay private and every process ends with it. gdb
# reads the core offline (scripts/gdb-core.sh); it is never attached to a live server.
#   diag.sh <install> <results dir>      (inside `nix develop`)
set -euo pipefail
inst=$(readlink -f "${1:?usage: diag.sh <install> <results dir>}")
mkdir -p "${2:?usage: diag.sh <install> <results dir>}"
R=$(readlink -f "$2")
repo=${CUBRID_NIX_REPO:-$HOME/cubrid-nix}

exec unshare -Urmipnf --mount-proc --kill-child bash -s "$inst" "$R" "$repo" <<'EOF'
set -euo pipefail
inst=$1 R=$2 repo=$3
ip link set lo up
h=$(hostname)
printf '127.0.0.1\t%s localhost\n' "$h" > "$R/diag-hosts"
mount --bind "$R/diag-hosts" /etc/hosts
env=$("$repo/scripts/rundir.sh" "$inst" "$repo/.scratch/run/diag-$(date -u +%Y%m%dT%H%M%SZ)")
. "$env"
cd "$CUBRID/tmp"   # csql writes csql.err into its working directory
ulimit -c unlimited
mkdir -p "$CUBRID_DATABASES/diagdb"
(cd "$CUBRID_DATABASES/diagdb" && cubrid createdb --db-volume-size=64M --log-volume-size=64M diagdb en_US.utf8 </dev/null) \
  > "$R/diag-createdb.log" 2>&1
cubrid server start diagdb </dev/null > "$R/diag-server.log" 2>&1
csql -u dba diagdb -c "create table t1 (n int primary key); insert into t1 values (1),(2),(3),(4),(5),(6),(7),(8),(9),(10); create table t as select rownum as a, mod(rownum, 97) as b from t1 x1, t1 x2, t1 x3, t1 x4, t1 x5, t1 x6" </dev/null \
  > "$R/diag-data.log" 2>&1
pid=$(pgrep -x cub_server)
# a query in flight when the core is written
( csql -u dba diagdb -c "select count(*), sum(a.b) from t a, t1 x where a.b > x.n and a.a <= 200000" </dev/null ) > "$R/diag-load.log" 2>&1 &
sleep 2

# gdb: a core the kernel writes where core_pattern points. The server's fatal signal
# handler ignores a SIGSEGV that came from kill(2) (si_code <= 0, server.c crash_handler);
# in an optdebug build (asserts on) its SIGABRT handler ends in abort(), which dumps core.
pat=$(cat /proc/sys/kernel/core_pattern)
kill -ABRT "$pid"
# the kernel keeps the process until the core is written: wait until it is gone (or a zombie)
for i in $(seq 1 120); do
  st=$(awk '/^State:/ { print $2 }' "/proc/$pid/status" 2>/dev/null || true)
  case "$st" in ''|Z) break ;; esac
  sleep 1
done
core=$(ls -t "$(dirname "$pat")"/core.cub_server.* 2>/dev/null | head -1 || true)
if [ -n "${core:-}" ]; then
  echo "$core" > "$R/core-path.txt"
  "$repo/scripts/gdb-core.sh" "$inst" "$core" "$R" || true
else
  echo "no core under $(dirname "$pat") (core_pattern '$pat')" > "$R/core-path.txt"
fi
wait || true
cubrid service stop </dev/null > "$R/diag-stop.log" 2>&1 || true
EOF
