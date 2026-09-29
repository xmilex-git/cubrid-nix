#!/usr/bin/env bash
# Server smoke on a run directory (ADR 0001 D2): create a database, start the server,
# run a query and a PL/CSQL function (the PL server and its JVM), stop everything.
# Run it where ports are private (a container or a network namespace): it uses the
# install's default port. `cubrid server ...` output goes to a file, never a pipe
# (captured through a pipe it hangs).
set -euo pipefail

. "${1:?usage: smoke.sh <run dir>/cubrid.env [db]}"
db=${2:-smokedb}
log=$CUBRID/log/smoke.log
sql=$CUBRID/tmp/smoke.sql

echo "stored_procedure=yes" >> "$CUBRID/conf/cubrid.conf"
mkdir -p "$CUBRID_DATABASES/$db"
(cd "$CUBRID_DATABASES/$db" && cubrid createdb --db-volume-size=64M --log-volume-size=64M "$db" en_US.utf8 </dev/null)

cubrid server start "$db" </dev/null >>"$log" 2>&1 || { tail -20 "$log"; exit 1; }
trap 'cubrid server stop "$db" </dev/null >>"$log" 2>&1; cubrid service stop </dev/null >>"$log" 2>&1' EXIT

csql -u dba "$db" -c "select 1 + 1 as two" </dev/null

cat > "$sql" <<'EOF'
create or replace function smoke_f (a int) return int as
begin
  return a * 6;
end;
select smoke_f (7) as pl_result;
EOF
csql -u dba "$db" -i "$sql" </dev/null | tee "$CUBRID/tmp/smoke-pl.out"
grep -q '42' "$CUBRID/tmp/smoke-pl.out" || { echo "smoke: PL/CSQL did not return 42" >&2; exit 1; }
echo "smoke: ok"
