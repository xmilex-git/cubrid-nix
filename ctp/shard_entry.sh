#!/usr/bin/env bash
# One CTP shard inside its own namespaces (ADR 0001 D8). ctp_run.sh starts it as
#   unshare -Urmipnf --mount-proc --kill-child bash shard_entry.sh <shard dir>
# and writes the shard's settings to <shard dir>/shard.env.
#
# CTP's teardown runs `pkill cub` and kills every process of the user; in these PID,
# network, mount and IPC namespaces it reaches only this shard. The shard is laid out
# at the CI container's paths (/home/CUBRID, /home/cubrid-testtools/CTP,
# /home/<testcases repo>, /home/CUBRID_DB, /home/reports), so the stock CTP confs work
# unchanged, then this runs what the cubridci entrypoint's `test` runs for sql and
# medium: derive the runtime conf, narrow it to the shard's scenario, ctp.sh, collect
# the JUnit XML, judge.
set -euo pipefail

d=${1:?usage: shard_entry.sh <shard dir>}
# ctp_run.sh starts this with an empty environment (exec -c): nothing of the caller's
# (its CUBRID_TMP or LD_LIBRARY_PATH, credentials) reaches CTP; shard.env holds all.
# shellcheck source=/dev/null
. "$d/shard.env"
export PATH=$TOOLS_PATH

# Everything the shard prints goes to console.log and, with a timestamp per line, to
# console.ts.log (the runner's hang watchdog and timing read them). PID 1's exit kills
# the whole namespace, so the exit trap waits for the filter to write the last lines.
# The logs are opened here, not by path per line: with the shard under /home, the tmpfs
# mounted on /home below hides that path from this mount namespace.
exec 3>> "$d/console.log" 4>> "$d/console.ts.log"
exec > >(while IFS= read -r line; do
           printf '%s\n' "$line" >&3
           printf '%(%Y-%m-%dT%H:%M:%S%z)T %s\n' -1 "$line" >&4
         done) 2>&1
filter=$!
exec 3>&- 4>&-
trap 'exec >&- 2>&-; wait "$filter" 2>/dev/null' EXIT

step() { printf '[shard] %s %s\n' "$(date -u +%FT%T.%3NZ)" "$*"; }
die() { step "FAILED: $*"; exit 90; }

# --- layout ------------------------------------------------------------------------
if [ "$DIRECT" = 1 ]; then
  # No namespaces here (ctp_run.sh ran one shard directly): the CI layout is made of
  # symlinks under <shard>/home, and the unix sockets go to a short private directory
  # (CUBRID's socket paths are limited to 108 bytes).
  top=$d/home
  mkdir -p "$top/cubrid-testtools"
  ln -sfn ../CUBRID "$top/CUBRID"
  ln -sfn ../../CTP "$top/cubrid-testtools/CTP"
  ln -sfn ../testcases "$top/$TCREPO"
  ln -sfn ../CUBRID_DB "$top/CUBRID_DB"
  ln -sfn ../reports "$top/reports"
  export CUBRID_TMP TMPDIR=$d/tmp
  mkdir -p "$TMPDIR"
  CUBRID_TMP=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/cn.XXXXXX")
  step "direct layout at $top (no namespaces), CUBRID_TMP=$CUBRID_TMP"
else
  # --- namespaces ------------------------------------------------------------------
  # CUBRID's server reaches its master through the host name, which must resolve to
  # this namespace's loopback; POSIX shm names carry pids, which repeat across PID
  # namespaces (workspace fast-gate lessons).
  ip link set lo up || die "lo up"
  h=$(hostname)
  { printf '127.0.0.1\t%s localhost\n::1\tlocalhost\n' "$h"
    grep -v -w -F -e "$h" -e localhost /etc/hosts 2>/dev/null || true; } > "$d/hosts"
  mount --bind "$d/hosts" /etc/hosts || die "private /etc/hosts"
  mount -t tmpfs -o "size=$SHM_SIZE,mode=1777" tmpfs /dev/shm || die "private /dev/shm"
  # core_pattern is resolved in the crashing process's mount namespace
  if [ -n "$CORE_DIR" ]; then
    mount --bind "$d/cores/" "$CORE_DIR" || die "core dir $CORE_DIR"
  fi

  # The run directory names the install by its absolute path (its links and wrappers).
  # The mounts below cover /mnt, /tmp and /home, so an install under one of them (a
  # `make shell-build` prefix in the home directory) rides along in the shard dir and
  # is bound back at its own path once the layout is up.
  case "$INSTALL" in
    /home/*|/mnt/*|/tmp/*) install_covered=1 ;;
    *) install_covered=0 ;;
  esac
  if [ "$install_covered" = 1 ]; then
    mkdir -p "$d/install" && mount --bind "$INSTALL" "$d/install" || die "stage the install $INSTALL"
  fi

  # The CI container's layout. The shard dir is staged on /mnt first: the tmpfs on /home
  # would hide it when it lives under /home. --rbind carries the staged install along.
  mount --rbind "$d" /mnt || die "stage the shard on /mnt"
  d=/mnt   # $d may be under /home, which the tmpfs below hides
  # a private /tmp on the shard's disk, as the CI container has its own
  mkdir -p /mnt/tmp && mount --bind /mnt/tmp /tmp || die "private /tmp"
  mount -t tmpfs -o mode=755 tmpfs /home || die "tmpfs /home"
  mkdir -p /home/CUBRID /home/cubrid-testtools/CTP "/home/$TCREPO" /home/CUBRID_DB /home/reports
  mount --bind /mnt/CUBRID /home/CUBRID
  mount --bind /mnt/CTP /home/cubrid-testtools/CTP
  mount --bind /mnt/testcases "/home/$TCREPO"
  mount --bind /mnt/CUBRID_DB /home/CUBRID_DB
  mount --bind /mnt/reports /home/reports
  if [ "$install_covered" = 1 ]; then
    mkdir -p "$INSTALL" && mount --bind /mnt/install "$INSTALL" || die "bind the install back at $INSTALL"
  fi
  # sql/medium create basic/mdb under $CUBRID/databases (run.sh: cubrid_root_dir=$CUBRID).
  # With the volatile option every fsync there returns at once; the database is thrown
  # away with the shard (workspace ADR 0017 D7).
  if [ "$VOLATILE" = 1 ]; then
    mkdir -p /mnt/volatile/up /mnt/volatile/work
    mount -t overlay overlay \
      -o "lowerdir=/home/CUBRID/databases,upperdir=/mnt/volatile/up,workdir=/mnt/volatile/work,volatile,userxattr" \
      /home/CUBRID/databases || die "volatile overlay on /home/CUBRID/databases"
  fi
  step "namespaces ready (host $h, volatile=$VOLATILE, core dir ${CORE_DIR:-none})"
  top=/home
fi

# --- the CI test image's environment --------------------------------------------------
export HOME=$top WORKDIR=$top CUBRID=$top/CUBRID CTP_HOME=$top/cubrid-testtools/CTP
export CUBRID_DATABASES=$top/CUBRID_DB TEST_REPORT=$top/reports
# The master's unix socket defaults to /tmp/CUBRID<port>, which every shard shares (same
# ports in every shard): a second master unlinks the first one's socket. Keep it in the
# shard (the direct layout has its own CUBRID_TMP above).
[ "$DIRECT" = 1 ] || export CUBRID_TMP=$CUBRID/var/CUBRID_SOCK
# LOCALE_ARCHIVE first: bash resolves LC_ALL=en_US itself, from this archive
export JAVA_HOME TZDIR LOCALE_ARCHIVE
export TZ=Asia/Seoul LANG=en_US.UTF-8 LC_ALL=en_US CTP_SKIP_UPDATE=1 CTP_BRANCH_NAME=develop
export USER LOGNAME
USER=$(id -un); LOGNAME=$USER
export PATH="$CUBRID/bin:$CTP_HOME/bin:$CTP_HOME/common/script:$TOOLS_PATH"
if [ -n "${EXTRA_ENV:-}" ]; then
  while IFS= read -r kv; do [ -z "$kv" ] || export "${kv?}"; done <<< "$EXTRA_ENV"
fi
ulimit -c 10485760 2>/dev/null || true
# Without a volatile overlay, fsync goes through eatmydata (ADR 0001 D8). The library is
# built against the snapshot's glibc 2.28, so it loads into CUBRID and nix programs alike.
if [ -n "$EATMYDATA" ]; then
  export LD_PRELOAD="$EATMYDATA${LD_PRELOAD:+:$LD_PRELOAD}"
fi

# --- the cubridci entrypoint's `test` for sql and medium ------------------------------
case "$SUITE" in
  sql)    CTP_CMD=sql;    CONF_SRC=conf/sql.conf;        CTP_CONF=conf/sql_runtime.conf ;;
  medium) CTP_CMD=medium; CONF_SRC=conf/medium_dev.conf; CTP_CONF=conf/medium_runtime.conf ;;
  *) die "suite '$SUITE' is out of scope (ADR 0001 D2)" ;;
esac
XML_SRC=$CTP_HOME/sql/result
conf=$CTP_HOME/$CTP_CONF

set_conf_key() {
  local key=$1 val=$2 esc
  esc=${val//\\/\\\\}; esc=${esc//&/\\&}; esc=${esc//|/\\|}
  sed -i "s|^$key[[:space:]]*=.*|$key=$esc|" "$conf"
  grep -qxF "$key=$val" "$conf" || die "$CTP_CONF lacks '$key=$val'; check the CTP conf upstream"
}

cp -f "$CTP_HOME/$CONF_SRC" "$conf" || die "cannot derive $CTP_CONF from $CONF_SRC"
set_conf_key scenario "$top/$TCREPO/$SUBPATH"
exclude=${EXCLUDE_NAME:+$CTP_HOME/conf/$EXCLUDE_NAME}
set_conf_key testcase_exclude_from_file "$exclude"
step "conf: $CTP_CONF <- $CONF_SRC, scenario=$top/$TCREPO/$SUBPATH exclude=${exclude:-(none)}"

[ -x "$CUBRID/bin/cubrid_rel" ] || die "no CUBRID at $CUBRID"
step "cubrid_rel: $(cubrid_rel 2>&1 | tr -s '\n' ' ')"

run_stamp=$d/.run_stamp
: > "$run_stamp"
ctp_ret=0
# ctp.sh says #!/bin/sh but uses ${PIPESTATUS[0]}: where /bin/sh is dash (Debian, Ubuntu) it
# dies with "Bad substitution" and exit 2 once the run is over, so bash runs it.
( cd "$top" && "$BASH" "$CTP_HOME/bin/ctp.sh" "$CTP_CMD" -c "$conf" ) || ctp_ret=$?

# collect_xml
n=0
while IFS= read -r x; do
  cp -f "$x" "$TEST_REPORT/" && n=$((n + 1))
done < <(find -L "$XML_SRC" -type f -name '*.xml' ! -name 'summary.xml' -newer "$run_stamp" 2>/dev/null)
step "collected $n JUnit XML file(s) into $TEST_REPORT"

[ "$ctp_ret" -eq 0 ] || die "CTP exited with $ctp_ret"

# judge_sqlresult
summary_infos=$(find "$XML_SRC" -type f -name summary_info -newer "$run_stamp" 2>/dev/null || true)
[ -n "$summary_infos" ] || die "no summary_info under $XML_SRC; nothing was tested"
failed=$(echo "$summary_infos" | xargs -n1 grep -hw nok | awk -F: '{print $1}' || true)
if [ -n "$failed" ]; then
  echo "** There are $(echo "$failed" | wc -l) failed Testcases on this test."
  echo "** All failed Testcases are listed below:"
  echo "$failed" | sed "s|.*$top/$TCREPO/| - |"
  exit 1
fi
echo "** All Tests are passed"
