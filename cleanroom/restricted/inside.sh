#!/usr/bin/env bash
# The restricted-cloud acceptance, inside the container that cleanroom/restricted/run.sh
# starts (ADR 0003), as this user with no privileges. The repositories live in
# /workspace/<name>, as in the target: the engine with its whole history, cubrid-testcases
# at its develop, cubrid-nix cloned from its committed HEAD.
# Each step writes ~/results/<step>.log and a line to ~/results/steps.tsv: PASS, FAIL,
# NOT RUN (with the reason), or the verdict a step reports itself. RESTRICTED_STEPS="<step>
# ..." runs only those steps. The exit status is 1 when a step failed.
set -uo pipefail
R=$HOME/results
mkdir -p "$R"
W=/workspace
N=$W/cubrid-nix E=$W/cubrid TC=$W/cubrid-testcases
ENGINE_REF=${ENGINE_REF:-develop}
TC_REF=${TC_REF:-develop}
I=$N/.scratch/install/cubrid-optdebug-shell
IR=$N/.scratch/install/cubrid-release-shell
failed=0
# git runs its automatic maintenance detached after a fetch: it would end as an orphan of
# PID 1, which reaps nothing here (ADR 0003 D12)
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=gc.autoDetach GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=maintenance.autoDetach GIT_CONFIG_VALUE_1=false

# Memory is not limited here: every 2 s, the time, the RSS of all processes and of the
# largest one, in KiB. A sum of RSS counts shared pages once per process: an upper bound.
( while :; do
    awk -v t="$(date +%s)" '{ s += $2; if ($2 > m) m = $2 } END { print t, s * 4, m * 4 }' /proc/[0-9]*/statm 2>/dev/null
    sleep 2
  done ) >> "$R/rss.tsv" &
sampler=$!
trap 'kill $sampler 2>/dev/null' EXIT
peak() {
  awk -v a="$1" -v b="$2" '$1 >= a && $1 <= b { if ($2 > s) s = $2; if ($3 > m) m = $3 }
    END { printf "peak RSS %.1f GiB, largest process %.1f GiB", s / 1048576, m / 1048576 }' "$R/rss.tsv"
}

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" | tee -a "$R/steps.tsv"; }
step() {
  local name=$1 t0 t1 rc v
  shift
  if [ -n "${RESTRICTED_STEPS:-}" ] && [[ " $RESTRICTED_STEPS " != *" $name "* ]]; then return 0; fi
  echo "=== $name $(date -u +%FT%TZ)"
  t0=$(date +%s)
  rm -f "$R/$name.verdict"
  "$@" > "$R/$name.log" 2>&1
  rc=$?
  t1=$(date +%s)
  if [ -s "$R/$name.verdict" ]; then v=$(cat "$R/$name.verdict")
  elif [ "$rc" = 0 ]; then v=PASS
  else v="FAIL (exit $rc)"; fi
  case "$v" in FAIL*) failed=1 ;; esac
  record "$name" "$v" "$(( t1 - t0 ))s, $(peak "$t0" "$t1")"
}
# the reason goes into the verdict; the step's exit status then does not matter
verdict() { echo "$2" > "$R/$1.verdict"; }
lsh() { bash -lc "$1"; }   # a login shell: ~/.profile sources env.sh (install.sh --profile)

# what the container holds now, without procps: "pid state ppid comm" per process
proc_table() {
  local f l rest
  for f in /proc/[0-9]*/stat; do
    read -r l < "$f" 2>/dev/null || continue
    rest=${l##*) }
    set -- $rest
    l=${l#*(}
    printf '%s %s %s %s\n' "${f//[^0-9]/}" "$1" "$2" "${l%)*}"
  done
}
zombie_count() { proc_table | awk '$2 == "Z"' | wc -l; }
listening_ports() {
  local f st addr
  for f in /proc/net/tcp /proc/net/tcp6; do
    while read -r _ addr _ st _; do
      [ "$st" = 0A ] && printf '%d ' "$((16#${addr##*:}))"
    done < <(tail -n +2 "$f" 2>/dev/null)
  done
}
shm_segments() { tail -n +2 /proc/sysvipc/shm 2>/dev/null | wc -l; }

facts() {
  echo "uname: $(uname -srm)"
  echo "id: $(id)"
  echo "PID 1: $(tr '\0' ' ' < /proc/1/cmdline)"
  echo "nproc: $(nproc)"
  echo "cgroup cpu.max: $(cat /sys/fs/cgroup/cpu.max 2>&1)"
  echo "MemTotal: $(awk '/^MemTotal:/ { print $2 " kB" }' /proc/meminfo)"
  df -h / "$HOME" /var/tmp "$W"
  unshare -U true 2>&1 && echo "user namespaces: yes" || echo "user namespaces: no"
  echo "RLIMIT_CORE: $(ulimit -c) (hard $(ulimit -Hc))"
  echo "core_pattern: [$(cat /proc/sys/kernel/core_pattern 2>&1)]"
  mkdir /nix 2>&1 || :
  for t in gcc g++ make java git curl nix gdb cmake ninja javac just; do
    printf '%s: %s\n' "$t" "$(command -v "$t" || echo absent)"
  done
  gcc --version | head -1
  make --version | head -1
  java -version 2>&1 | head -1
  echo "malloc.h: $(ls -l /usr/include/malloc.h 2>&1)"
}

clone_repo() {
  git clone -q /src/cubrid-nix "$N" && git -C "$N" log -1 --format='cubrid-nix %H %s'
}

install_nix() {
  cd "$N" && ./install.sh --profile && du -sh "$HOME/.local/share/cubrid-nix"
}

activate() {
  local check='command -v nix && nix --version && [ "$(nix eval --raw --expr builtins.storeDir)" = /var/tmp/cubrid-nix/store ] && echo activated'
  lsh "$check" || return 1
  # a fresh /var/tmp: the next shell makes the link again
  rm /var/tmp/cubrid-nix && lsh "$check" && ls -l /var/tmp/cubrid-nix
}

# the whole history (build.sh numbers the version by commits) and every submodule
engine() {
  git clone -q https://github.com/CUBRID/cubrid.git "$E" &&
    git -C "$E" checkout -q "$ENGINE_REF" &&
    git -C "$E" submodule update -q --init &&
    echo "shallow: $(git -C "$E" rev-parse --is-shallow-repository), commits: $(git -C "$E" rev-list --count HEAD)" &&
    git -C "$E" log -1 --format='engine %H %cd %s' &&
    git -C "$E" submodule status &&
    du -sh "$E"
}

testcases() {
  git clone -q --filter=blob:none -b "$TC_REF" https://github.com/CUBRID/cubrid-testcases.git "$TC" &&
    git -C "$TC" log -1 --format='testcases %H %cd %s' &&
    du -sh "$TC"
}

# the runner's core capture against every form of core_pattern, and this container's own
core_capture_test() {
  echo "this container: core_pattern [$(cat /proc/sys/kernel/core_pattern 2>&1)]"
  lsh "cd $N && nix develop -c bash ctp/test_core_capture.sh"
}

# PID 1 here reaps nothing: an orphan that exits stays a zombie, unless scripts/reap.py
# is its subreaper
reaper_control() {
  local z0 z1 z2
  z0=$(zombie_count)
  bash -c '(sleep 0.3 &); exit 0'; sleep 1
  z1=$(zombie_count)
  lsh "cd $N && nix develop -c scripts/reap.py -- bash -c '(sleep 0.3 &); exit 0'"; sleep 1
  z2=$(zombie_count)
  echo "zombies: $z0 before, $z1 after an orphan without the reaper, $z2 after one under it"
  echo "$z1" > "$R/zombies.baseline"
  if [ "$z1" -gt "$z0" ] && [ "$z2" -eq "$z1" ]; then
    verdict reaper_control "PASS (without the reaper an orphan became a zombie of PID 1; under it, none)"
  else
    verdict reaper_control "FAIL (zombies $z0 -> $z1 without, -> $z2 with the reaper)"
  fi
}

shell_build() {
  lsh "cd $N && make shell-build WORKTREE=$E MODE=${1:-optdebug}" &&
    du -sh "$E/build_x86_64_${1:-optdebug}" "$N/.scratch/install/cubrid-${1:-optdebug}-shell" "$HOME/.cache/ccache"
}
shell_build_release() { shell_build release; }

smoke() {
  lsh "cd $N && make smoke INSTALL=${1:-$I} NAME=restricted"
}
smoke_release() { smoke "$IR"; }

# a one-line change: the incremental build and ccache
rebuild() {
  echo '/* restricted rebuild */' >> "$E/src/query/query_executor.c"
  lsh "cd $N && make shell-build WORKTREE=$E MODE=optdebug"
  local rc=$?
  git -C "$E" checkout -q src/query/query_executor.c
  return $rc
}

# where the kernel cannot write cores
core_generation() {
  ulimit -c unlimited 2>&1 && echo "RLIMIT_CORE raised" || echo "RLIMIT_CORE cannot be raised"
  echo "core_pattern: [$(cat /proc/sys/kernel/core_pattern 2>&1)]"
  mkdir -p "$R/core-probe" && cd "$R/core-probe" || return 1
  bash -c 'kill -SEGV $$'
  echo "a process killed by SIGSEGV left: $(ls -A | tr '\n' ' ')"
  if [ -z "$(ls -A)" ] && [ "$(ulimit -Hc)" = 0 ]; then
    verdict core_generation "IMPOSSIBLE (RLIMIT_CORE hard 0, no core written)"
  else
    verdict core_generation "POSSIBLE (see the log)"
  fi
}

# a core made elsewhere by an install the binary cache serves (ADR 0003 D9)
gdb_external() {
  local core inst
  core=$(ls /core/core.* 2>/dev/null | head -1)
  [ -n "$core" ] && [ -r /core/install-path ] || { verdict gdb_external "NOT RUN (no external core mounted at /core)"; return 0; }
  inst=$(cat /core/install-path)
  lsh "nix build --no-link $inst && cd $N && nix develop -c scripts/reap.py -- scripts/gdb-core.sh $inst $core $R/gdb"
}

# A CTP run, then its counts and what it left behind. Assigned is what the runner split
# out of the ONLY dirs; CTP's total is what it executed; skipped = total - passed - failed;
# not run = assigned - total. PASS needs no failure, nothing skipped or not run, and no
# process, port, shared memory segment or database volume left.
ctp_run() {
  local suite=$1 only=$2 name=$3 rc out line fail succ total cores exp skipped notrun left=""
  lsh "cd $N && CUBRID_NIX_TESTCASES=$TC make ctp SUITE=$suite INSTALL=$I TC_REF=$TC_REF ONLY=$only"
  rc=$?
  out=$(ls -dt "$N/.scratch/ctp/$suite-"* 2>/dev/null | head -1)
  line=$(grep -E '^  ALL ' "$R/$name.log" | tail -1)
  if [ -z "$line" ]; then
    verdict "$name" "FAIL (exit $rc, no result: the run did not reach its cases)"
    return 1
  fi
  read -r _ _ fail succ total cores exp <<< "$line"
  skipped=$(( total - succ - fail )) notrun=$(( exp - total ))
  [ "$(proc_table | awk '$4 ~ /^cub/' | wc -l)" = 0 ] || left+=" processes:$(proc_table | awk '$4 ~ /^cub/ { printf "%s(%s) ", $1, $4 }')"
  [ -z "$(listening_ports)" ] || left+=" ports:$(listening_ports)"
  [ "$(shm_segments)" = 0 ] || left+=" shm:$(shm_segments)"
  [ -z "$out" ] || [ "$(find "$out" -name '*_lgat' 2>/dev/null | wc -l)" = 0 ] || left+=" db-volumes:$(find "$out" -name '*_lgat' | wc -l)"
  grep -q '^reap.py: ' "$R/$name.log" && left+=" (the reaper stopped: $(grep '^reap.py: ' "$R/$name.log" | head -1))"
  local counts="assigned $exp, executed $((succ + fail)), passed $succ, failed $fail, skipped $skipped, not run $notrun, cores $cores"
  echo "counts: $counts"
  echo "left: ${left:-nothing}"
  echo "out: $out"
  if [ "$rc" = 0 ] && [ "$fail" = 0 ] && [ "$skipped" = 0 ] && [ "$notrun" = 0 ] && [ -z "$left" ]; then
    verdict "$name" "PASS ($counts; nothing left)"
  else
    verdict "$name" "FAIL (exit $rc; $counts; left:${left:- nothing})"
  fi
}
ctp_sql() { ctp_run sql _01_object/_04_trigger ctp_sql; }
ctp_medium() { ctp_run medium _07_mc_dep ctp_medium; }

shell_case() {
  [ -d /private-ex/shell ] || { verdict shell_case "NOT RUN (no private-ex checkout mounted at /private-ex)"; return 0; }
  lsh "cd $N && make shell-case INSTALL=$I CASE=_01_utility/_17_loaddb/bug_xdbms184 TESTCASES=/private-ex"
}

nix_build() {
  lsh "cd $N && make build WORKTREE=$E MODE=optdebug" &&
    smoke "$N/.scratch/install/cubrid-optdebug"
}

# everything again in the same home: nothing is fetched twice and nothing is left over
rerun() {
  (cd "$N" && ./install.sh) | tee "$R/rerun-install.txt" &&
    ! grep -q '^fetching nix' "$R/rerun-install.txt" &&
    smoke
}

# after everything: zombies beyond the control's, and processes PID 1 adopted
zombies() {
  local base now adopted
  base=$(cat "$R/zombies.baseline" 2>/dev/null || echo 0)
  proc_table > "$R/procs-final.txt"
  now=$(awk '$2 == "Z"' "$R/procs-final.txt" | wc -l)
  adopted=$(awk '$3 == 1 && $2 != "Z" { printf "%s(%s) ", $1, $4 }' "$R/procs-final.txt")
  echo "zombies: $now (the reaper control left $base); running processes adopted by PID 1: ${adopted:-none}"
  [ "$now" -le "$base" ] && [ -z "$adopted" ]
}

disk() {
  du -sh "$HOME/.local/share/cubrid-nix/store" "$E" "$TC" "$HOME/.cache" "$N/.scratch" 2>&1
  df -h "$HOME" "$W"
}

step facts facts
step clone_repo clone_repo
step install_nix install_nix
step activate activate
step engine engine
step testcases testcases
step core_capture_test core_capture_test
step reaper_control reaper_control
step shell_build shell_build
step smoke smoke
step shell_build_release shell_build_release
step smoke_release smoke_release
step core_generation core_generation
step gdb_external gdb_external
step ctp_sql ctp_sql
step ctp_medium ctp_medium
step shell_case shell_case
step rebuild rebuild
step nix_build nix_build
step rerun rerun
step zombies zombies
step disk disk
exit "$failed"
