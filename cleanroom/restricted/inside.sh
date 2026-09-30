#!/usr/bin/env bash
# The restricted-cloud acceptance, inside the container that cleanroom/restricted/run.sh
# starts (ADR 0003). As this user, with the host's network only:
# install, activation in a new shell, the engine's sources, builds, a server, gdb on an
# external core, CTP samples, one shell case, then the same again.
# Each step writes ~/results/<step>.log and a line to ~/results/steps.tsv:
# PASS, FAIL, NOT RUN (with the reason), or the verdict a step reports itself.
# RESTRICTED_STEPS="<step> ..." runs only those steps.
set -uo pipefail
R=$HOME/results
mkdir -p "$R"
ENGINE_REV=${ENGINE_REV:-35f528e89f9918ec0ac1a272c0da4fec67c51078}
TC_REF=${TC_REF:-7bd8ebbc777d96964734a23ff8fd115e08594ce7}
N=$HOME/cubrid-nix
I=$N/.scratch/install/cubrid-optdebug-shell

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
  record "$name" "$v" "$(( t1 - t0 ))s, $(peak "$t0" "$t1")"
}
# the reason goes into the verdict; the step's exit status then does not matter
verdict() { echo "$2" > "$R/$1.verdict"; }
lsh() { bash -lc "$1"; }   # a login shell: ~/.profile sources env.sh (install.sh --profile)

facts() {
  echo "uname: $(uname -srm)"
  echo "id: $(id)"
  echo "nproc: $(nproc)"
  echo "cgroup cpu.max: $(cat /sys/fs/cgroup/cpu.max 2>&1)"
  echo "MemTotal: $(awk '/^MemTotal:/ { print $2 " kB" }' /proc/meminfo)"
  df -h / "$HOME" /var/tmp
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

engine() {
  git clone -q --shallow-since=2019-12-01 https://github.com/CUBRID/cubrid.git "$HOME/cubrid" &&
    git -C "$HOME/cubrid" checkout -q "$ENGINE_REV" &&
    git -C "$HOME/cubrid" submodule update -q --init &&
    git -C "$HOME/cubrid" log -1 --format='engine %H %cd %s' &&
    git -C "$HOME/cubrid" submodule status &&
    du -sh "$HOME/cubrid"
}

shell_build() {
  lsh "cd $N && make shell-build WORKTREE=$HOME/cubrid MODE=optdebug" &&
    du -sh "$HOME/cubrid/build_x86_64_optdebug" "$I" "$HOME/.cache/ccache" &&
    lsh "cd $N && nix develop -c ccache -s"
}

# a one-line change: the incremental build and ccache
rebuild() {
  echo '/* restricted rebuild */' >> "$HOME/cubrid/src/query/query_executor.c"
  lsh "cd $N && make shell-build WORKTREE=$HOME/cubrid MODE=optdebug"
  local rc=$?
  git -C "$HOME/cubrid" checkout -q src/query/query_executor.c
  return $rc
}

smoke() {
  lsh "cd $N && make smoke INSTALL=${1:-$I} NAME=restricted"
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
  lsh "nix build --no-link $inst && cd $N && nix develop -c scripts/gdb-core.sh $inst $core $R/gdb"
}

ctp_sql() {
  lsh "cd $N && make ctp SUITE=sql INSTALL=$I TC_REF=$TC_REF ONLY=_01_object/_04_trigger"
}

ctp_medium() {
  lsh "cd $N && make ctp SUITE=medium INSTALL=$I TC_REF=$TC_REF ONLY=_07_mc_dep"
}

shell_case() {
  [ -d /private-ex/shell ] || { verdict shell_case "NOT RUN (no private-ex checkout mounted at /private-ex)"; return 0; }
  lsh "cd $N && make shell-case INSTALL=$I CASE=_01_utility/_17_loaddb/bug_xdbms184 TESTCASES=/private-ex"
}

nix_build() {
  lsh "cd $N && make build WORKTREE=$HOME/cubrid MODE=optdebug" &&
    smoke "$N/.scratch/install/cubrid-optdebug"
}

# everything again in the same home: nothing is fetched twice and nothing is left over
rerun() {
  (cd "$N" && ./install.sh) | tee "$R/rerun-install.txt" &&
    ! grep -q '^fetching nix' "$R/rerun-install.txt" &&
    smoke && shell_case
}

disk() {
  du -sh "$HOME/.local/share/cubrid-nix/store" "$HOME/cubrid" "$HOME/.cache" "$N/.scratch" 2>&1
  df -h "$HOME"
}

step facts facts
step clone_repo clone_repo
step install_nix install_nix
step activate activate
step engine engine
step shell_build shell_build
step smoke smoke
step core_generation core_generation
step gdb_external gdb_external
step ctp_sql ctp_sql
step ctp_medium ctp_medium
step shell_case shell_case
step rebuild rebuild
step nix_build nix_build
step rerun rerun
step disk disk
