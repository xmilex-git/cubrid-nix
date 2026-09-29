#!/usr/bin/env bash
#
# ctp_run.sh — the CUBRID CTP runner of cubrid-nix: one suite, N isolated shards.
#
# Ported from xmilex-git/workspace .agents/skills/ctp-run (commit e704976), where each
# shard is a rootless podman container of the CI image. Here each shard is a set of
# namespaces (`unshare -Urmipnf --mount-proc`, ADR 0001 D8) inside the nix environment:
# ctp/shard_entry.sh lays the shard out at the CI container's paths and runs what the
# cubridci entrypoint's `test` runs. Planning, weights, the plan pin, colocation,
# exclusions, the watchdogs, provenance and the merged report are unchanged.
#
# Suites: sql | medium (ADR 0001 D2; shell and ha_shell are out of scope). A shard's
# slice of the suite is MATERIALIZED (only its own cases exist in its scenario copy),
# so CTP needs no giant exclusion list; results are merged into one pass/fail summary.
#
# Isolation is the whole point: CTP's teardown runs `pkill cub` / kills every
# process of the running user, so a host-side run destroys other sessions'
# servers. In a shard's PID namespace that kill reaches only the shard.
#
# Port isolation is by namespace, NOT by reassignment: every shard reuses the SAME
# ports/SHM IDs from the CTP conf; the net + IPC + mount namespaces keep them from
# colliding.
#
# Copyright (c) 2024 CUBRID test-infra. Apache-2.0.

set -euo pipefail

#####################################################################
# Constants — the CI container's paths, which shard_entry.sh recreates inside each
# shard's mount namespace (NOT host paths).
#####################################################################
# These are dictated by the cubridci entrypoint, not chosen by us: it runs CTP with
# HOME=$WORKDIR and the stock confs resolve ${HOME}/<tc repo> and ${CTP_HOME}, so the
# shard layout must land exactly here for an unmodified CTP conf to be correct.
readonly C_WORKDIR="/home"
readonly C_CUBRID="/home/CUBRID"
readonly C_CTP="/home/cubrid-testtools/CTP"
C_DB="/home/CUBRID_DB" # HA resolves this below to match CTP cleanup paths.
readonly C_REPORT="/home/reports"
C_SCN=""          # scenario root inside the container; set by resolve_suite
C_TCREPO=""       # testcases repo mount point inside the container

SELF="$(basename "$0")"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SELF_DIR/.." && pwd)"
# This runner has no install overlay mode: every shard gets a run directory.
readonly ARG_OVERLAY=0

#####################################################################
# Tiny helpers
#####################################################################
info()  { printf '[ctp-run] %s\n' "$*"; }
warn()  { printf '[ctp-run] WARN: %s\n' "$*" >&2; }
err()   { printf '[ctp-run] ERROR: %s\n' "$*" >&2; }
die()   { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
ctp_run.sh — run one CUBRID CTP suite in isolated namespace shards (cubrid-nix).

  ctp_run.sh --suite <sql|medium> --build <install> \
             --testcases <repo checkout> --ctp <CTP_HOME> [--out <dir>] [options]

  Run it inside `nix develop` (or through `just ctp`): the shards use this shell's
  PATH for CTP's tools, and the recipe passes the pinned CTP and the locale archive.

WHAT / WHY
  Every CTP run happens in its own namespaces because CTP's own teardown kills every
  cub_* process of the running user (pkill cub / kill -9 by uid). On the host that
  destroys other sessions' servers; in a PID namespace it reaches only the shard.
  Each shard runs `unshare -Urmipnf --mount-proc` (ADR 0001 D8): the install is a run
  directory over the nix store, laid out at the CI container's paths.

SUITES
  sql        shardable, default 16 shards (cases dirs + measured-time split, plan pin)
  medium     always 1 shard  (one mdb dataset, mutated in place)
  (shell and ha_shell are out of scope: ADR 0001 D2)

WHOLE SUITE vs SUBSET
  no --only        the whole suite, split across the suite's default shard count
  --only <path>    a subset: scenario-relative dir (repeatable). Sharding still
                   applies, so a big subset can be parallel too.

TESTCASE REF (never silently 'develop')
  --tc-ref <ref>   explicit branch/tag/sha        (wins over everything)
  --pr <N>         engine PR -> tc/pr-<N>
  --workspace <d>  infer the PR from that checkout's branch via gh
  With none of the three this refuses to run. cubrid-testcases carries tc/pr-<N>;
  a missing branch falls back to develop and says so in the provenance line.
  The ref is materialized as a git worktree, so the checkout's branch and its
  uncommitted edits are never touched.

OPTIONS
  --suite <s>            sql | medium                            (default sql)
  --build <dir>          CUBRID install to test (required for a real run)
  --testcases <dir>      testcases repo checkout for this suite (required)
  --ctp <dir>            CTP_HOME to copy per shard   (default $CUBRID_NIX_CTP, the pinned CTP)
  --out <dir>            run/output directory
  --only <relpath>       scenario-relative subset path (repeatable)
  --shards <N>           override the shard count (refused for medium)
  --tc-ref / --pr / --workspace   see TESTCASE REF
  --testcases-as-is      use --testcases verbatim, skipping ref resolution
  --worktree-root <dir>  where testcase worktrees live
  --conf <file>          cubrid.conf whose [<suite>/cubrid.conf] section CTP applies
  --exclude <file>       host exclusion file replacing the default; empty = none
  --env K=V              extra env into every shard (repeatable)
  --by-category|--by-dir|--by-case   split unit (default: per suite)
  --weights <f>|--no-weights         time-balance source
  --colocate <f>|--no-colocate       order-sensitivity registry
  --split <f>|--no-split             slow cases dirs cut into contiguous chunks (dir mode)
  --plan-pin <f>|--no-plan-pin       keep units on a verified run's shards (plan_pin.tsv)
  --keep-copies          keep each shard's install/CTP/testcases/DB copies after the run
  --volatile             mount the database dir as a volatile overlay: its fsyncs
                         return at once (default ON; CTP_VOLATILE=0 or --no-volatile
                         turns it off, and a kernel without overlayfs in user
                         namespaces falls back to eatmydata)
  --no-volatile          keep the database dir plain
  --abort-on-core        stop every shard on the first real core dump (default ON)
  --no-abort-on-core     keep collecting cores; a shard still stops after
                         $CTP_CRASH_LOOP_CORES (5) cores with no passing case in
                         between or $CTP_MAX_SHARD_CORES (20) cores in total, and
                         the disk floor still stops every shard
  --no-webconsole        skip the merged report under <out>/webconsole
  --merge-only <dir>     merge a finished run into <dir>/webconsole and exit
  --label <text>         label for the merged run
  --locale-dir <dir>     prebuilt libcubrid_all_locales.so to inject
  --dry-run              plan + validate the split, launch nothing
  -h, --help             this text

OUTPUT
  <out>/provenance.txt|tsv   install / nix pins / CTP / testcases ref+sha of this run
  <out>/plan.tsv, assignment.tsv, units.tsv, plan_pin.tsv
  <out>/shard_N/{console.log,console.ts.log,exclusions.txt,assigned_cases.txt,reports/,cores/}
  <out>/failed.list          failing cases, in the shape --only takes
EOF
}

#####################################################################
# Argument parsing
#####################################################################
ARG_BUILD=""
ARG_TC=""
ARG_SUITE="sql"        # CTP suite: sql | medium | shell | ha_shell
ARG_TCREF=""           # explicit testcases ref (branch/tag/sha); "" = derive from --pr/--workspace
ARG_PR=""              # engine PR number -> testcases ref tc/pr-<N>
ARG_WS=""              # CUBRID source checkout, used to infer the PR when --pr/--tc-ref are absent
ARG_CONF=""            # host cubrid.conf whose [suite/cubrid.conf] params CTP should apply
ARG_EXCLUDE=""         # host exclusion file; set-but-empty disables exclusions
ARG_EXCLUDE_SET=0
ARG_TC_ASIS=0          # 1 = use --testcases verbatim, no ref resolution / worktree
ARG_WT_ROOT=""         # where testcase worktrees live (default: <out>/../tc-worktrees)
ARG_SHARDS=""
ARG_CTP="${CUBRID_NIX_CTP:-}"   # the pinned CTP, passed by `just ctp` (ADR 0001 D8)
ARG_OUT=""
ARG_UNIT="auto"       # split-unit mode: auto (per-suite default) | category (top-level _* "bulk") | dir | case
declare -a ARG_ONLY=()   # scenario-relative subset prefixes ("" = whole suite)
ARG_KEEP_COPIES="${CTP_KEEP_COPIES:-0}"   # 1: keep shard working copies (see prune_shard_copies)
ARG_VOLATILE="${CTP_VOLATILE:-1}"         # 1: volatile overlay on the suite's database dir (see resolve_volatile, D7)
ARG_WEIGHTS="auto"   # "auto" = bundled baseline_weights.tsv (time-based) | <path> | "none" (count)
ARG_LOCALE_DIR=""
ARG_WEBCONSOLE=1
ARG_COLOCATE="auto"   # "auto" = bundled colocate.tsv if present; a path = that file; "" = disabled
ARG_SPLIT="auto"      # "auto" = bundled split.tsv (sql, dir mode); a path = that file; "" = disabled
ARG_PIN="auto"        # "auto" = bundled plan_pin.tsv (sql, dir mode, same shard count); a path; "" = none
ARG_ABORT_ON_CORE=1   # default ON (2026-09-03): stop every shard as soon as a core dump / disk-floor breach is seen; --no-abort-on-core opts out
ARG_MERGE_ONLY=""     # path to a finished --out dir to merge into webconsole, then exit
ARG_LABEL=""          # human tag for the merged run (webconsole 'machine' field)
ARG_DRYRUN=0
ARG_VALIDATE_ONLY=0
VO_ASSIGN=""
VO_SQL=""
declare -a ARG_ENV=()   # repeatable --env NAME=VALUE, passed through to every shard

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --build)       ARG_BUILD="${2:-}"; shift 2 ;;
      --testcases)   ARG_TC="${2:-}"; shift 2 ;;
      --suite)       ARG_SUITE="${2:-}"; shift 2 ;;
      --tc-ref)      ARG_TCREF="${2:-}"; shift 2 ;;
      --pr)          ARG_PR="${2:-}"; shift 2 ;;
      --workspace)   ARG_WS="${2:-}"; shift 2 ;;
      --conf)        ARG_CONF="${2:-}"; shift 2 ;;
      --exclude)
        [ "$#" -ge 2 ] || die "--exclude requires a host file path or an empty argument"
        ARG_EXCLUDE="$2"; ARG_EXCLUDE_SET=1; shift 2 ;;
      --testcases-as-is) ARG_TC_ASIS=1; shift ;;
      --worktree-root)   ARG_WT_ROOT="${2:-}"; shift 2 ;;
      --shards)      ARG_SHARDS="${2:-}"; shift 2 ;;
      --ctp)         ARG_CTP="${2:-}"; shift 2 ;;
      --out)         ARG_OUT="${2:-}"; shift 2 ;;
      --only)        ARG_ONLY+=( "${2:-}" ); shift 2 ;;
      --by-category) ARG_UNIT="category"; shift ;;
      --by-dir)      ARG_UNIT="dir"; shift ;;
      --by-case)     ARG_UNIT="case"; shift ;;
      --keep-copies) ARG_KEEP_COPIES=1; shift ;;
      --volatile)    ARG_VOLATILE=1; shift ;;
      --no-volatile) ARG_VOLATILE=0; shift ;;
      --weights)     ARG_WEIGHTS="${2:-}"; shift 2 ;;
      --no-weights)  ARG_WEIGHTS="none"; shift ;;
      --locale-dir)  ARG_LOCALE_DIR="${2:-}"; shift 2 ;;
      --colocate)    ARG_COLOCATE="${2:-}"; shift 2 ;;
      --no-colocate) ARG_COLOCATE=""; shift ;;
      --split)       ARG_SPLIT="${2:-}"; shift 2 ;;
      --no-split)    ARG_SPLIT=""; shift ;;
      --plan-pin)    ARG_PIN="${2:-}"; shift 2 ;;
      --no-plan-pin) ARG_PIN=""; shift ;;
      --abort-on-core) ARG_ABORT_ON_CORE=1; shift ;;
      --no-abort-on-core) ARG_ABORT_ON_CORE=0; shift ;;
      --no-webconsole) ARG_WEBCONSOLE=0; shift ;;
      --merge-only)  ARG_MERGE_ONLY="${2:-}"; shift 2 ;;
      --label)       ARG_LABEL="${2:-}"; shift 2 ;;
      --env)
        case "${2:-}" in
          [A-Za-z_]*=*) : ;;
          *) usage; die "--env expects NAME=VALUE (got: '${2:-}')" ;;
        esac
        # Scope must reach the host planner before it materializes each shard.
        case "${2%%=*}" in
          CTP_SCENARIO|CTP_EXCLUDE|SHELL_SCENARIO|HA_SCENARIO|MEMORY_SCENARIO)
            die "${2%%=*} is retired; use --only for scope or --exclude for exclusions" ;;
          TEST_SCENARIO|TEST_EXCLUDE)
            die "${2%%=*} is managed by the runner; use --only or --exclude so the split matches the run" ;;
        esac
        ARG_ENV+=("$2"); shift 2 ;;
      --dry-run)     ARG_DRYRUN=1; shift ;;
      # Hidden self-test seam: run ONLY the offline split-validator against the
      # given assignment.tsv + .sql list (used by run_tests.sh on synthetic data).
      --validate-only) ARG_VALIDATE_ONLY=1; VO_ASSIGN="${2:-}"; VO_SQL="${3:-}"; shift 3 ;;
      -h|--help)     usage; exit 0 ;;
      *)             usage; die "unknown argument: $1" ;;
    esac
  done

  if [ "$ARG_VALIDATE_ONLY" -eq 1 ]; then
    [ -r "$VO_ASSIGN" ] || die "--validate-only: assignment file unreadable: $VO_ASSIGN"
    [ -r "$VO_SQL" ]    || die "--validate-only: sql-list file unreadable: $VO_SQL"
    return 0
  fi

  # --merge-only needs only a finished out dir + a CTP_HOME to merge into (no build/testcases).
  if [ -n "$ARG_MERGE_ONLY" ]; then
    [ -d "$ARG_MERGE_ONLY" ] || die "--merge-only dir does not exist: $ARG_MERGE_ONLY"
    [ -d "$ARG_CTP" ]        || die "--merge-only: --ctp dir does not exist: $ARG_CTP"
    [ -d "$ARG_CTP/sql" ]    || die "--merge-only: $ARG_CTP has no sql/ (need a CTP_HOME with webconsole)"
    return 0
  fi

  if [ "$ARG_EXCLUDE_SET" -eq 1 ] && [ -n "$ARG_EXCLUDE" ]; then
    [ -f "$ARG_EXCLUDE" ] && [ -r "$ARG_EXCLUDE" ] \
      || die "--exclude file unreadable: $ARG_EXCLUDE"
    ARG_EXCLUDE="$(readlink -f "$ARG_EXCLUDE")"
  fi

  resolve_suite
  resolve_volatile
  resolve_server_params
  case "$HANG_SECS" in
    ''|*[!0-9]*) die "CTP_HANG_SECS must be a whole number of seconds, 0 to disable (got: '$HANG_SECS')" ;;
  esac
  # shell/HA cases can run silently for many minutes and CTP's shell runner has its
  # own per-case timeout, so the hang watchdog is on there only when asked for.
  if [ -z "${CTP_HANG_SECS:-}" ] && [ "$SUITE_STYLE" = "status" ]; then
    HANG_SECS=0
  fi
  if [ -z "$ARG_OUT" ]; then
    ARG_OUT="$(bash "$SELF_DIR/artifact_root.sh")/$ARG_SUITE-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  # Both MUST be absolute before anything uses them. `git worktree add` resolves a
  # relative path against the REPOSITORY, not the invocation cwd, so a relative
  # --out silently created the worktree inside the testcases checkout while every
  # later check looked for it under the cwd. mkdir -p first: readlink -f of a
  # not-yet-existing path is fine, but the out dir is created here anyway.
  mkdir -p "$ARG_OUT" 2>/dev/null || die "cannot create --out dir: $ARG_OUT"
  ARG_OUT="$(readlink -f "$ARG_OUT")"
  [ -n "$ARG_WT_ROOT" ] || ARG_WT_ROOT="$(dirname "$ARG_OUT")/tc-worktrees"
  mkdir -p "$ARG_WT_ROOT" 2>/dev/null || die "cannot create worktree root: $ARG_WT_ROOT"
  ARG_WT_ROOT="$(readlink -f "$ARG_WT_ROOT")"
  [ -n "$ARG_TC" ]  || { usage; die "--testcases is required"; }
  [ -d "$ARG_TC" ]  || die "--testcases dir does not exist: $ARG_TC"
  SCN="$ARG_TC/$SUITE_SUBPATH"
  [ -d "$SCN" ]     || die "scenario dir not found: $SCN (expected <testcases>/$SUITE_SUBPATH)"
  [ -d "$ARG_CTP" ] || die "--ctp dir does not exist: $ARG_CTP"
  if [ -n "$ARG_CONF" ]; then
    [ -r "$ARG_CONF" ] || die "--conf file unreadable: $ARG_CONF"
    ARG_CONF="$(readlink -f "$ARG_CONF")"
  fi

  if [ "$ARG_DRYRUN" -eq 0 ]; then
    [ -n "$ARG_BUILD" ] || { usage; die "--build is required for a real run (omit only with --dry-run)"; }
    [ -d "$ARG_BUILD" ] || die "--build dir does not exist: $ARG_BUILD"
    # Resolve symlinks: a CUBRID install is often a symlink (e.g. ~/CUBRID -> .../CUBRID-11.5.x).
    # cp -a of a symlink would create a dangling link in the shard workdir, so copy the target.
    ARG_BUILD="$(readlink -f "$ARG_BUILD")"
    [ -d "$ARG_BUILD" ] || die "--build resolved to a non-directory: $ARG_BUILD"
  fi
  # Normalise SCN to an absolute path with no trailing slash (matches scenarioRootPath in F4).
  SCN="$(cd "$SCN" && pwd)"
}

#####################################################################
# Suite table. Each suite fixes: which testcases repo holds it, where under that
# repo the scenario root is, which ctp.sh category runs it, what a "case" file
# looks like, the default split unit, whether it may be sharded at all, and where
# its base exclusion list lives.
#
# Sharding policy (decided 2026-09-04, workspace#157 grilling):
#   sql      shardable, default 7 (bulk + measured-time split)
#   shell    shardable, default 7 (per test-dir, count-balanced until timings exist)
#   medium   NEVER sharded — one mdb is loaded from a single data_file tarball and
#            the cases mutate it in place, so two shards would race one dataset.
#   ha_shell NEVER sharded — a shard is a PAIR of containers (master+slave) and the
#            suite is only ever run one bucket at a time.
#####################################################################
SUITE_TCREPO=""; SUITE_SUBPATH=""; SUITE_CAT=""; SUITE_EXT=""
SUITE_UNIT_DEFAULT=""; SUITE_SHARDABLE=0; SUITE_STYLE=""
SUITE_CONF=""     # source conf for host engine-parameter merging, before the runtime copy
resolve_suite() {
  case "$ARG_SUITE" in
    sql)
      SUITE_TCREPO="cubrid-testcases";            SUITE_SUBPATH="sql"
      SUITE_CAT="sql";      SUITE_EXT="sql";      SUITE_UNIT_DEFAULT="dir"
      SUITE_SHARDABLE=1;    SUITE_STYLE="sqlresult";  SUITE_CONF="conf/sql.conf" ;;
    medium)
      SUITE_TCREPO="cubrid-testcases";            SUITE_SUBPATH="medium"
      SUITE_CAT="medium";   SUITE_EXT="sql";      SUITE_UNIT_DEFAULT="dir"
      SUITE_SHARDABLE=0;    SUITE_STYLE="sqlresult";  SUITE_CONF="conf/medium_dev.conf" ;;
    shell|ha_shell)
      die "--suite $ARG_SUITE is out of scope for cubrid-nix (ADR 0001 D2: sql and medium only)" ;;
    *) usage; die "--suite must be sql or medium (got: '$ARG_SUITE')" ;;
  esac
  C_TCREPO="$C_WORKDIR/$SUITE_TCREPO"
  C_SCN="$C_TCREPO/$SUITE_SUBPATH"
  # NOT a one-line test: as the last statement of the function its exit status
  # would become the function's, so an explicit --by-* (auto already replaced)
  # would make resolve_suite return 1 and, under set -e, kill the run silently.
  if [ "$ARG_UNIT" = "auto" ]; then
    ARG_UNIT="$SUITE_UNIT_DEFAULT"
  fi
}

# Volatile database dir (D7): the dirs CTP creates its database in, mounted
# inside the container as an overlayfs with the kernel's `volatile` option
# (scripts/volatile_entry.sh), so every fsync there returns at once. sql/medium
# create basic/mdb under $CUBRID/databases (run.sh: cubrid_root_dir=$CUBRID).
# shell/ha_shell cases create databases in their own case dirs, so nothing is
# applied there.
VOLATILE_TARGETS=""
resolve_volatile() {
  case "$ARG_VOLATILE" in
    0|1) : ;;
    *) die "CTP_VOLATILE must be 0 or 1 (got: '$ARG_VOLATILE')" ;;
  esac
  [ "$ARG_VOLATILE" -eq 1 ] || return 0
  case "$ARG_SUITE" in
    sql|medium) VOLATILE_TARGETS="$C_CUBRID/databases" ;;
    *) return 0 ;;
  esac
}

#####################################################################
# Which testcases ref this run verifies.
#
# The default must NEVER be "whatever the host checkout happens to have on
# HEAD": that is how a PR gets validated against develop testcases and the
# result is quietly meaningless (and how a second session's `git checkout`
# changes another session's run mid-flight). So: explicit --tc-ref wins, else
# --pr, else the PR inferred from --workspace's branch; with none of the three
# this refuses to run.
#
# CI's own rule is mirrored here: cubrid-testcases and cubrid-testcases-private-ex
# carry tc/pr-<N> branches, and a missing one falls back to develop (recorded in
# the provenance line, never silent). cubrid-testcases-private has no tc/pr-<N>
# convention at all, so it is always develop.
#####################################################################
TC_REF=""; TC_REF_SRC=""; TC_SHA=""; TC_WORKTREE=""
resolve_tc_ref() {
  local repo="$SUITE_TCREPO" want=""
  if [ -n "$ARG_TCREF" ]; then
    want="$ARG_TCREF"; TC_REF_SRC="--tc-ref"
  elif [ "$repo" = "cubrid-testcases-private" ]; then
    want="develop";    TC_REF_SRC="always-develop (repo has no tc/pr-N convention)"
  else
    local pr="$ARG_PR"
    if [ -z "$pr" ] && [ -n "$ARG_WS" ]; then
      pr="$(infer_pr_from_workspace "$ARG_WS")" || pr=""
      [ -n "$pr" ] && TC_REF_SRC="inferred from --workspace branch (PR #$pr)"
    else
      [ -n "$pr" ] && TC_REF_SRC="--pr $pr"
    fi
    [ -n "$pr" ] || die "no testcases ref: pass --tc-ref <ref> or --pr <engine PR>, or --workspace <cubrid checkout> to infer it. Refusing to silently run develop testcases."
    want="tc/pr-$pr"
  fi
  TC_REF="$want"
}

# Echo the engine PR number whose head is the workspace's current branch, or fail.
infer_pr_from_workspace() {
  local ws="$1" br
  [ -d "$ws/.git" ] || return 1
  br="$(git -C "$ws" rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 1
  [ -n "$br" ] && [ "$br" != "HEAD" ] || return 1
  case "$br" in develop|master|main) return 1 ;; esac
  command -v gh >/dev/null 2>&1 || return 1
  gh pr list --repo CUBRID/cubrid --head "$br" --state all --limit 1 \
     --json number --jq '.[0].number' 2>/dev/null | grep -E '^[0-9]+$'
}

# Materialize TC_REF as a worktree we own, so the host checkout's branch and its
# uncommitted edits are never touched (and two sessions on different refs cannot
# fight over one working tree). Reused across runs; refreshed to the remote tip.
# Concurrent runs share a testcases repo: sql and medium started together, or
# another session. Two git worktree operations on one repo at once fail on its
# index.lock ("Unable to create .../index.lock: File exists"), which killed a
# medium run started beside sql. So the fetch/worktree steps take the repo's own
# lock file, which serializes every runner on this host that uses that repo.
materialize_tc_worktree() {
  local repo_dir="$1" common lock fd
  git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a git checkout: $repo_dir"
  common="$(cd "$repo_dir" && cd "$(git rev-parse --git-common-dir)" && pwd)"
  lock="$common/ctprun-materialize.lock"
  exec {fd}>"$lock" || die "cannot open $lock"
  flock -w 900 "$fd" || die "timed out after 900s waiting for $lock (another run is materializing testcases)"
  # Called bare so set -e still stops the run on a failed git step; exiting
  # releases the lock with the process.
  materialize_tc_worktree_unlocked "$@"
  exec {fd}>&-
}

materialize_tc_worktree_unlocked() {
  local repo_dir="$1" ref="$2" wt_root="$3"
  local safe; safe="$(printf '%s' "$ref" | tr -c 'A-Za-z0-9._-' '_')"
  local wt="$wt_root/$(basename "$repo_dir")/$safe"

  if git -C "$repo_dir" fetch --quiet origin "$ref" 2>/dev/null; then
    TC_SHA="$(git -C "$repo_dir" rev-parse FETCH_HEAD)"
  else
    # A raw commit SHA is not fetchable by name (GitHub refuses want-of-arbitrary-SHA), so a
    # fetch failure alone does not mean the ref is unknown. Refresh the remote refs and try to
    # resolve it locally before giving up -- otherwise pinning a SHA silently degrades into
    # "whatever develop is right now", which is exactly what an explicit ref is for, and makes
    # two runs pinned to the same SHA incomparable.
    git -C "$repo_dir" fetch --quiet origin 2>/dev/null || true
    TC_SHA="$(git -C "$repo_dir" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null || true)"
    if [ -z "$TC_SHA" ]; then
      if [ "$ref" != "develop" ]; then
        warn "$(basename "$repo_dir"): ref '$ref' not on origin -> falling back to develop."
        TC_REF="develop"; TC_REF_SRC="$TC_REF_SRC + fallback (no $ref on origin)"
        materialize_tc_worktree_unlocked "$repo_dir" develop "$wt_root"
        return
      fi
      die "$(basename "$repo_dir"): cannot fetch origin develop"
    fi
    TC_REF_SRC="$TC_REF_SRC (resolved locally)"
  fi

  mkdir -p "$(dirname "$wt")"
  if [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; then
    git -C "$wt" reset --quiet --hard "$TC_SHA"
    git -C "$wt" clean -qfd
  else
    rm -rf "$wt"
    git -C "$repo_dir" worktree add --quiet --detach "$wt" "$TC_SHA" \
      || die "could not create worktree $wt at $TC_SHA"
  fi
  TC_WORKTREE="$wt"
  info "testcases: $(basename "$repo_dir") @ $TC_REF ($(printf '%.12s' "$TC_SHA")) -> $wt"
}

PROVENANCE=""
build_provenance() {
  PROVENANCE="$(printf 'install=%s runner=unshare nixpkgs=%s ctp=%s testcases=%s@%s(%.12s) suite=%s shards=%s ref-src=%s volatile=%s pinned=%s plan=%s' \
    "${ARG_BUILD:-<none>}" "${CUBRID_NIX_NIXPKGS_REV:-unknown}" "$(ctp_revision)" \
    "$SUITE_TCREPO" "$TC_REF" "${TC_SHA:-unknown}" "$ARG_SUITE" "$NSHARDS" "${TC_REF_SRC:-n/a}" \
    "${VOLATILE_TARGETS:-off}" "$(pinned_label | tr ' ' ',')" "$(printf '%s' "$PLAN_LABEL" | tr ' ' '_')")"
}
ctp_revision() {
  git -C "$ARG_CTP" rev-parse --short HEAD 2>/dev/null || echo "${CUBRID_NIX_CTP_REV:-unknown}"
}
# The CI toolchain snapshot an install runs on: its programs name the snapshot's loader.
snapshot_of() {
  readelf -l "$1/bin/cub_server" 2>/dev/null \
    | sed -n 's/.*program interpreter: \(.*\)\/lib64\/ld-linux-x86-64.so.2]$/\1/p'
}
write_provenance() {
  printf '%s\n' "$PROVENANCE" > "$OUT/provenance.txt"
  {
    printf 'suite\t%s\n' "$ARG_SUITE"
    printf 'install\t%s\n' "${ARG_BUILD:-}"
    printf 'runner\tunshare shards (cubrid-nix %s)\n' "$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)$(git -C "$REPO_DIR" diff --quiet HEAD 2>/dev/null || echo +dirty)"
    printf 'nixpkgs\t%s\n' "${CUBRID_NIX_NIXPKGS_REV:-unknown}"
    printf 'snapshot\t%s\n' "$(snapshot_of "${ARG_BUILD:-/nonexistent}" || echo unknown)"
    printf 'fsync\t%s\n' "$([ -n "$VOLATILE_TARGETS" ] && echo "volatile overlay" || { [ "$USE_EATMYDATA" -eq 1 ] && echo eatmydata || echo "fsync on"; })"
    printf 'ctp\t%s\t%s\n' "$ARG_CTP" "$(ctp_revision)"
    printf 'testcases_repo\t%s\n' "$SUITE_TCREPO"
    printf 'testcases_ref\t%s\n' "$TC_REF"
    printf 'testcases_sha\t%s\n' "${TC_SHA:-}"
    printf 'testcases_ref_source\t%s\n' "${TC_REF_SRC:-}"
    printf 'shards\t%s\n' "$NSHARDS"
    printf 'conf\t%s\n' "${ARG_CONF:-<CTP default>}"
    printf 'volatile\t%s\n' "${VOLATILE_TARGETS:-off}"
    printf 'pinned_params\t%s\n' "$(pinned_label)"
    printf 'plan\t%s\n' "$PLAN_LABEL"
    if [ "$ARG_EXCLUDE_SET" -eq 1 ]; then
      printf 'exclude\t%s\n' "${ARG_EXCLUDE:-<none>}"
    else
      printf 'exclude\t%s\n' "<suite default>$([ -n "$(dirsplit_exclusions_file)" ] && echo ' + dirsplit_exclusions.txt')"
    fi
    printf 'started\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$OUT/provenance.tsv"
  info "provenance: $PROVENANCE"
}

#####################################################################
# Host preflight — what the shards need from this kernel and shell (ADR 0001 D11).
# Runs BEFORE any work dirs are created, so a failing check leaves nothing behind.
#####################################################################
USE_EATMYDATA=0
NS_MODE=1   # 0: this environment cannot make namespaces; one shard runs directly
host_preflight() {
  local t tool
  for tool in unshare nsenter ip readelf; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not on PATH; run inside \`nix develop\` (or \`just ctp\`)."
  done
  [ -d /mnt ] || die "/mnt does not exist: each shard stages its directory there before it builds the CI layout on /home."
  [ -d /home ] || die "/home does not exist: each shard builds the CI container's layout there."
  if ! unshare -Urmipnf --mount-proc true 2>/dev/null; then
    NS_MODE=0
    warn "cannot create user, mount, PID and network namespaces here (unshare -Urmipnf --mount-proc failed)."
    warn "Running ONE shard directly (ADR 0001 D11). CTP's teardown kills every cub_* process of this"
    warn "user, so use an environment dedicated to this run."
  fi
  if [ "$NS_MODE" -eq 0 ] && [ -n "$VOLATILE_TARGETS" ]; then
    VOLATILE_TARGETS=""; USE_EATMYDATA=1
  fi
  # overlayfs with the volatile option inside a user namespace needs kernel 5.11+
  if [ -n "$VOLATILE_TARGETS" ]; then
    t="$(mktemp -d "$(dirname "$ARG_OUT")/.volatile-probe.XXXXXX")"
    mkdir -p "$t/l" "$t/u" "$t/w" "$t/m"
    if ! unshare -Urm sh -c "mount -t overlay overlay -o lowerdir=$t/l,upperdir=$t/u,workdir=$t/w,volatile,userxattr $t/m" 2>/dev/null; then
      warn "volatile overlay is not available in a user namespace here (kernel < 5.11?); fsync goes through eatmydata instead."
      VOLATILE_TARGETS=""; USE_EATMYDATA=1
    fi
    unshare -Ur rm -rf "$t" 2>/dev/null || rm -rf "$t"
  fi
  if [ "$USE_EATMYDATA" -eq 1 ] && [ ! -r "${CUBRID_NIX_EATMYDATA:-}" ]; then
    warn "eatmydata library not found (CUBRID_NIX_EATMYDATA); shards keep fsync on."
    USE_EATMYDATA=0
  fi
  # sql/medium compile CTP's Java SP classes against the install's JDBC driver and run
  # CQT on it; without jdbc/ CTP would only die after createdb and javac.
  case "$ARG_SUITE" in
    sql|medium)
      [ -e "$ARG_BUILD/jdbc/cubrid_jdbc.jar" ] \
        || die "--build has no jdbc/cubrid_jdbc.jar: $ARG_BUILD (CTP $ARG_SUITE needs the JDBC driver)" ;;
  esac
  [ -n "$(snapshot_of "$ARG_BUILD")" ] \
    || die "--build $ARG_BUILD is not built with the CI toolchain snapshot (no snapshot loader on bin/cub_server)"
  local avail_kb
  avail_kb="$(df -Pk "$(dirname "$ARG_OUT")" 2>/dev/null | awk 'NR==2{print $4}')"
  [ -n "${avail_kb:-}" ] && info "disk available at out parent: $((avail_kb/1024/1024)) GB"
}

#####################################################################
# Resource sizing — pick N when --shards not given.
#   DEFAULT = 7 (DEFAULT_SHARDS): the workload-optimal count for the default
#   bulk(_*) + measured-time split on the CUBRID sql suite. The slowest shard is
#   bounded by the heaviest single bulk (~323s here, _05_plcsql), so the knee is
#   N* = ceil(total_time / heaviest_bulk) = ceil(2204/323) = 7 — at 7 shards every
#   shard is full (~315-324s) and adding more shards only leaves them idle (no
#   wall-clock gain) while costing extra build copies / RAM. (CircleCI uses 10 only
#   because it splits by name, not time.) Memory-guarded: capped down with a warning
#   if free RAM can't hold 7 shards, to avoid OOM; pass --shards to override.
#####################################################################
readonly DEFAULT_SHARDS=7
# sql (D9): split by cases dir with measured weights, the knee moves to
# total / longest unit = 2,668s / ~167s (longest dir, once split.tsv cuts the
# 203s _005_reorganization in two) = 16. Every shard also costs this host's
# pids cgroup (pids.max 8192) about PER_SHARD_PIDS processes+threads.
readonly DEFAULT_SQL_SHARDS=16
PER_SHARD_GB=3
PER_SHARD_PIDS=400
shard_refusal_reason() {
  case "$ARG_SUITE" in
    medium)   printf 'one mdb dataset is loaded from a single data_file tarball and the cases mutate it in place' ;;
    ha_shell) printf 'a shard is a master+slave container pair and the suite is run one bucket at a time' ;;
    *)        printf 'suite policy' ;;
  esac
}
choose_shards() {
  if [ "$NS_MODE" -eq 0 ] && [ "$ARG_DRYRUN" -eq 0 ]; then
    NSHARDS=1
    info "shard count: 1 (no namespaces here: the shard runs directly)"
    return
  fi
  if [ "$SUITE_SHARDABLE" -eq 0 ]; then
    if [ -n "$ARG_SHARDS" ] && [ "$ARG_SHARDS" != "1" ]; then
      die "suite '$ARG_SUITE' cannot be sharded (--shards $ARG_SHARDS refused): $(shard_refusal_reason)"
    fi
    NSHARDS=1
    info "shard count: 1 (suite '$ARG_SUITE' is never sharded: $(shard_refusal_reason))"
    return
  fi
  if [ -n "$ARG_SHARDS" ]; then
    case "$ARG_SHARDS" in (*[!0-9]*|"") die "--shards must be a positive integer";; esac
    [ "$ARG_SHARDS" -ge 1 ] || die "--shards must be >= 1"
    NSHARDS="$ARG_SHARDS"
    info "shard count: $NSHARDS (from --shards)"
    return
  fi
  # A subset defaults to ONE shard. Every shard costs a full copy of the install
  # (~1GB) and a container, which is worth it for a 17k-case suite and absurd for
  # the handful of dirs a subset usually is. Parallelism is still one flag away
  # (--shards N) for a genuinely large subset.
  if [ "${#ARG_ONLY[@]}" -gt 0 ]; then
    NSHARDS=1
    info "shard count: 1 (subset run; pass --shards N to split a large subset)"
    return
  fi
  local def=$DEFAULT_SHARDS
  [ "$ARG_SUITE" = "sql" ] && def=$DEFAULT_SQL_SHARDS
  NSHARDS=$def
  local free_gb mem_cap pmax pcur pid_cap
  free_gb="$(free -g 2>/dev/null | awk '/^Mem:/{print $7}')"; [ -z "${free_gb:-}" ] && free_gb=$(( def * PER_SHARD_GB ))
  mem_cap=$(( free_gb / PER_SHARD_GB )); [ "$mem_cap" -lt 1 ] && mem_cap=1
  if [ "$mem_cap" -lt "$NSHARDS" ]; then
    warn "default $def shards needs ~$(( def * PER_SHARD_GB ))GB; only ${free_gb}GB free -> capping to $mem_cap (override with --shards)."
    NSHARDS=$mem_cap
  fi
  # pids cgroup: a container host like this one caps processes+threads for the
  # whole user (pids.max 8192 here). Forks failing mid-run turn into random NOKs.
  pmax="$(cat /sys/fs/cgroup/pids/pids.max 2>/dev/null || cat /sys/fs/cgroup/pids.max 2>/dev/null || echo max)"
  pcur="$(cat /sys/fs/cgroup/pids/pids.current 2>/dev/null || cat /sys/fs/cgroup/pids.current 2>/dev/null || echo 0)"
  # Short of room, wait for it rather than run fewer shards: the room is usually
  # another session's CTP run, which ends within minutes (user decision
  # 2026-09-24). Only after CTP_PIDS_WAIT_SECS (default 900) is the count capped.
  case "$pmax" in
    ''|max|*[!0-9]*) : ;;
    *) local waited=0 wait_max="${CTP_PIDS_WAIT_SECS:-900}"
       while pid_cap=$(( (pmax - pcur) / PER_SHARD_PIDS )); [ "$pid_cap" -lt "$NSHARDS" ] && [ "$waited" -lt "$wait_max" ]; do
         [ "$waited" -eq 0 ] && warn "pids cgroup: ${pcur}/${pmax} in use and a shard takes ~${PER_SHARD_PIDS}; room for $pid_cap of $NSHARDS shards. Waiting up to ${wait_max}s (CTP_PIDS_WAIT_SECS) for other runs to finish ..."
         sleep 15; waited=$(( waited + 15 ))
         pcur="$(cat /sys/fs/cgroup/pids/pids.current 2>/dev/null || cat /sys/fs/cgroup/pids.current 2>/dev/null || echo 0)"
       done
       [ "$pid_cap" -lt 1 ] && pid_cap=1
       if [ "$pid_cap" -lt "$NSHARDS" ]; then
         warn "pids cgroup: still ${pcur}/${pmax} after ${waited}s -> capping to $pid_cap shards (override with --shards)."
         NSHARDS=$pid_cap
       elif [ "$waited" -gt 0 ]; then
         info "pids cgroup: room for $NSHARDS shards after ${waited}s (${pcur}/${pmax})."
       fi ;;
  esac
  info "shard count: $NSHARDS (default for $ARG_SUITE: $def, split by ${ARG_UNIT} with measured time)"
}

#####################################################################
# Order-sensitivity registry (colocate.tsv). Produces two WORK files consumed by
# unit discovery / routing / balancing:
#   keepwhole.txt : one cases-dir per line -> routed at cases-dir granularity in
#                   EVERY mode (so --by-case never splits these), kept whole.
#   gids.txt      : "<cases-dir>\t<group-id>" -> dirs sharing a group-id are pinned
#                   to the SAME shard by the balancer.
# Both files always exist (possibly empty) so the awk getline never trips. A
# registered dir absent from the scenario is warned about, not fatal.
#####################################################################
COLO_KEEPWHOLE=""
COLO_GIDS=""
resolve_colocate() {
  COLO_KEEPWHOLE="$WORK/keepwhole.txt"
  COLO_GIDS="$WORK/gids.txt"
  : >"$COLO_KEEPWHOLE"; : >"$COLO_GIDS"
  local src=""
  case "$ARG_COLOCATE" in
    "")   info "colocate: disabled (--no-colocate)."; return 0 ;;
    auto) local bundled="$SELF_DIR/../colocate.tsv"
          # bundled registry lists sql/ cases dirs only; meaningless for another suite
          [ "$ARG_SUITE" = "sql" ] && [ -r "$bundled" ] && src="$bundled" ;;
    *)    [ -r "$ARG_COLOCATE" ] || die "--colocate file not readable: $ARG_COLOCATE"; src="$ARG_COLOCATE" ;;
  esac
  if [ -z "$src" ]; then
    info "colocate: no registry found (bundled colocate.tsv absent); no constraints."
    return 0
  fi
  # Each non-comment line is a group; tokens are cases-dir relpaths (trailing '/'
  # tolerated). Emit "<dir>\tG<lineno>"; line number is a stable per-group id.
  awk '
    /^[[:space:]]*#/ { next }
    { gsub(/\r/,""); n=split($0,t,/[[:space:]]+/)
      for (i=1;i<=n;i++) if (t[i]!="") { d=t[i]; sub(/\/+$/,"",d); print d "\tG" NR }
    }
  ' "$src" > "$COLO_GIDS"
  cut -f1 "$COLO_GIDS" > "$COLO_KEEPWHOLE"
  local missing=0 d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -d "$SCN/$d" ] || { warn "colocate: registered dir not in scenario (ignored): $d"; missing=$((missing+1)); }
  done < "$COLO_KEEPWHOLE"
  local ndirs ngroups
  ndirs=$(grep -c . "$COLO_KEEPWHOLE" 2>/dev/null || echo 0)
  ngroups=$(cut -f2 "$COLO_GIDS" 2>/dev/null | LC_ALL=C sort -u | grep -c . || echo 0)
  info "colocate: $ndirs dir(s) in $ngroups group(s) from $(basename "$src") — keep-whole applies to --by-case only; multi-dir groups pinned to one shard$([ "$missing" -gt 0 ] && echo "; $missing missing")."
}

#####################################################################
# Plan pin (plan_pin.tsv, D9): the unit -> shard assignment of a verified run.
# A dir-split plan is only as clean as the dirs that run in front of each dir,
# and LPT reshuffles almost everything when one weight or one case changes, so
# a PR branch's cases or a weight refresh would otherwise bring a new plan with
# new order-dependent failures. With the pin, every unit it knows keeps its
# shard and only the units it does not know are placed, by LPT around the
# pinned load (balance_units).
#   auto (default) -> the bundled plan_pin.tsv, for a whole-suite sql run split
#                     by cases dir; <path> -> that file; "" -> no pin.
# A pin written for another shard count is not used (warned): the shards are
# only the same shards when there are as many of them.
# Every sharded run writes its own plan as <out>/plan_pin.tsv; copying a
# verified run's file over the bundled one re-pins.
#####################################################################
PIN_FILE=""
PLAN_LABEL="lpt"
pin_header() {                     # pin_header <file> <key>: a key=value of its "# shards=" line
  awk -v k="$2" '/^# shards=/ { for (i=2;i<=NF;i++) { split($i,kv,"="); if (kv[1]==k) { print kv[2]; exit } } }' "$1"
}
resolve_pin() {
  local src="" bundled="$SELF_DIR/../plan_pin.tsv" n
  case "$ARG_PIN" in
    "")   PLAN_LABEL="lpt (--no-plan-pin)"; return 0 ;;
    auto) [ "$ARG_SUITE" = "sql" ] && [ "$ARG_UNIT" = "dir" ] && [ "${#ARG_ONLY[@]}" -eq 0 ] \
            && [ -r "$bundled" ] && src="$bundled" ;;
    *)    [ -r "$ARG_PIN" ] || die "--plan-pin file not readable: $ARG_PIN"; src="$ARG_PIN" ;;
  esac
  [ -n "$src" ] || return 0
  [ "$(pin_header "$src" suite)" = "$ARG_SUITE" ] && [ "$(pin_header "$src" unit)" = "$ARG_UNIT" ] \
    || die "plan pin $src is for suite=$(pin_header "$src" suite) unit=$(pin_header "$src" unit); this run is suite=$ARG_SUITE unit=$ARG_UNIT."
  n="$(pin_header "$src" shards)"
  if [ "$n" != "$NSHARDS" ]; then
    warn "plan pin: $(basename "$src") is for ${n:-?} shards and this run has $NSHARDS; planning by LPT alone."
    PLAN_LABEL="lpt (pin is for ${n:-?} shards)"
    return 0
  fi
  PIN_FILE="$src"
  PLAN_LABEL="pinned:$(basename "$src")"
}

# After balance_units: what the pin kept, and a warning once the pinned plan has
# drifted out of balance (new units piled up, or weights moved), meaning the
# heaviest shard is more than 10% over the mean.
report_pin() {
  [ -n "$PIN_FILE" ] || return 0
  local kept placed conflict gone i mx=0 sum=0 mean
  kept="$(awk -F'\t' '$1=="kept"{print $2}' "$WORK/pin_stats.tsv")"
  placed="$(awk -F'\t' '$1=="placed"{print $2}' "$WORK/pin_stats.tsv")"
  conflict="$(awk -F'\t' '$1=="conflict"{print $2}' "$WORK/pin_stats.tsv")"
  gone="$(awk -F'\t' '$1=="gone"{print $2}' "$WORK/pin_stats.tsv")"
  info "plan pin: $kept unit group(s) on their pinned shard, $placed placed by LPT (not in the pin$([ "${conflict:-0}" -gt 0 ] && echo ", $conflict of them colocated from different pinned shards")); $gone pinned unit(s) not in this pool."
  for (( i=0; i<NSHARDS; i++ )); do
    sum=$(( sum + ${SHARD_LOAD[i]:-0} )); [ "${SHARD_LOAD[i]:-0}" -gt "$mx" ] && mx=${SHARD_LOAD[i]}
  done
  mean=$(( sum / NSHARDS ))
  if [ "$mean" -gt 0 ] && [ $(( mx * 100 )) -gt $(( mean * 110 )) ]; then
    warn "plan pin: the heaviest shard (${mx}) is over 110% of the mean (${mean}). To re-pin: run with --no-plan-pin, verify that plan twice, then copy its plan_pin.tsv over the bundled one."
  fi
}

# This run's plan in the pin's format. Called before expand_split_assignment,
# while the assignment still has one row per unit (a split chunk is "<dir>#<k>").
write_run_pin() {
  [ "$NSHARDS" -gt 1 ] || return 0
  {
    printf '# shards=%d unit=%s suite=%s testcases=%s@%.12s run=%s\n' "$NSHARDS" "$ARG_UNIT" "$ARG_SUITE" \
      "$TC_REF" "${TC_SHA:-unknown}" "$(basename "$OUT")"
    printf '# unit -> shard of this run'"'"'s plan (%s). Copy it over .agents/skills/ctp-run/plan_pin.tsv to pin it.\n' "$PLAN_LABEL"
    LC_ALL=C sort "$ASSIGN_FILE"
  } > "$OUT/plan_pin.tsv"
}

#####################################################################
# Split registry (split.tsv): cases dirs too slow to sit whole on one shard.
# "<cases dir>\t<parts>" per line (# comments). Applies to dir mode only; see
# discover_units. A dir that is also keep-whole in colocate.tsv is a contradiction
# and refused. Produces $SPLIT_FILE ("<dir>\t<parts>").
#   auto (default) -> bundled split.tsv for sql; <path> -> that file; "" -> none.
#####################################################################
SPLIT_FILE=""
resolve_split() {
  SPLIT_FILE="$WORK/split.txt"
  : >"$SPLIT_FILE"
  local src="" d k
  case "$ARG_SPLIT" in
    "")   return 0 ;;
    auto) [ "$ARG_SUITE" = "sql" ] && [ -r "$SELF_DIR/../split.tsv" ] && src="$SELF_DIR/../split.tsv" ;;
    *)    [ -r "$ARG_SPLIT" ] || die "--split file not readable: $ARG_SPLIT"; src="$ARG_SPLIT" ;;
  esac
  [ -n "$src" ] || return 0
  while IFS=$'\t' read -r d k; do
    case "$d" in ''|\#*) continue ;; esac
    d="${d%/}"
    case "$k" in ''|*[!0-9]*) die "split.tsv: '$d' needs a whole number of parts >= 2 (got: '$k')" ;; esac
    [ "$k" -ge 2 ] || die "split.tsv: '$d' needs at least 2 parts (got: $k)"
    grep -qxF "$d" "$COLO_KEEPWHOLE" 2>/dev/null \
      && die "split.tsv: '$d' is keep-whole in colocate.tsv; it cannot also be split"
    [ -d "$SCN/$d" ] || { warn "split: registered dir not in scenario (ignored): $d"; continue; }
    printf '%s\t%s\n' "$d" "$k" >> "$SPLIT_FILE"
  done < "$src"
  [ "$ARG_UNIT" = "dir" ] || { [ -s "$SPLIT_FILE" ] && info "split: registry ignored in '$ARG_UNIT' mode (dir mode only)."; : >"$SPLIT_FILE"; }
  [ -s "$SPLIT_FILE" ] && info "split: $(wc -l < "$SPLIT_FILE") dir(s) cut into contiguous weight chunks ($(basename "$src"))." || :
}

#####################################################################
# Resolve the effective weights table (measured per-case seconds for time balancing).
#   auto (default) -> bundled baseline_weights.tsv if present, else count.
#   none           -> count-based (--no-weights).
#   <path>         -> that file (must be readable).
#####################################################################
WEIGHTS_FILE=""
resolve_weights() {
  case "$ARG_WEIGHTS" in
    none|"") WEIGHTS_FILE=""; info "weights: count-based (--no-weights)." ;;
    auto)
      local bundled="$SELF_DIR/../baseline_weights.tsv"
      if [ "$ARG_SUITE" != "sql" ]; then
        WEIGHTS_FILE=""; info "weights: bundled table is sql-only; count-based for suite '$ARG_SUITE'."
      elif [ -r "$bundled" ]; then
        WEIGHTS_FILE="$bundled"
        info "weights: time-based from bundled $(basename "$bundled") ($(awk -F'\t' '{s+=$2}END{printf "%.0f", s}' "$bundled" 2>/dev/null)s over $(wc -l < "$bundled") cases)."
      else
        WEIGHTS_FILE=""; info "weights: no bundled table; count-based."
      fi ;;
    *)
      [ -r "$ARG_WEIGHTS" ] || die "--weights file not readable: $ARG_WEIGHTS"
      WEIGHTS_FILE="$ARG_WEIGHTS"; info "weights: time-based from $ARG_WEIGHTS." ;;
  esac
}

#####################################################################
# Unit discovery.
#   DEFAULT unit = top-level _* directory ("bulk"). This is exactly CircleCI's sql
#   split unit (.circleci/config.yml globs "cubrid-testcases/sql/_*" and ships each
#   match WHOLE to one node). A bulk is INDIVISIBLE — it is never split across shards
#   — so every test inside a _* dir stays co-located in canonical order, exactly as
#   CI groups them. That co-location is what keeps the suite green: finer splits move
#   tests apart and expose cross-test / shared-DB interference (one shard runs ONE
#   database for all its cases, and not every test self-isolates), producing failures
#   that depend on which tests share a shard. Bulk grouping mirrors CI and avoids it.
#   Balance bulks by measured time with --weights (a bulk's weight = sum of its cases'
#   seconds); without weights, by case count. Tradeoff: the heaviest single bulk is a
#   hard floor on the slowest shard, since a bulk cannot be split.
#   --by-dir:      unit = OUTERMOST cases dir (~1157 units; finer => better balance, but
#                  co-locates fewer related tests, so may expose isolation failures).
#   --by-case:     unit = the .sql itself (finest; NOT order-safe; opt in only when the
#                  targeted cases are known independent).
#   colocate.tsv:  applies ONLY to --by-case (keeps listed cases dirs whole / co-located);
#                  in dir/category the cases dir / bulk is already atomic.
# Emits to stdout: "<unit_relpath>\t<weight>" (scenario-relative, no leading '/').
# Honors base exclusions (F4): a .sql removed by the base list is not counted.
#####################################################################
UNITS_FILE=""      # tmp: unit \t sqlcount
SQL_LIST=""        # tmp: surviving .sql relpaths (post base exclusion)
PLAN_LIST=""       # tmp: the pool the plan is computed over (SQL_LIST plus dir-split exclusions)
SQL_ALL=""         # tmp: all .sql relpaths
BASE_FILE=""       # the original CTP exclusions.txt (verbatim base list)

# The base exclusion list CTP itself will apply. It must be the SAME file the
# container's conf points at, or our surviving-case count (and therefore the
# split invariant) disagrees with what CTP actually runs.
suite_base_exclusion_file() {
  case "$ARG_SUITE" in
    sql|medium) printf '%s' "$ARG_CTP/conf/exclusions.txt" ;;
    shell|ha_shell) printf '%s' "$SCN/config/daily_regression_test_excluded_list_linux.conf" ;;
  esac
}

# The dir-split exclusion list when it applies (sql, split by cases dir, suite
# default exclusions), else nothing.
dirsplit_exclusions_file() {
  local f="$SELF_DIR/../dirsplit_exclusions.txt"
  if [ "$ARG_SUITE" = "sql" ] && [ "$ARG_UNIT" = "dir" ] && [ "$ARG_EXCLUDE_SET" -eq 0 ] && [ -r "$f" ]; then
    printf '%s' "$f"
  fi
}

discover_units() {
  BASE_FILE="$(suite_base_exclusion_file)"
  if [ "$ARG_EXCLUDE_SET" -eq 1 ]; then
    BASE_FILE="${ARG_EXCLUDE:-/dev/null}"
  fi
  [ -r "$BASE_FILE" ] || die "exclusion list unreadable: $BASE_FILE (use --exclude '' for no exclusions)"
  # Snapshot the exact list used for planning; every shard receives these bytes.
  # Split by cases dir, the default sql list also takes dirsplit_exclusions.txt:
  # cases whose answers need CI's whole serial order before them (D9).
  local dx; dx="$(dirsplit_exclusions_file)"
  if [ -n "$dx" ]; then
    { cat "$BASE_FILE"; echo; grep -v -E '^[[:space:]]*(#|$)' "$dx"; } > "$WORK/exclusions.txt"
    cp -f "$BASE_FILE" "$WORK/exclusions.plan.txt"
    info "exclusions: suite default + $(grep -c -v -E '^[[:space:]]*(#|$)' "$dx") dir-split entr(y/ies) from $(basename "$dx")."
  else
    cp -f "$BASE_FILE" "$WORK/exclusions.txt"
  fi
  BASE_FILE="$WORK/exclusions.txt"
  SQL_ALL="$WORK/sql_all.txt"
  SQL_LIST="$WORK/sql_surviving.txt"
  UNITS_FILE="$WORK/units.tsv"

  # All .sql under a cases dir, as scenario-relative paths with NO leading '/'.
  # CTP's run.sh appends a trailing '/' to the scenario root before computing
  # caseRelativePath = caseFile.substring(rootLen), so the relative path it
  # matches against exclusions has NO leading slash. We must use the same
  # convention or the substring (containPath) match never fires.
  find "$SCN" -type f -name "*.${SUITE_EXT}" -path '*/cases/*' \
    | sed "s#^${SCN}/##" | LC_ALL=C sort > "$SQL_ALL"
  local total; total=$(wc -l < "$SQL_ALL")
  [ "$total" -gt 0 ] || die "no .${SUITE_EXT} case found under $SCN"

  # Subset (--only): keep only cases under the requested scenario-relative dirs.
  # This is how a partial run is expressed — one shard over a filtered case pool —
  # so the whole-suite path and the subset path share every downstream step.
  if [ "${#ARG_ONLY[@]}" -gt 0 ]; then
    local sel="$WORK/only.txt" pfx
    : >"$sel"
    for pfx in "${ARG_ONLY[@]}"; do
      pfx="${pfx#/}"; pfx="${pfx%/}"
      [ -n "$pfx" ] || continue
      [ -e "$SCN/$pfx" ] || die "--only path not in the scenario: $pfx (under $SCN)"
      awk -v p="$pfx/" 'index($0,p)==1' "$SQL_ALL" >> "$sel"
      awk -v p="$pfx" '$0==p' "$SQL_ALL" >> "$sel"
    done
    LC_ALL=C sort -u "$sel" -o "$sel"
    [ -s "$sel" ] || die "--only selected no cases (checked ${#ARG_ONLY[@]} path(s) under $SCN)"
    info "subset: ${#ARG_ONLY[@]} path(s) -> $(wc -l < "$sel") of $total case(s)"
    mv -f "$sel" "$SQL_ALL"
    total=$(wc -l < "$SQL_ALL")
  fi

  # Apply base exclusions (F4 containPath) to get the surviving pool.
  apply_base_exclusions "$SQL_ALL" "$SQL_LIST"
  # The plan is computed over the pool BEFORE the dir-split exclusions, so that
  # adding or removing one never moves any other dir to another shard: every
  # verified shard keeps the same dirs in front of each of its dirs. Order-
  # dependent failures show up exactly when that changes.
  PLAN_LIST="$SQL_LIST"
  if [ -n "$dx" ]; then
    PLAN_LIST="$WORK/sql_plan.txt"
    local keep_base="$BASE_FILE"
    BASE_FILE="$WORK/exclusions.plan.txt"
    apply_base_exclusions "$SQL_ALL" "$PLAN_LIST"
    BASE_FILE="$keep_base"
  fi

  GLOBAL_SQL=$total
  SURVIVING_SQL=$(wc -l < "$SQL_LIST")
  BASE_EXCLUDED=$(( GLOBAL_SQL - SURVIVING_SQL ))
  [ "$SURVIVING_SQL" -gt 0 ] || die "exclusions removed every selected case; nothing to run"

  # Build "<unit>\t<weight>": aggregate the surviving .sql by their unit key and sum
  # weights (measured seconds from --weights, else 1 per .sql; an all-zero unit is
  # clamped to weight 1 so it is still schedulable). The unit key (see unitkey()) is
  # the cases dir by default, the top-level _* dir with --by-category, or the .sql
  # itself with --by-case.
  local wfile="${WEIGHTS_FILE:-/dev/null}"
  # A cases dir in the split registry (split.tsv, dir mode only) becomes <parts>
  # CONTIGUOUS chunks "<dir>#<k>" cut at equal measured weight, so each chunk keeps
  # CQT's order within itself. $WORK/split_map.tsv records "<.sql>\t<chunk>";
  # expand_split_assignment turns the chunk rows back into per-.sql rows.
  : >"$WORK/split_map.tsv"
  awk -F'\t' -v mode="$ARG_UNIT" -v wf="$wfile" -v kw="$COLO_KEEPWHOLE" \
      -v sp="$SPLIT_FILE" -v smap="$WORK/split_map.tsv" '
    function casedir(p,   c) { c=p; if (match(c,/\/cases\//)) c=substr(c,1,RSTART+RLENGTH-2); return c }
    function unitkey(p,   u, c, k) {
      # category (DEFAULT): top-level _* "bulk" — atomic, never split across shards.
      if (mode=="category") { u=p; sub(/\/.*/,"",u); return u }
      # outermost cases dir of p (also the keep-whole lookup key).
      c=casedir(p)
      # keep-whole registry applies ONLY to --by-case (the only mode finer than a cases dir);
      # in dir/category the cases dir / bulk is already whole, so the registry must not pull a
      # cases dir out of its atomic bulk.
      if (mode=="case") return (c in KW) ? c : p
      if (c in K) {                    # dir mode, registered split: contiguous weight chunk
        k=int(cum[c] * K[c] / (tot[c] > 0 ? tot[c] : 1)); if (k >= K[c]) k=K[c]-1
        cum[c]+=wt
        return c "#" k
      }
      return c                         # dir: outermost cases dir
    }
    BEGIN {
      while ((getline l < kw) > 0) if (l!="") KW[l]=1
      while ((getline l < wf) > 0) { m=split(l,a,"\t"); if (m>=2) w[a[1]]=a[2]+0 }
      while ((getline l < sp) > 0) { m=split(l,a,"\t"); if (m>=2 && mode=="dir") K[a[1]]=a[2]+0 }
    }
    FNR==NR { if (mode=="dir") { c=casedir($0); if (c in K) tot[c]+=(($0 in w)?w[$0]:1) }; next }
    { p=$0; wt=(p in w)?w[p]:1; u=unitkey(p); agg[u]+=wt; if (index(u,"#")) print p "\t" u > smap }
    END { for (u in agg) printf "%s\t%d\n", u, (agg[u]<1?1:agg[u]) }
  ' "$PLAN_LIST" "$PLAN_LIST" | LC_ALL=C sort > "$UNITS_FILE"
}

# Replace each split chunk's assignment row "<dir>#<k>\t<shard>" by one row per
# .sql of that chunk, so validate_split's containment proof (a unit claims an .sql
# that equals it or lies under it) and expand_shard_sets see ordinary per-.sql
# units. A no-op without split units.
expand_split_assignment() {
  [ -s "$WORK/split_map.tsv" ] || return 0
  awk -F'\t' '
    FNR==NR { members[$2]=members[$2] $1 "\n"; next }
    index($1,"#") && ($1 in members) { n=split(members[$1], m, "\n"); for (i=1;i<=n;i++) if (m[i]!="") print m[i] "\t" $2; next }
    { print }
  ' "$WORK/split_map.tsv" "$ASSIGN_FILE" > "$ASSIGN_FILE.split" && mv -f "$ASSIGN_FILE.split" "$ASSIGN_FILE"
}

# shell_helper_dirs <scenario_root>
# Print (scenario-relative, one per line) every directory that is neither a case
# dir (has a cases/ beneath it), nor inside one, nor config/ — i.e. the shared
# helper dirs (common/, commonMethod/) shell cases source by relative path. Only
# the outermost such dir is printed; rsync -r ships its contents.
shell_helper_dirs() {
  local scn="$1"
  local cases all
  cases="$(cd "$scn" && find . -type d -name cases -printf '%h\n' | sed 's#^\./##' | LC_ALL=C sort -u)"
  all="$(cd "$scn" && find . -mindepth 1 -type d ! -name cases ! -path '*/cases/*' ! -path './config' ! -path './config/*' \
          | sed 's#^\./##' | LC_ALL=C sort)"
  awk 'NR==FNR { c[$0]=1; next }
       {
         d=$0
         for (k in c) {
           if (k==d || index(k, d "/")==1 || index(d, k "/")==1) next
         }
         # skip a dir whose ancestor was already printed (rsync -r covers it)
         for (h in out) if (index(d, h "/")==1) next
         out[d]=1; print d
       }' <(printf '%s\n' "$cases") <(printf '%s\n' "$all")
}

# apply_base_exclusions <in_sql_list> <out_surviving_list>
# Uses SQL containPath or shell raw-substring matching for the selected suite.
apply_base_exclusions() {
  local in="$1" out="$2"
  # getLineList keeps every non-blank, trimmed line (comments included; they match nothing).
  awk 'NF{ gsub(/^[ \t]+|[ \t]+$/,""); if(length) print }' "$BASE_FILE" > "$WORK/base_entries.txt" 2>/dev/null || :
  [ -s "$WORK/base_entries.txt" ] || : >"$WORK/base_entries.txt"

  # Which root the exclusion entries are relative to is NOT the same for every
  # suite. sql/medium list cases relative to the scenario root (_13_issues/...),
  # but the shell lists are written relative to the REPO root and so carry the
  # scenario dir itself as their first segment (shell/_06_issues/...). Matching
  # scenario-relative paths against those entries silently excludes nothing —
  # every entry misses — so for those suites we prefix the paths, filter, then
  # strip the prefix back off.
  local pfx=""
  [ "$SUITE_STYLE" = "status" ] && pfx="$SUITE_SUBPATH/"
  if [ -z "$pfx" ]; then
    contain_path_filter "$WORK/base_entries.txt" "$in" "$out"
    return
  fi
  awk -v p="$pfx" '{print p $0}' "$in" > "$WORK/base_prefixed_in.txt"
  # The shell runner matches raw substrings, including an individual .sh name;
  # SQL's directory-suffix rule would turn x.sh into x.sh/ and miss that case.
  awk -v entries="$WORK/base_entries.txt" '
    BEGIN { while ((getline e < entries) > 0) if (e!="") ent[++n]=e }
    { for (i=1;i<=n;i++) if (index($0,ent[i])>0) next; print }
  ' "$WORK/base_prefixed_in.txt" > "$WORK/base_prefixed_out.txt"
  awk -v p="$pfx" 'index($0,p)==1 { print substr($0, length(p)+1); next } { print }' \
    "$WORK/base_prefixed_out.txt" > "$out"
}

# contain_path_filter <entries_file> <paths_file> <surviving_out>
# Writes to <surviving_out> the paths NOT matched by ANY entry, using F4 semantics:
#   entry e -> e2 = (e ends with '/' or '.sql') ? e : e+'/' ; match if index(path,e2)>0
contain_path_filter() {
  local entries="$1" paths="$2" out="$3"
  # Read entries in BEGIN via getline (NOT the NR==FNR idiom): when the entries
  # file is EMPTY, NR==FNR stays true for the paths file too, so every path would
  # be misread as an exclusion entry and nothing would survive. getline keeps the
  # two inputs cleanly separate and yields n=0 (exclude nothing) on an empty file.
  awk -v entries="$entries" '
    BEGIN {
      n=0
      while ((getline e < entries) > 0) {
        if (e=="") continue
        if (substr(e,length(e))!="/" && substr(e,length(e)-3)!=".sql") e=e"/"
        ent[++n]=e
      }
    }
    {
      p=$0; excluded=0
      for (i=1;i<=n;i++) { if (index(p,ent[i])>0) { excluded=1; break } }
      if (!excluded) print p
    }
  ' "$paths" > "$out"
}

#####################################################################
# Greedy LPT balancing — assign units to shards, respecting co-locate groups.
#   A "group" is a co-locate group from the registry (its member units must share
#   a shard) or, for every other unit, the unit itself. Groups are packed weight
#   DESC (tie-break: group-id ASC, deterministic) into the least-loaded shard;
#   then each member unit inherits its group's shard. With no registry every group
#   is a singleton, so this reduces exactly to per-unit LPT.
# Produces: ASSIGN ("unit \t shard"), SHARD_LOAD[i] totals.
#####################################################################
ASSIGN_FILE=""
declare -a SHARD_LOAD
balance_units() {
  ASSIGN_FILE="$WORK/assignment.tsv"
  : >"$ASSIGN_FILE"
  local i
  for (( i=0; i<NSHARDS; i++ )); do SHARD_LOAD[i]=0; done

  # (1) unit -> group-id (default = the unit) and per-group summed weight.
  awk -F'\t' -v gidf="$COLO_GIDS" -v ugf="$WORK/unit_gid.tsv" -v gwf="$WORK/group_w.tsv" '
    BEGIN { while ((getline l < gidf) > 0) { m=split(l,a,"\t"); if (m>=2) gid[a[1]]=a[2] } }
    { u=$1; w=$2+0; g=(u in gid)?gid[u]:u; gw[g]+=w; print u "\t" g > ugf }
    END { for (g in gw) printf "%s\t%d\n", g, gw[g] > gwf }
  ' "$UNITS_FILE"

  # (2) LPT over groups (weight desc, group-id asc) -> group -> shard + #LOAD.
  # With a plan pin (resolve_pin), a group whose pinned units share a shard goes
  # there first, whatever its weight is now, and takes its new units with it;
  # LPT then places only the groups the pin does not know, around that load.
  local pin="${PIN_FILE:-/dev/null}"
  LC_ALL=C sort -t"$(printf '\t')" -k2,2nr -k1,1 "$WORK/group_w.tsv" \
    | awk -F'\t' -v n="$NSHARDS" -v pinf="$pin" -v ugf="$WORK/unit_gid.tsv" -v st="$WORK/pin_stats.tsv" '
        BEGIN {
          for (i=0;i<n;i++) load[i]=0
          while ((getline l < pinf) > 0) {
            if (l ~ /^#/) continue
            m=split(l,a,"\t"); if (m>=2 && a[2] ~ /^[0-9]+$/ && a[2]+0 < n) ps[a[1]]=a[2]+0
          }
          # group -> the shard its pinned units share (-1: they disagree, which a
          # colocate.tsv change can do). A group without pinned units is new.
          while ((getline l < ugf) > 0) {
            m=split(l,a,"\t"); u=a[1]; g=a[2]; seen[u]=1
            if (!(u in ps)) continue
            if (!(g in gp)) gp[g]=ps[u]; else if (gp[g]!=ps[u]) gp[g]=-1
          }
          for (u in ps) if (!(u in seen)) gone++
        }
        { g=$1; w=$2+0; order[++ng]=g; gw[g]=w
          if ((g in gp) && gp[g]>=0) { load[gp[g]]+=w; out[g]=gp[g]; kept++ } }
        END {
          for (k=1;k<=ng;k++) { g=order[k]; if (g in out) continue
            best=0; for (i=1;i<n;i++) if (load[i]<load[best]) best=i
            load[best]+=gw[g]; out[g]=best; placed++; if (g in gp) conflict++ }
          for (k=1;k<=ng;k++) print order[k] "\t" out[order[k]]
          for (i=0;i<n;i++) printf "#LOAD\t%d\t%d\n", i, load[i]
          printf "kept\t%d\nplaced\t%d\nconflict\t%d\ngone\t%d\n", kept+0, placed+0, conflict+0, gone+0 > st
        }
      ' > "$WORK/group_shard_raw.tsv"
  grep -v '^#LOAD' "$WORK/group_shard_raw.tsv" > "$WORK/group_shard.tsv"

  # (3) join unit -> group -> shard.
  awk -F'\t' '
    FNR==NR { gs[$1]=$2; next }            # group -> shard
    { print $1 "\t" gs[$2] }               # unit  -> shard
  ' "$WORK/group_shard.tsv" "$WORK/unit_gid.tsv" > "$ASSIGN_FILE"

  # capture loads
  while IFS=$'\t' read -r tag idx load; do
    [ "$tag" = "#LOAD" ] && SHARD_LOAD[idx]=$load
  done < <(grep '^#LOAD' "$WORK/group_shard_raw.tsv")
}

#####################################################################
# Expand the unit->shard assignment into per-shard .sql lists (the files each
# shard will MATERIALIZE) and per-shard .sql counts. Each surviving .sql is
# routed to exactly one shard via its unit, so this is an exact partition.
# Also writes a base-only exclusions.txt per shard (belt-and-suspenders: the
# assigned .sql are materialized, the rest are simply never copied).
#####################################################################
declare -a SHARD_NSQL
expand_shard_sets() {
  local i
  rm -f "$WORK/unmapped.txt"
  for (( i=0; i<NSHARDS; i++ )); do
    : >"$WORK/shard_${i}.sql.txt"
    SHARD_NSQL[i]=0
    cp -f "$BASE_FILE" "$WORK/shard_${i}.exclusions.txt"
  done
  awk -F'\t' -v mode="$ARG_UNIT" -v work="$WORK" -v kw="$COLO_KEEPWHOLE" -v sp="$SPLIT_FILE" '
    function unitkey(p,   u, c) {
      if (mode=="category") { u=p; sub(/\/.*/,"",u); return u }
      c=p; if (match(c,/\/cases\//)) c=substr(c,1,RSTART+RLENGTH-2)
      if (mode=="case") return (c in KW) ? c : p
      if (c in K) return p             # split dir: assigned per .sql (expand_split_assignment)
      return c
    }
    BEGIN {
      while ((getline l < kw) > 0) if (l!="") KW[l]=1
      while ((getline l < sp) > 0) { m=split(l,a,"\t"); if (m>=2 && mode=="dir") K[a[1]]=a[2]+0 }
    }
    FNR==NR { sh[$1]=$2; next }                      # ASSIGN: unit -> shard
    {
      p=$0; u=unitkey(p); s=sh[u]
      if (s=="") { print p > (work"/unmapped.txt"); next }
      print p > (work"/shard_" s ".sql.txt")
      cnt[s]++
    }
    END { for (s in cnt) print s"\t"cnt[s] }
  ' "$ASSIGN_FILE" "$SQL_LIST" > "$WORK/shard_nsql.txt"
  while IFS=$'\t' read -r s c; do SHARD_NSQL[$s]=$c; done < "$WORK/shard_nsql.txt"
}

#####################################################################
# Split validation (offline; needs only assignment.tsv + the surviving .sql list,
# so it doubles as the --validate-only self-test seam).
#
# A unit U (a dir path) CLAIMS a .sql P iff P==U (per-case units) or P starts with
# U"/" (dir/category units). A clean split requires every surviving .sql to be
# claimed by EXACTLY ONE shard:
#   * 0 claiming units            -> ORPHAN: no shard would run it.
#   * units on >1 distinct shard  -> AMBIGUOUS: a nested cases dir landed on a
#                                    different shard than its outer dir, so the .sql
#                                    would be materialized in more than one shard.
# Proving this for every .sql proves the unit set is prefix-free (order-safe split
# units never overlap) AND covers the pool exactly once. Aborts (exit 4) otherwise.
#####################################################################
validate_split() {
  local nsql; nsql="$(wc -l < "$SQL_LIST")"
  : "${SURVIVING_SQL:=$nsql}"
  info "validating split over $nsql surviving .sql (each must be claimed by exactly one shard) ..."

  # Exact-key routing guard (real/dry-run path only; --validate-only has no WORK
  # tree): a .sql whose unit key is absent from the assignment was routed nowhere.
  if [ -n "${WORK:-}" ] && [ -s "$WORK/unmapped.txt" ]; then
    err "split validation FAILED: $(wc -l < "$WORK/unmapped.txt") surviving .sql not routed to any shard. Head:"
    sed -n '1,20p' "$WORK/unmapped.txt" >&2
    exit 4
  fi

  # Containment proof, independent of how routing was computed. For each .sql, walk
  # its path prefixes (and itself) and match against the assigned units.
  if awk -F'\t' '
        FNR==NR { U[$1]=$2; next }                   # ASSIGN: unit -> shard
        {
          p=$0; nclaim=0; sset=""
          if (p in U) { nclaim++; sset="<" U[p] ">" }
          L=length(p)
          for (k=1;k<=L;k++) {
            if (substr(p,k,1)=="/") {
              cand=substr(p,1,k-1)
              if (cand in U) {
                nclaim++; tag="<" U[cand] ">"
                if (index(sset,tag)==0) sset=sset tag
              }
            }
          }
          if (nclaim==0) { printf "ORPHAN (no assigned unit claims): %s\n", p > "/dev/stderr"; bad++; next }
          ndist=gsub(/>/,">",sset)                    # one ">" per distinct shard tag
          if (ndist>1) { printf "ORPHAN/AMBIGUOUS (claimed by %d units across shards %s): %s\n", nclaim, sset, p > "/dev/stderr"; bad++ }
        }
        END { exit (bad>0)?1:0 }
      ' "$ASSIGN_FILE" "$SQL_LIST"; then
    info "split valid: all $nsql surviving .sql alive in exactly one shard."
  else
    err "split validation FAILED: orphaned or cross-shard-ambiguous .sql (see ORPHAN lines above)."
    exit 4
  fi
}

#####################################################################
# Upstream composes the runtime CTP conf inside the container and applies
# TEST_SCENARIO / TEST_EXCLUDE there. Repo-relative mounts also preserve the
# medium data_file path; namespace isolation preserves ports and SHM IDs.
#
# Optional --conf: a cubrid.conf whose server parameters this run should use.
# WHERE they have to go differs by suite, because who starts the server differs:
#
#   sql / medium : CTP starts the server and writes its conf from the
#                  [<suite>/cubrid.conf] SECTION of its own suite conf. So the
#                  parameters are merged into that section of the shard's CTP
#                  copy (keys present there are replaced, new keys appended).
#                  Dropping a cubrid.conf next to it would do nothing at all.
#   shell / HA   : the cases start servers themselves (init.sh), from the
#                  install's own $CUBRID/conf/cubrid.conf. So the file replaces
#                  the one in the shard's install copy.
install_suite_conf() {
  local d="$1"
  [ -n "$ARG_CONF" ] || return 0

  if [ "$SUITE_STYLE" = "status" ]; then
    if [ "$ARG_OVERLAY" -eq 1 ]; then
      die "--conf with --overlay is not supported for suite '$ARG_SUITE': the install is not copied, so its conf cannot be replaced per shard."
    fi
    cp -f "$ARG_CONF" "$d/CUBRID/conf/cubrid.conf"
    info "conf: $(basename "$ARG_CONF") -> shard install conf/cubrid.conf"
    return
  fi

  local target="$d/CTP/$SUITE_CONF"
  [ -f "$target" ] || die "--conf: cannot find the shard's CTP conf to merge into: $target"
  merge_params_into_section "$target" "$SQL_CONF_SECTION" "$ARG_CONF"
  info "conf: merged $(basename "$ARG_CONF") into $SUITE_CONF ${SQL_CONF_SECTION}"
}

# The section CTP's run.sh reads server parameters from, for sql AND medium
# (ini -s "sql/cubrid.conf"; medium_dev.conf has no [medium/cubrid.conf]).
readonly SQL_CONF_SECTION="[sql/cubrid.conf]"

# Set the KEY=VALUE lines of $3 inside section $2 of the ini-style conf $1.
# Keys already in the section are replaced. New keys go at the end of the
# section. A missing section is appended together with them.
merge_params_into_section() {
  local target="$1" section="$2" params="$3"
  awk -v userconf="$params" -v section="$section" '
    function flushnew() {
      for (k in u) if (!(k in done)) { print k "=" u[k]; done[k]=1 }
    }
    BEGIN {
      while ((getline l < userconf) > 0) {
        if (l ~ /^[ \t]*[#;]/ || l ~ /^[ \t]*$/ || l ~ /^[ \t]*\[/) continue
        if (match(l, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/)) {
          k = l; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
          v = l; sub(/^[^=]*=/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v)
          u[k] = v
        }
      }
    }
    $0 == section { insec = 1; seen = 1; print; next }
    /^[ \t]*\[/ && insec { flushnew(); insec = 0; print; next }
    insec && match($0, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/) {
      k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k)
      if (k in u) { print k "=" u[k]; done[k] = 1; next }
      print; next
    }
    { print }
    END { if (insec) flushnew(); else if (!seen) { print section; flushnew() } }
  ' "$target" > "$target.merged" && mv -f "$target.merged" "$target"
}

# Server parameters pinned for CTP runs (D8), so a run tests the engine as shipped
# and not whatever an install's conf/cubrid.conf was tuned to (`just conf` copies
# this repo's campaign cubrid.conf, parallelism=24 included, into every install).
#   every suite : the engine's own defaults (system_parameter.c):
#                 data_buffer_size=512M (32768 pages of the default 16K page),
#                 parallelism=4, max_parallel_workers=100
#   sql/medium  : also max_clients=20. CQT holds one connection and no sql/medium
#                 case mentions max_clients, while 16+ shards share this host's
#                 pids cgroup (pids.max 8192). shell/HA cases open connections of
#                 their own and 124 of them set max_clients, so they keep the
#                 install's value.
# Pinned BEFORE --conf is applied, so an explicit --conf still wins.
# CTP_PIN_PARAMS=0 leaves the install's values alone.
#   sql/medium : into [sql/cubrid.conf] of the shard's CTP conf, which CTP writes
#                into the server conf.
#   shell/HA   : into [common] of the shard install's conf/cubrid.conf, which the
#                cases start their servers from.
PIN_PARAMS="${CTP_PIN_PARAMS:-1}"
readonly PINNED_ALL="data_buffer_size=512M parallelism=4 max_parallel_workers=100"
readonly PINNED_SQL="max_clients=20"
resolve_server_params() {
  case "$PIN_PARAMS" in
    0|1) : ;;
    *) die "CTP_PIN_PARAMS must be 0 or 1 (got: '$PIN_PARAMS')" ;;
  esac
}
# The KEY=VALUE list pinned for this suite; empty when pinning is off.
pinned_params() {
  [ "$PIN_PARAMS" -eq 1 ] || return 0
  if [ "$SUITE_STYLE" = "status" ]; then
    printf '%s\n' "$PINNED_ALL"
  else
    printf '%s\n' "$PINNED_ALL $PINNED_SQL"
  fi
}
# What provenance and the plan summary show: the pinned list, or "off".
pinned_label() {
  local l; l="$(pinned_params)"
  printf '%s' "${l:-off}"
}
pin_server_params() {
  local d="$1" params="$WORK/pinned_params.$(basename "$1").conf" list kv
  list="$(pinned_params)"
  [ -n "$list" ] || return 0
  : > "$params"
  for kv in $list; do printf '%s\n' "$kv" >> "$params"; done
  if [ "$SUITE_STYLE" = "status" ]; then
    if [ "$ARG_OVERLAY" -eq 1 ]; then
      warn "server params: not pinned for '$ARG_SUITE' with --overlay (the install is not copied)."
      return 0
    fi
    if [ ! -f "$d/CUBRID/conf/cubrid.conf" ]; then
      warn "server params: $d/CUBRID/conf/cubrid.conf is missing; not pinned."
      return 0
    fi
    merge_params_into_section "$d/CUBRID/conf/cubrid.conf" "[common]" "$params"
  else
    if [ -z "$SUITE_CONF" ] || [ ! -f "$d/CTP/$SUITE_CONF" ]; then
      warn "server params: the shard's CTP suite conf ($d/CTP/${SUITE_CONF:-<unset>}) is missing; not pinned."
      return 0
    fi
    merge_params_into_section "$d/CTP/$SUITE_CONF" "$SQL_CONF_SECTION" "$params"
  fi
}

#####################################################################
# Emit the plan artifacts into --out (always; used by --dry-run and real runs).
#####################################################################
emit_plan() {
  mkdir -p "$OUT"
  cp -f "$ASSIGN_FILE" "$OUT/assignment.tsv"
  cp -f "$UNITS_FILE"  "$OUT/units.tsv"
  local i
  : >"$OUT/plan.tsv"
  printf '# shard\tsql_count\tweight\n' >>"$OUT/plan.tsv"
  for (( i=0; i<NSHARDS; i++ )); do
    printf '%d\t%d\t%d\n' "$i" "${SHARD_NSQL[i]:-0}" "${SHARD_LOAD[i]:-0}" >>"$OUT/plan.tsv"
    mkdir -p "$OUT/shard_${i}"
    cp -f "$WORK/shard_${i}.exclusions.txt" "$OUT/shard_${i}/exclusions.txt"
    cp -f "$WORK/shard_${i}.sql.txt" "$OUT/shard_${i}/assigned_cases.txt" 2>/dev/null || :
  done
  info "plan written to $OUT (assignment.tsv, units.tsv, plan.tsv, shard_*/{exclusions.txt,assigned_cases.txt})"
}

print_plan_summary() {
  info "split summary:"
  printf '  global .sql:        %d\n' "$GLOBAL_SQL"
  printf '  base-excluded .sql: %d\n' "$BASE_EXCLUDED"
  printf '  surviving .sql:     %d\n' "$SURVIVING_SQL"
  local modelabel
  case "$ARG_UNIT" in
    dir)      modelabel="cases-dir" ;;
    category) modelabel="bulk(_*)" ;;
    case)     modelabel="per-case" ;;
    *)        modelabel="$ARG_UNIT" ;;
  esac
  printf '  units:              %d  (mode: %s, weight: %s)\n' "$(wc -l < "$UNITS_FILE")" \
    "$modelabel" \
    "$([ -n "$WEIGHTS_FILE" ] && echo measured-time || echo count)"
  # awk line/group counts (always exit 0 and emit exactly one integer, even on an
  # empty file — unlike `grep -c`, which prints 0 AND exits 1, doubling under `||`).
  local kwn=0 grpn=0
  [ -r "$COLO_KEEPWHOLE" ] && kwn=$(awk 'END{print NR+0}' "$COLO_KEEPWHOLE" 2>/dev/null)
  [ -r "$COLO_GIDS" ] && grpn=$(awk -F'\t' '{c[$2]++} END{m=0; for(g in c) if(c[g]>1) m++; print m+0}' "$COLO_GIDS" 2>/dev/null)
  printf '  colocate:           %d dir(s), %d multi-dir group(s) pinned  (keep-whole active only with --by-case)\n' "${kwn:-0}" "${grpn:-0}"
  printf '  shards:             %d\n' "$NSHARDS"
  printf '  env passthrough (fixed): CUBRID CTP_HOME CUBRID_DATABASES WORKDIR TEST_REPORT TZ LC_ALL TEST_SCENARIO TEST_EXCLUDE\n'
  printf '  env passthrough (--env, %d): %s\n' "${#ARG_ENV[@]}" "${ARG_ENV[*]:-<none>}"
  printf '  volatile:           %s\n' "${VOLATILE_TARGETS:-off}"
  printf '  pinned params:      %s\n' "$(pinned_label)"
  printf '  plan:               %s\n' "$PLAN_LABEL"
  printf '  %-7s %-10s %s\n' "shard" "sql" "weight$([ -n "$WEIGHTS_FILE" ] && echo '(s)')"
  local i
  for (( i=0; i<NSHARDS; i++ )); do
    printf '  %-7d %-10d %d\n' "$i" "${SHARD_NSQL[i]:-0}" "${SHARD_LOAD[i]:-0}"
  done
}

#####################################################################
# Per-shard working-copy construction (host side).
#####################################################################
build_shard_workdir() {
  local i="$1" d="$OUT/shard_${i}"
  mkdir -p "$d"
  info "shard $i: building working copies under $d ..."

  # build -> CUBRID: a run directory over the read-only install (scripts/rundir.sh).
  # Its directories are writable and its conf is a copy, so CTP's conf rewrites and
  # locale libraries stay in the shard; the install's files are shared through links.
  "$REPO_DIR/scripts/rundir.sh" "$ARG_BUILD" "$d/CUBRID" >/dev/null
  if true; then
    # Locale speedup (D6): CTP keeps need_make_locale=yes, but make_locale is the
    # single slowest startup step (~60-90s of gcc, repeated in EVERY shard). Ship a
    # prebuilt libcubrid_all_locales.so + an early-exit make_locale.sh so CTP's
    # make_locale finds the .so already present and returns immediately instead of
    # recompiling. The locale is thus compiled at most ONCE (offline), not per shard.
    if [ -n "$LOCALE_SO" ]; then
      rm -f "$d/CUBRID/lib/libcubrid_all_locales.so" "$d/CUBRID/bin/make_locale.sh"
      cp -f "$LOCALE_SO" "$d/CUBRID/lib/libcubrid_all_locales.so"
      cp -f "$LOCALE_SCRIPT" "$d/CUBRID/bin/make_locale.sh"
      chmod +x "$d/CUBRID/bin/make_locale.sh" 2>/dev/null || :
    fi
  fi

  # testcases -> private scenario copy holding ONLY this shard's slice.
  #
  # sql/medium: two passes over case FILES. Pass A takes the tree, answers and
  # everything except the test .sql; pass B adds back exactly the .sql assigned
  # here. CTP then finds precisely this shard's cases, with no giant exclusion
  # list and no O(n^2) path matching.
  #
  # shell/ha_shell: whole test DIRECTORIES, because a shell case is not one file
  # — its dir also carries .answer files, helper .sh, .c and .java sources the
  # case compiles at run time. A file-level split would leave those behind.
  #
  # The copy is laid out repo-relative (scenario under <repo>/<subpath>) so the
  # stock CTP confs, which resolve ${HOME}/<repo>/..., are correct unmodified.
  # The host worktree is never written to.
  local scn_dst="$d/testcases/$SUITE_SUBPATH"
  mkdir -p "$scn_dst"
  if [ "$SUITE_EXT" = "sh" ]; then
    sed 's#/cases/[^/]*$##' "$WORK/shard_${i}.sql.txt" | LC_ALL=C sort -u > "$WORK/shard_${i}.dirs.txt"
    # config/ holds the exclusion list CTP reads; ship every non-case top file too.
    # -r is NOT redundant with -a here: --files-from turns recursion OFF, so
    # without it rsync creates the listed DIRECTORIES and copies none of their
    # contents — a shard that runs zero cases and reports a green empty pass.
    ( cd "$SCN" && rsync -a -r --exclude='*.result' --exclude='*.log' \
        --files-from="$WORK/shard_${i}.dirs.txt" ./ "$scn_dst/" )
    # Helper dirs (common/, commonMethod/): shared libraries a case sources by a
    # relative path (`. ../../../common/lib_csql_io.sh`). They hold no cases/, so
    # the dir list above never names them and every case that sources one failed
    # locally with a fake "No such file" (wf228, 2026-09-10). Ship all of them;
    # they are a handful of tiny dirs.
    shell_helper_dirs "$SCN" > "$WORK/shard_${i}.helpers.txt"
    if [ -s "$WORK/shard_${i}.helpers.txt" ]; then
      ( cd "$SCN" && rsync -a -r --exclude='*.result' --exclude='*.log' \
          --files-from="$WORK/shard_${i}.helpers.txt" ./ "$scn_dst/" )
      info "shard $i: $(wc -l < "$WORK/shard_${i}.helpers.txt") helper dir(s) shipped alongside the cases."
    fi
    [ -d "$SCN/config" ] && rsync -a "$SCN/config" "$scn_dst/" || :
    find "$SCN" -maxdepth 1 -type f -exec cp -f {} "$scn_dst/" \; 2>/dev/null || :
  elif command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude='*.sql' --exclude='*.result' --exclude='*.log' "$SCN/" "$scn_dst/"
    # (a file list, so recursion is moot here — unlike the dir list above.)
    rsync -a --files-from="$WORK/shard_${i}.sql.txt" "$SCN/" "$scn_dst/"
  else
    cp -a "$SCN/." "$scn_dst/"
    find "$scn_dst" -type f \( -name '*.result' -o -name '*.log' \) -delete
    ( cd "$scn_dst" && find . -type f -name '*.sql' -path '*/cases/*' | sed 's#^\./##' \
        | grep -vxF -f "$WORK/shard_${i}.sql.txt" | tr '\n' '\0' | xargs -0 -r rm -f )
  fi

  # Materialization is the one step whose failure looks like success: a shard whose
  # scenario copy came out empty runs zero cases and reports a clean pass. (It has
  # happened: --files-from turns rsync's recursion off, so a directory list copied
  # the dirs and none of their contents.) So count what actually landed and refuse
  # to launch on a shortfall.
  local want got
  want="$(wc -l < "$WORK/shard_${i}.sql.txt")"
  got="$(find "$scn_dst" -type f -name "*.${SUITE_EXT}" -path '*/cases/*' 2>/dev/null | wc -l)"
  if [ "$got" -lt "$want" ]; then
    die "shard $i: materialized $got of $want assigned case file(s) under $scn_dst — refusing to run a partially-copied scenario (a shard that silently runs nothing looks like a pass)."
  fi
  info "shard $i: $got case file(s) materialized (assigned $want)."

  # CTP -> per-shard copy (drop stale run artifacts), then wire conf + exclusions
  mkdir -p "$d/CTP"
  if command -v rsync >/dev/null 2>&1; then
    # The host CTP_HOME accumulates every past run's results, for every suite.
    # Copying them into the shard makes this run's own result scan pick up
    # someone else's months-old failures (seen: a June shell failure surfacing in
    # a September sql run's failed.list). Keep the DIRECTORIES (CTP writes into
    # them) and drop their contents.
    rsync -a \
      --exclude='.output_*.log' --exclude='.script_cont_*' \
      --exclude='sql/result/*' --exclude='sql/log/*' \
      --exclude='result/*' --exclude='log/*' \
      "$ARG_CTP/" "$d/CTP/"
  else
    cp -a "$ARG_CTP/." "$d/CTP/"
    rm -rf "$d/CTP"/.output_*.log "$d/CTP"/.script_cont_* "$d/CTP"/sql/result/* "$d/CTP"/sql/log/* \
           "$d/CTP"/result/* "$d/CTP"/log/* 2>/dev/null || :
  fi
  # the pinned CTP comes from the read-only nix store
  chmod -R u+w "$d/CTP"
  cp -f "$WORK/shard_${i}.exclusions.txt" "$d/CTP/conf/ctprun_exclusions.txt"
  pin_server_params "$d"
  install_suite_conf "$d"

  # fresh per-shard CUBRID_DATABASES + report dir
  mkdir -p "$d/CUBRID_DB"
  : >"$d/CUBRID_DB/databases.txt"
  mkdir -p "$d/out" "$d/reports"
  # Upper/work dirs of the volatile database overlay (workspace ADR 0017 D7). They must
  # be fresh: a volatile workdir refuses a second mount. Its work/ is mode 000 and owned
  # by the namespace's root, so only a user namespace can remove it.
  if [ -n "$VOLATILE_TARGETS" ]; then
    rm -rf "$d/volatile" 2>/dev/null || unshare -Ur rm -rf "$d/volatile"
    mkdir -p "$d/volatile"
  fi
}

#####################################################################
# Decide how cub_server core dumps can be captured out of each shard.
# The kernel's core_pattern is a single global knob (not namespaced), but the
# path is resolved in the crashing process's mount-ns, so:
#   - absolute path  -> bind-mount the shard's cores/ over that dir (cores land on
#                       the host automatically). [CORE_MODE=path]
#   - relative       -> cores land in the server's cwd (under the mounted CUBRID*/
#                       CTP copies); collect them after the run.          [relative]
#   - pipe (|handler)-> the host's coredump handler gets them; we cannot capture
#                       per-shard, only warn.                              [pipe]
#####################################################################
CORE_MODE="none"
CORE_DIR=""
setup_core_capture() {
  local pat; pat="$(cat /proc/sys/kernel/core_pattern 2>/dev/null)"
  case "$pat" in
    \|*) CORE_MODE="pipe"
         err "WARNING: core_pattern pipes to a handler ('$pat'); per-shard cores cannot be"
         err "         captured. Cores (if any) go to the host coredump store." ;;
    /*)  CORE_MODE="path"; CORE_DIR="$(dirname "$pat")"
         info "core capture: bind-mounting each shard's cores/ over '$CORE_DIR' (pattern '$pat')." ;;
    ?*)  CORE_MODE="relative"
         info "core capture: core_pattern is relative ('$pat'); will collect cores from shard copies." ;;
    *)   CORE_MODE="none"
         err "WARNING: core_pattern is empty; cores may be disabled on this host." ;;
  esac
}

#####################################################################
# Launch one shard: its namespaces run ctp/shard_entry.sh (ADR 0001 D8).
#####################################################################
SHM_SIZE="2g"

# Where shard core dumps are kept. Each shard's cores/ is a symlink into
# $CORE_STORE/<run>/shard_N, so the bind-mount, the watchdog and the collector see the
# same directory, and deleting a run leaves its cores in the store until they are
# removed there. Default: next to the run.
CORE_STORE="${CTP_CORE_STORE:-}"

declare -a SHARD_PIDS
# The shard's settings for shard_entry.sh. TOOLS_PATH is this shell's PATH: inside
# `nix develop` it holds CTP's tools, the CI toolchain (make_locale) and Temurin.
write_shard_env() {
  local d="$1" kv extra=""
  if [ "${#ARG_ENV[@]}" -gt 0 ]; then
    for kv in "${ARG_ENV[@]}"; do extra+="$kv"$'\n'; done
  fi
  {
    printf 'DIRECT=%q\n' "$(( 1 - NS_MODE ))"
    printf 'SUITE=%q\n' "$ARG_SUITE"
    printf 'TCREPO=%q\n' "$SUITE_TCREPO"
    printf 'SUBPATH=%q\n' "$SUITE_SUBPATH"
    printf 'CORE_DIR=%q\n' "$([ "$CORE_MODE" = path ] && echo "$CORE_DIR")"
    printf 'VOLATILE=%q\n' "$([ -n "$VOLATILE_TARGETS" ] && echo 1 || echo 0)"
    printf 'EATMYDATA=%q\n' "$([ "$USE_EATMYDATA" -eq 1 ] && echo "$CUBRID_NIX_EATMYDATA")"
    printf 'SHM_SIZE=%q\n' "$SHM_SIZE"
    printf 'TOOLS_PATH=%q\n' "$PATH"
    printf 'JAVA_HOME=%q\n' "${JAVA_HOME:?JAVA_HOME is unset; run inside nix develop}"
    printf 'TZDIR=%q\n' "${TZDIR:?TZDIR is unset; run inside nix develop}"
    printf 'LOCALE_ARCHIVE=%q\n' "${LOCALE_ARCHIVE:-}"
    # the exclusion file sits in the shard's CTP conf dir; shard_entry.sh resolves it
    if [ "$ARG_EXCLUDE_SET" -eq 1 ] && [ -z "$ARG_EXCLUDE" ]; then
      printf 'EXCLUDE_NAME=\n'
    else
      printf 'EXCLUDE_NAME=%q\n' "ctprun_exclusions.txt"
    fi
    printf 'EXTRA_ENV=%q\n' "$extra"
  } > "$d/shard.env"
}

launch_shard() {
  local i="$1" d="$OUT/shard_${i}"
  SHARD_NAMES[i]="shard_${i}"
  if [ -n "$CORE_STORE" ] && mkdir -p "$CORE_STORE/$(basename "$OUT")/shard_${i}" 2>/dev/null; then
    ln -sfn "$CORE_STORE/$(basename "$OUT")/shard_${i}" "$d/cores"
  else
    [ -z "$CORE_STORE" ] || warn "core store $CORE_STORE not writable; keeping shard $i cores under $d/cores."
    mkdir -p "$d/cores"
  fi
  write_shard_env "$d"
  info "shard $i: launching (unshare -Urmipnf, ctp.sh ${SUITE_CAT}) ..."
  if [ "$NS_MODE" -eq 1 ]; then
    # --kill-child: when unshare dies, the shard's PID 1 dies, and with it every process
    # of the shard's PID namespace.
    unshare -Urmipnf --mount-proc --kill-child bash "$SELF_DIR/shard_entry.sh" "$d" \
      </dev/null >"$d/launch.log" 2>&1 &
  else
    bash "$SELF_DIR/shard_entry.sh" "$d" </dev/null >"$d/launch.log" 2>&1 &
  fi
  SHARD_PIDS[i]=$!
}

# The shard's PID 1 (unshare's child), for entering its namespaces.
shard_init_pid() {
  pgrep -P "${SHARD_PIDS[$1]}" 2>/dev/null | head -1
}

#####################################################################
# Core watchdog: while shards run, poll the shard working copies (bind-mounted
# host dirs, so cores are visible live even in relative core_pattern mode) and
# the free disk at --out. It runs in both modes:
#   - disk floor breach: stop ALL shard containers, whatever the mode.
#   - --abort-on-core (default): the first REAL core dump (file(1)-verified,
#     not just a core.* name) stops ALL shards, so a crash-looping server cannot
#     fill the disk with cores (2026-08-31 incident: 1.1T of cores on /home).
#   - --no-abort-on-core: keep collecting cores, but stop a shard whose server
#     can no longer run cases — CRASH_LOOP_CORES cores with no passing case in
#     between, or MAX_SHARD_CORES cores in total. The other shards keep running.
#     2026-09-23: a crashed database crashed again in recovery on every restart;
#     with the watchdog off the shard wrote 170 cores while every remaining case
#     waited out a 3-minute connect timeout (~2000 cases left = days).
# Reasons are left in $OUT/.abort_reason (whole run) and $OUT/.dead_shards (one
# line per stopped shard) for aggregate() to report; collection still runs.
#####################################################################
CORE_POLL_SECS=5   # 2026-09-03 #199: a crash-looping shard produced 13 cores (16GB) inside one 30s poll; 5s bounds it to ~2 per shard
DISK_FLOOR_GB=30
CRASH_LOOP_CORES="${CTP_CRASH_LOOP_CORES:-5}"
MAX_SHARD_CORES="${CTP_MAX_SHARD_CORES:-20}"
# Hang watchdog: a shard whose container printed nothing for HANG_SECS is hung.
# CTP's sql/medium have no per-case timeout, so without this a hang stops the
# whole run forever (2026-09-24: one of 16 shards sat 35 minutes in a PX sort
# worker <-> leader mutex deadlock, xmilex-git/workspace issue). The longest
# single sql case measured is 69s, so 300s is far outside normal. On by default
# for sql/medium only (see parse_args); CTP_HANG_SECS=<s> sets it for any suite,
# CTP_HANG_SECS=0 turns it off.
HANG_SECS="${CTP_HANG_SECS:-300}"
HANG_POLL_SECS=30
WATCHDOG_PID=""

# Evidence from a hung shard, taken before it is stopped: its processes go with
# its namespaces, so this is the only chance. Saved under shard_N/hang/.
capture_hang_evidence() {
  local i="$1" h="$OUT/shard_$1/hang" db="" ns
  case "$ARG_SUITE" in sql) db=basic ;; medium) db=mdb ;; esac
  mkdir -p "$h"
  tail -n 40 "$OUT/shard_$1/console.ts.log" > "$h/console.tail.txt" 2>&1 || :
  ns="$(shard_init_pid "$i")"
  [ -n "$ns" ] || { echo "shard $i: its namespaces are gone" > "$h/cub_server.stacks.txt"; return 0; }
  local -a enter=( nsenter -t "$ns" -U -m -n -p -i --preserve-credentials )
  "${enter[@]}" env DB="$db" PATH="$PATH" bash -c '
    export CUBRID=/home/CUBRID PATH=/home/CUBRID/bin:$PATH
    for pid in $(pgrep -x cub_server); do
      echo "=== cub_server pid $pid: $(tr "\0" " " < /proc/$pid/cmdline)"
      grep -E "^(Threads|VmRSS)" /proc/$pid/status
      timeout 180 gdb -p "$pid" -batch -ex "thread apply all bt" 2>&1
    done' > "$h/cub_server.stacks.txt" 2>&1 || :
  "${enter[@]}" env PATH="$PATH" bash -c '
    for pid in $(pgrep -f "java .*-Xms1024m"); do
      echo "=== java pid $pid"; timeout 60 jstack "$pid" 2>&1
    done' > "$h/cqt.jstack.txt" 2>&1 || :
  if [ -n "$db" ]; then
    "${enter[@]}" env DB="$db" PATH="$PATH" bash -c '
      export CUBRID=/home/CUBRID CUBRID_DATABASES=/home/CUBRID_DB PATH=/home/CUBRID/bin:$PATH
      echo "=== tranlist"; timeout 60 cubrid tranlist "$DB" 2>&1
      echo "=== lockdb";   timeout 120 cubrid lockdb "$DB" 2>&1' > "$h/tran_lock.txt" 2>&1 || :
  fi
}

# Verified core dumps of one shard; file(1) runs once per path (the cache lives
# in the watchdog subshell). core_pattern names have no whitespace
# (core.%e.%p.%h.%t), so word splitting the find output is safe. Sets SHARD_CORE_COUNT.
declare -A CORE_SEEN=()
count_shard_cores() {
  local d="$1" f n=0
  for f in $(find "$d/cores/" "$d/CUBRID" "$d/CUBRID_DB" "$d/CTP" "$d/volatile" -type f -name 'core.*' 2>/dev/null); do
    if [ -z "${CORE_SEEN[$f]+x}" ]; then
      if file -b "$f" 2>/dev/null | grep -q 'core file'; then CORE_SEEN[$f]=1; else CORE_SEEN[$f]=0; fi
    fi
    if [ "${CORE_SEEN[$f]}" = 1 ]; then n=$((n + 1)); fi
  done
  SHARD_CORE_COUNT=$n
}

# Cases one shard has passed so far: the sql/medium runner log and the shell
# runners' feedback.log both mark a passing case with [OK]. Sets SHARD_PASS_COUNT.
count_shard_passes() {
  SHARD_PASS_COUNT="$(cat "$1"/CTP/sql/log/*.log "$1"/CTP/result/*/current_runtime_logs/feedback.log 2>/dev/null \
    | grep -c '\[OK\]' || :)"
}

# Stop whole shards by index: SIGKILL their unshare process; --kill-child then kills
# the shard's PID 1, which takes every process of its PID namespace with it. kill, not
# stop: every second of a crash-looping server is another ~2.4GB core.
stop_shards() {
  local i
  for i in "$@"; do
    [ -n "$i" ] || continue
    kill -9 "${SHARD_PIDS[i]}" 2>/dev/null || :
  done
  # Without namespaces the servers are daemons outside the shard's process tree; the
  # environment is dedicated to the run (see host_preflight), as CTP's own teardown assumes.
  [ "$NS_MODE" -eq 1 ] || pkill -9 -u "$(id -u)" '^cub_' 2>/dev/null || :
}

start_core_watchdog() {
  rm -f "$OUT/.abort_reason" "$OUT/.dead_shards"
  (
    declare -a cores_prev=() cores_mark=() pass_mark=() stopped=()
    hang_checked=$SECONDS
    while :; do
      sleep "$CORE_POLL_SECS"
      reason=""
      avail_gb="$(df -BG --output=avail "$OUT" 2>/dev/null | tail -1 | tr -dc '0-9')"
      if [ -n "$avail_gb" ] && [ "$avail_gb" -lt "$DISK_FLOOR_GB" ]; then
        reason="disk floor breached: ${avail_gb}GB available < ${DISK_FLOOR_GB}GB"
      elif [ "$ARG_ABORT_ON_CORE" -eq 1 ]; then
        for f in $(find "$OUT"/shard_*/CUBRID "$OUT"/shard_*/CUBRID_DB "$OUT"/shard_*/CTP "$OUT"/shard_*/volatile "$OUT"/shard_*/cores/ \
                     -type f -name 'core.*' 2>/dev/null); do
          if file -b "$f" 2>/dev/null | grep -q 'core file'; then reason="core dump detected: $f"; break; fi
        done
      else
        for (( i=0; i<${#SHARD_NAMES[@]}; i++ )); do
          [ "${stopped[i]:-0}" -eq 0 ] || continue
          count_shard_cores "$OUT/shard_${i}"
          [ "$SHARD_CORE_COUNT" -ne "${cores_prev[i]:-0}" ] || continue
          # A case passed since the last new core: the server is alive, restart the count.
          count_shard_passes "$OUT/shard_${i}"
          if [ "$SHARD_PASS_COUNT" -gt "${pass_mark[i]:-0}" ]; then
            pass_mark[i]=$SHARD_PASS_COUNT
            cores_mark[i]=${cores_prev[i]:-0}
          fi
          cores_prev[i]=$SHARD_CORE_COUNT
          why=""
          if [ $(( SHARD_CORE_COUNT - ${cores_mark[i]:-0} )) -ge "$CRASH_LOOP_CORES" ]; then
            why="crash loop: $(( SHARD_CORE_COUNT - ${cores_mark[i]:-0} )) core dumps with no passing case in between (CTP_CRASH_LOOP_CORES=$CRASH_LOOP_CORES)"
          elif [ "$SHARD_CORE_COUNT" -ge "$MAX_SHARD_CORES" ]; then
            why="core cap: $SHARD_CORE_COUNT core dumps (CTP_MAX_SHARD_CORES=$MAX_SHARD_CORES)"
          fi
          if [ -n "$why" ]; then
            stopped[i]=1
            printf 'shard %d: %s\n' "$i" "$why" >> "$OUT/.dead_shards"
            echo "[ctp-run] CRASH-LOOP WATCHDOG: shard $i $why — stopping that shard; the others keep running." >&2
            stop_shards "$i"
          fi
        done
      fi
      if [ "$HANG_SECS" -gt 0 ] && [ $(( SECONDS - hang_checked )) -ge "$HANG_POLL_SECS" ]; then
        hang_checked=$SECONDS
        now="$(date +%s)"
        for (( i=0; i<${#SHARD_NAMES[@]}; i++ )); do
          [ "${stopped[i]:-0}" -eq 0 ] || continue
          kill -0 "${SHARD_PIDS[i]}" 2>/dev/null || continue
          # the shard's last output line is the console log's last write
          last_s="$(stat -c %Y "$OUT/shard_${i}/console.log" 2>/dev/null || echo "$now")"
          [ $(( now - last_s )) -ge "$HANG_SECS" ] || continue
          stopped[i]=1
          why="hang: no output for $(( now - last_s ))s (CTP_HANG_SECS=$HANG_SECS); stacks in shard_${i}/hang/"
          printf 'shard %d: %s\n' "$i" "$why" >> "$OUT/.dead_shards"
          echo "[ctp-run] HANG WATCHDOG: shard $i $why — capturing evidence, then stopping that shard; the others keep running." >&2
          capture_hang_evidence "$i" || :
          stop_shards "$i"
        done
      fi
      if [ -n "$reason" ]; then
        printf '%s\n' "$reason" > "$OUT/.abort_reason"
        echo "[ctp-run] ABORT-ON-CORE: $reason — stopping all shards." >&2
        stop_shards "${!SHARD_PIDS[@]}"
        exit 0
      fi
    done
  ) &
  WATCHDOG_PID=$!
  if [ "$HANG_SECS" -gt 0 ]; then
    info "hang watchdog on: a shard silent for ${HANG_SECS}s is stopped after its stacks are saved (CTP_HANG_SECS)."
  fi
  if [ "$ARG_ABORT_ON_CORE" -eq 1 ]; then
    info "abort-on-core watchdog started (pid $WATCHDOG_PID, poll ${CORE_POLL_SECS}s, disk floor ${DISK_FLOOR_GB}GB)."
  else
    info "crash-loop watchdog started (pid $WATCHDOG_PID, poll ${CORE_POLL_SECS}s, disk floor ${DISK_FLOOR_GB}GB; a shard stops after ${CRASH_LOOP_CORES} cores with no passing case or ${MAX_SHARD_CORES} cores in total)."
  fi
}
stop_core_watchdog() {
  if [ -n "$WATCHDOG_PID" ]; then kill "$WATCHDOG_PID" 2>/dev/null || :; wait "$WATCHDOG_PID" 2>/dev/null || :; fi
  WATCHDOG_PID=""
}

#####################################################################
# Wait, collect, aggregate.
#####################################################################
declare -a SHARD_NAMES
declare -a SHARD_RC
wait_shards() {
  local i
  for (( i=0; i<NSHARDS; i++ )); do
    info "waiting on shard $i ..."
    SHARD_RC[i]=0
    wait "${SHARD_PIDS[i]}" || SHARD_RC[i]=$?
    # shard_entry.sh writes console.log and console.ts.log itself; unshare's own
    # messages (a shard that could not start) are in launch.log
    [ -s "$OUT/shard_${i}/console.log" ] || cp -f "$OUT/shard_${i}/launch.log" "$OUT/shard_${i}/console.log" 2>/dev/null || :
    info "shard $i finished rc=${SHARD_RC[i]}"
  done
}

# Preserve artifacts BEFORE cleanup; then rm (unless --keep).
declare -a SHARD_CORES
collect_shards() {
  local i
  for (( i=0; i<NSHARDS; i++ )); do
    local d="$OUT/shard_${i}"
    cp -f "$WORK/shard_${i}.exclusions.txt" "$d/exclusions.txt" 2>/dev/null || :
    # CTP summary/logs already live in the per-shard CTP copy on the host; which
    # subtree holds them depends on the runner CTP used (sql/ vs result/<cat>/).
    [ -d "$d/CTP/sql/result" ] && cp -a "$d/CTP/sql/result" "$d/out/" 2>/dev/null || :
    [ -d "$d/CTP/sql/log" ]    && cp -a "$d/CTP/sql/log"    "$d/out/" 2>/dev/null || :
    [ -d "$d/CTP/result" ]     && cp -a "$d/CTP/result"     "$d/out/" 2>/dev/null || :
    # Core dumps. path mode: already on the host in $d/cores via the bind-mount.
    # relative mode: cores landed in the server cwd inside the mounted CUBRID*/CTP
    # copies; sweep them into $d/cores before they are lost. (CTP only deletes cores
    # under $CUBRID/$CTP_HOME, so sweep those plus CUBRID_DB and the volatile upper.)
    [ -e "$d/cores" ] || mkdir -p "$d/cores"
    if [ "$CORE_MODE" = "relative" ]; then
      find "$d/CUBRID" "$d/CUBRID_DB" "$d/CTP" "$d/volatile" -type f -name 'core*' 2>/dev/null \
        -exec sh -c 'f="$1"; [ "$(file -b "$f" 2>/dev/null | grep -c core)" -gt 0 ] && mv "$f" "$2/" || :' _ {} "$d/cores" \; 2>/dev/null || :
    fi
    SHARD_CORES[i]=$(find "$d/cores/" -type f -name 'core*' 2>/dev/null | wc -l)
    [ "${SHARD_CORES[i]}" -gt 0 ] && err "shard $i: ${SHARD_CORES[i]} core dump(s) preserved in $d/cores"
  done
  cp -f "$ASSIGN_FILE" "$OUT/assignment.tsv" 2>/dev/null || :
}

# Parse "Fail/Success/Total" from a shard's CTP output. Echoes "fail success total".
# status-style suites (shell, ha_shell) do not print a Fail/Success/Total block;
# CTP writes test_status.data with the counters, exactly as the CI runner's
# judge_status reads them. Echoes "fail success total".
parse_shard_result_status() {
  local d="$1" f="" t="" sd
  sd="$(find "$d/CTP" "$d/out" -name test_status.data -type f 2>/dev/null | head -1)"
  if [ -z "$sd" ]; then
    # No counter file at all: fall back to the JUnit report the entrypoint collected.
    local xml; xml="$(find "$d/reports" -name '*.xml' -type f 2>/dev/null | head -1)"
    if [ -n "$xml" ]; then
      t="$(grep -o 'tests="[0-9]*"' "$xml" | head -1 | tr -dc '0-9')"
      f="$(grep -o 'failures="[0-9]*"' "$xml" | head -1 | tr -dc '0-9')"
      printf '%d %d %d\n' "${f:-0}" "$(( ${t:-0} - ${f:-0} ))" "${t:-0}"
      return
    fi
    echo "0 0 0"; return
  fi
  f="$(sed -nE 's/^[[:space:]]*total_fail_case_count[[:space:]]*[:=][[:space:]]*([0-9]+).*/\1/p' "$sd" | tail -1)"
  t="$(sed -nE 's/^[[:space:]]*total_executed_case_count[[:space:]]*[:=][[:space:]]*([0-9]+).*/\1/p' "$sd" | tail -1)"
  f="${f:-0}"; t="${t:-0}"
  printf '%d %d %d\n' "$f" "$(( t - f ))" "$t"
}

parse_shard_result() {
  local d="$1" src=""
  if [ "$SUITE_STYLE" = "status" ]; then parse_shard_result_status "$d"; return; fi
  # CTP writes a summary; search console + any result summary files.
  for cand in "$d/console.log" "$d"/CTP/sql/result/*summary* "$d"/out/result/*summary*; do
    [ -f "$cand" ] && src="$cand $src"
  done
  [ -n "$src" ] || { echo "0 0 0"; return; }
  # CTP prints its summary as capitalized "Key:Value" with no space, e.g.
  #   Fail:10
  #   Success:129
  #   Total:139
  # Split on ':'/'=', lowercase+trim the key, and pull the digits from the value.
  # Last matching block wins (console.log is parsed last, so it is authoritative).
  # shellcheck disable=SC2086
  awk -F'[:=]' '
    { key=tolower($1); gsub(/[ \t]/,"",key); val=$2; gsub(/[^0-9]/,"",val) }
    key=="fail"    && val!="" { f=val }
    key=="success" && val!="" { s=val }
    key=="total"   && val!="" { t=val }
    END { printf "%d %d %d\n", f+0, s+0, t+0 }
  ' $src 2>/dev/null
}

# Write $OUT/failed.list — one scenario-relative case path per line, the exact
# shape --only accepts, so a failed run can be re-run with:
#   ctp_run.sh --suite <s> ... $(sed "s/^/--only /" failed.list)
# CTP co-locates a failed case's artifacts in its result tree, which is what makes
# the list recoverable without parsing console output.
emit_failed_list() {
  local i out="$OUT/failed.list"
  : >"$out"
  for (( i=0; i<NSHARDS; i++ )); do
    local d="$OUT/shard_${i}"
    if [ "$SUITE_STYLE" = "status" ]; then
      # shell/HA: the entrypoint collects one JUnit report per shard, whose
      # <testcase> entries name the cases and carry <failure> for the bad ones.
      find "$d/reports" -name '*.xml' -type f 2>/dev/null | while read -r x; do
        # The attribute is ` name="…"`, and it MUST be matched with its leading
        # boundary: `classname="…"` contains `name="` as a substring, so a naive
        # /name="[^"]*"/ picks up the classname instead — which for the shell
        # runner is a GitHub blob URL, not a path anything local can use.
        awk '
          /<testcase/ {
            pend=""
            if (match($0, /[ \t]name="[^"]*"/))
              pend=substr($0, RSTART+7, RLENGTH-8)
          }
          /<(failure|error)[ >]/ { if (pend!="") { print pend; pend="" } }
        ' "$x"
      done >> "$out"
    else
      # sql/medium: CTP writes NO per-case JUnit here (the entrypoint's collector
      # finds nothing and says so). What it does write is the schedule dir's
      # summary.xml, one <scenario> block per case with its <case> path and
      # <result>. Read that from the shard's own CTP copy — this run's data only.
      find "$d/CTP" -name 'summary.xml' -type f 2>/dev/null | while read -r x; do
        awk '
          match($0, /<case>[^<]*<\/case>/) { c=substr($0, RSTART+6, RLENGTH-13) }
          /<result>[ \t]*fail[ \t]*<\/result>/ { if (c!="") { print c; c="" } }
        ' "$x"
      done >> "$out"
    fi
  done
  # CTP names a case relative to the testcases REPO (sql/_13_issues/…,
  # shell/_21_xa/…), while --only takes scenario-relative paths. Normalize so
  # this file can be fed straight back in.
  if [ -s "$out" ]; then
    awk -v p="$SUITE_SUBPATH/" 'index($0,p)==1 { print substr($0, length(p)+1); next } { print }' \
      "$out" > "$out.norm" && mv -f "$out.norm" "$out"
  fi
  LC_ALL=C sort -u "$out" -o "$out" 2>/dev/null || :
  if [ -s "$out" ]; then
    info "failed cases ($(wc -l < "$out")) listed in $out"
  else
    rm -f "$out"
  fi
}
aggregate() {
  local i tot_fail=0 tot_succ=0 tot_total=0 tot_cores=0 any_crash=0
  info "==================== AGGREGATE ===================="
  printf '  %-7s %-8s %-8s %-8s %-8s %-8s %s\n' "shard" "rc" "fail" "success" "total" "cores" "expected"
  for (( i=0; i<NSHARDS; i++ )); do
    local d="$OUT/shard_${i}" f s t exp cores
    read -r f s t <<<"$(parse_shard_result "$d")"
    exp="${SHARD_NSQL[i]:-0}"
    cores="${SHARD_CORES[i]:-0}"
    tot_fail=$((tot_fail+f)); tot_succ=$((tot_succ+s)); tot_total=$((tot_total+t)); tot_cores=$((tot_cores+cores))
    # CTP exits non-zero merely because cases failed, so rc alone does not mean a
    # crash. Only call it CRASHED when the shard produced no counters at all —
    # that is the shape of a container/CTP startup failure, and it is the case
    # that must not be mistaken for "0 failures".
    local note=""
    if [ "${SHARD_RC[i]}" != "0" ] && [ "$t" -eq 0 ]; then
      note="CRASHED"; any_crash=1
    elif [ "${SHARD_RC[i]}" != "0" ] && [ "$f" -eq 0 ]; then
      note="rc!=0,NO-FAILURES-PARSED"; any_crash=1
    fi
    [ "$cores" -gt 0 ] && note="${note:+$note,}CORE"
    [ "$t" != "$exp" ] && note="${note:+$note,}TOTAL!=EXPECTED"
    printf '  %-7d %-8s %-8d %-8d %-8d %-8d %s %s\n' "$i" "${SHARD_RC[i]}" "$f" "$s" "$t" "$cores" "$exp" "$note"
  done
  printf '  %-7s %-8s %-8d %-8d %-8d %-8d %d\n' "ALL" "-" "$tot_fail" "$tot_succ" "$tot_total" "$tot_cores" "$SURVIVING_SQL"

  # Split invariant: Sigma CTP Total == surviving == global - base_excluded.
  # Hard for sql/medium (a mismatch means the split lost or duplicated cases).
  # Advisory for shell/ha_shell: CTP additionally drops cases by macro
  # (testcase_exclude_by_macro=LINUX_NOT_SUPPORTED) and by its own skip rules, so
  # executed < assigned is normal there and must not fail an otherwise-green run.
  local fail=0
  if [ "$tot_total" -ne "$SURVIVING_SQL" ]; then
    if [ "$SUITE_STYLE" = "status" ]; then
      warn "executed=$tot_total != assigned=$SURVIVING_SQL (macro/skip exclusions; not a split error)"
      [ "$tot_total" -eq 0 ] && { err "INVARIANT VIOLATED: nothing executed at all"; fail=1; }
    else
      err "INVARIANT VIOLATED: sum(CTP Total)=$tot_total != surviving=$SURVIVING_SQL"
      fail=1
    fi
  fi
  if [ "$SURVIVING_SQL" -ne "$(( GLOBAL_SQL - BASE_EXCLUDED ))" ] && [ "$SUITE_STYLE" != "status" ]; then
    err "INVARIANT VIOLATED: surviving=$SURVIVING_SQL != global-base=$(( GLOBAL_SQL - BASE_EXCLUDED ))"
    fail=1
  fi
  if [ -s "$OUT/.abort_reason" ]; then
    err "run ABORTED by the core watchdog: $(cat "$OUT/.abort_reason")"
    err "shard results below are PARTIAL (containers were stopped mid-run)."
    fail=1
  fi
  if [ -s "$OUT/.dead_shards" ]; then
    while IFS= read -r line; do err "STOPPED by a watchdog: $line"; done < "$OUT/.dead_shards"
    err "those shards' results are PARTIAL; rerun their remaining cases once the crash is fixed."
    fail=1
  fi
  [ "$any_crash" -ne 0 ] && { err "one or more shards crashed."; fail=1; }
  [ "$tot_cores" -ne 0 ] && { err "$tot_cores core dump(s) captured (see shard_*/cores/)."; fail=1; }
  [ "$tot_fail" -ne 0 ] && { err "$tot_fail test failure(s) across all shards."; fail=1; }

  emit_failed_list
  if [ "$fail" -ne 0 ]; then
    err "RESULT: FAILED"
    return 1
  fi
  info "RESULT: PASSED (fail=0, total=$tot_total over $NSHARDS shards)"
  return 0
}

#####################################################################
# Merge the per-shard CTP result dirs into ONE schedule dir under
# $OUT/webconsole, keeping the merged report beside the parallel run
# as a single entry whose failures are all browsable (D7).
#
# CTP makes each schedule dir self-contained for FAILED cases: it co-locates the
# failing <case>.sql/.result/.answer inside the schedule's category tree, and the
# webconsole's failure view simply walks the schedule dir for *.sql. So merging is
# a UNION of every shard's schedule sql/ subtree plus one summed main.info at the
# root (findAllTestResults stops at the first main.info, so only the merged run is
# listed; per-shard main.info are intentionally NOT copied).
#####################################################################
merge_results() {
  [ "$ARG_WEBCONSOLE" -eq 1 ] || { info "webconsole merge skipped (--no-webconsole)."; return 0; }
  # The webconsole model is the sql runner's schedule dir layout; the shell runner
  # writes elsewhere and has no such view, so there is nothing to merge for it.
  if [ "$SUITE_STYLE" = "status" ]; then
    info "webconsole merge skipped (suite '$ARG_SUITE' has no sql/result schedule layout)."
    return 0
  fi
  [ "$NSHARDS" -gt 0 ] || return 0
  # Keep the merged copy on the same artifact disk as its source shards.
  local resroot="$OUT/webconsole"
  if [ ! -d "$ARG_CTP/sql" ]; then
    warn "webconsole merge: $ARG_CTP/sql not found; skipping."
    return 0
  fi

  # Build/version label + a representative cubrid_rel from any shard's main.info.
  local ver="" rel="" os="linux" i src sched
  for (( i=0; i<NSHARDS; i++ )); do
    local mi; mi="$(find "$OUT/shard_${i}/CTP/sql/result" -name main.info 2>/dev/null | head -1)"
    if [ -n "$mi" ]; then
      ver="$(awk -F: '/^build:/{print $2; exit}' "$mi")"
      rel="$(grep -m1 '^cubrid_rel:' "$mi" | cut -d: -f2-)"
      os="$(awk -F: '/^os:/{print $2; exit}' "$mi")"
      break
    fi
  done
  [ -n "$ver" ] || ver="unknown"

  local y m stamp lbl lblsan
  lbl="${ARG_LABEL:-$(basename "$OUT")}"
  lblsan="$(printf '%s' "$lbl" | tr -c 'A-Za-z0-9._-' '_')"
  y="y$(date +%Y)"; m="m$(date +%-m)"; stamp="$(date +%s)"
  sched="schedule_${os}_${ARG_SUITE}_64bit_parallel_${stamp}_${lblsan}_${ver}"
  local dest="$resroot/$y/$m/$sched"
  mkdir -p "$dest/sql"

  # Union every shard's schedule sql/ subtree (carries each shard's failed-case
  # artifacts + summary files). Distinct failures live in distinct category leaves,
  # so the union is lossless for the failure view.
  local sum_succ=0 sum_fail=0 sum_total=0 sum_exec=0 sum_time=0
  for (( i=0; i<NSHARDS; i++ )); do
    src="$(find "$OUT/shard_${i}/CTP/sql/result" -type d -name 'schedule_*' 2>/dev/null | head -1)"
    [ -n "$src" ] || { warn "webconsole merge: shard $i has no schedule dir; skipping it."; continue; }
    [ -d "$src/sql" ] && cp -an "$src/sql/." "$dest/sql/" 2>/dev/null || :
    local mi="$src/main.info"
    if [ -r "$mi" ]; then
      sum_succ=$(( sum_succ + $(awk -F: '/^success:/{print $2+0; exit}' "$mi") ))
      sum_fail=$(( sum_fail + $(awk -F: '/^fail:/{print $2+0; exit}' "$mi") ))
      sum_total=$(( sum_total + $(awk -F: '/^total:/{print $2+0; exit}' "$mi") ))
      sum_exec=$(( sum_exec + $(awk -F: '/^execute_case:/{print $2+0; exit}' "$mi") ))
      sum_time=$(( sum_time + $(awk -F: '/^totalTime:/{print $2+0; exit}' "$mi") ))
    fi
  done

  # One summed main.info at the merged root -> appears as a single run in the list.
  {
    printf 'build:%s\n' "$ver"
    printf 'version:64bit\n'
    printf 'os:%s\n' "$os"
    printf 'category:%s\n' "$ARG_SUITE"
    printf 'elapse_time:%d\n' "$sum_time"
    printf 'success:%d\n' "$sum_succ"
    printf 'fail:%d\n' "$sum_fail"
    printf 'total:%d\n' "$sum_total"
    printf 'execute_case:%d\n' "$sum_exec"
    printf 'totalTime:%d\n' "$sum_time"
    printf 'end_time:%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'result_path:%s\n' "$dest"
    printf '%s\n' "${rel:+cubrid_rel:$rel}"
    printf 'user:\n'
    printf 'machine:ctp-run/%s(%d shards)\n' "$lbl" "$NSHARDS"
  } > "$dest/main.info"

  info "webconsole: merged $NSHARDS shards -> $dest (success=$sum_succ fail=$sum_fail total=$sum_total)"
  info "webconsole-format reports retained under $resroot (not copied into CTP_HOME)."
}

#####################################################################
# Resolve the prebuilt locale lib + early-exit make_locale.sh to inject per shard
# (D6). Source priority: (1) --locale-dir, (2) a libcubrid_all_locales.so already
# in the build tree. The early-exit make_locale.sh is taken from --locale-dir if
# present, else the skill-bundled copy under locale/. The 18MB .so itself is NOT
# bundled in the skill; without it shards compile the locale themselves (slow).
#####################################################################
LOCALE_SO=""
LOCALE_SCRIPT=""
resolve_locale() {
  local bundled="$SELF_DIR/locale/make_locale.sh"
  if [ -n "$ARG_LOCALE_DIR" ]; then
    [ -d "$ARG_LOCALE_DIR" ] || die "--locale-dir does not exist: $ARG_LOCALE_DIR"
    [ -r "$ARG_LOCALE_DIR/libcubrid_all_locales.so" ] \
      || die "--locale-dir has no libcubrid_all_locales.so: $ARG_LOCALE_DIR"
    LOCALE_SO="$(cd "$ARG_LOCALE_DIR" && pwd)/libcubrid_all_locales.so"
    if [ -r "$ARG_LOCALE_DIR/make_locale.sh" ]; then
      LOCALE_SCRIPT="$(cd "$ARG_LOCALE_DIR" && pwd)/make_locale.sh"
    else
      LOCALE_SCRIPT="$bundled"
    fi
  elif [ -r "$ARG_BUILD/lib/libcubrid_all_locales.so" ]; then
    LOCALE_SO="$ARG_BUILD/lib/libcubrid_all_locales.so"
    LOCALE_SCRIPT="$bundled"
  fi
  if [ -n "$LOCALE_SO" ]; then
    [ -r "$LOCALE_SCRIPT" ] || die "early-exit make_locale.sh missing: $LOCALE_SCRIPT"
    info "locale: injecting prebuilt $(basename "$LOCALE_SO") + early-exit make_locale.sh per shard (skips per-shard compile)."
  else
    info "locale: no prebuilt locale lib; shards will run make_locale (slow). Pass --locale-dir <dir with libcubrid_all_locales.so> to skip it."
  fi
}

#####################################################################
# Main
#####################################################################
WORK=""
OUT=""
# After the results are merged, drop each shard's working copies (install, CTP tree,
# testcases, DB volumes) and keep only the evidence: console.log, out/ (CTP result +
# log), reports/, cores/, the composed CTP conf and the install's log/. The copies
# are the bulk of a run and are reproducible from --build / --testcases; keeping them
# on the NVMe home disk is what filled it before runs were moved to the HDD, and the
# HDD is what made runs slow. --keep-copies (or CTP_KEEP_COPIES=1) opts out for a run
# that needs a shard's copy for debugging.
prune_shard_copies() {
  [ "$ARG_KEEP_COPIES" -eq 0 ] || { info "--keep-copies set: shard working copies left in place."; return 0; }
  local i d before after sub
  before="$(du -sh "$OUT" 2>/dev/null | cut -f1)"
  for (( i=0; i<NSHARDS; i++ )); do
    d="$OUT/shard_${i}"
    [ -d "$d" ] || continue
    mkdir -p "$d/out"
    [ -d "$d/CTP/conf" ]   && rm -rf "$d/out/ctp-conf"   && cp -a "$d/CTP/conf"   "$d/out/ctp-conf"   2>/dev/null || :
    [ -d "$d/CUBRID/log" ] && rm -rf "$d/out/cubrid-log" && cp -a "$d/CUBRID/log" "$d/out/cubrid-log" 2>/dev/null || :
    for sub in CUBRID CTP testcases CUBRID_DB; do
      rm -rf "$d/$sub" 2>/dev/null || :
    done
    # The volatile overlay's workdir keeps a mode-000 work/ owned by the
    # namespace's root; only a user namespace can remove it.
    if [ -e "$d/volatile" ]; then
      rm -rf "$d/volatile" 2>/dev/null || unshare -Ur rm -rf "$d/volatile" 2>/dev/null || :
    fi
  done
  after="$(du -sh "$OUT" 2>/dev/null | cut -f1)"
  info "pruned shard working copies: $OUT $before -> $after (evidence kept: console.log, out/, reports/, cores/)."
}

#####################################################################
# Phase timing: where a run's wall clock goes, recorded for every run.
#   <out>/timing.tsv : host phase marks (epoch seconds), then per-shard container
#                      phases read from shard_N/console.ts.log.
#   <out>/timing.txt : the same as durations, one line per shard.
# Container phases are the first line matching each CTP stage banner. A suite
# without one (shell/HA print no "[SQL] TEST STARTED") shows "-" there.
#####################################################################
mark_phase() { printf 'host\t%s\t%s\n' "$1" "$(date +%s)" >> "$OUT/timing.tsv"; }

write_timing() {
  local i f t0 p v line up first last n
  declare -A at
  t0="$(awk -F'\t' '$1=="host" && $2=="start" {print $3; exit}' "$OUT/timing.tsv")"
  {
    printf '# run: host marks (seconds from start)\n'
    awk -F'\t' -v t0="$t0" '$1=="host" {printf "  %-15s +%ds\n", $2, $3-t0}' "$OUT/timing.tsv"
    printf '# shard: stage starts in s from the container'"'"'s first log line; setup = first line..first case; tc = first case..Testing End\n'
  } > "$OUT/timing.txt"
  for (( i=0; i<NSHARDS; i++ )); do
    f="$OUT/shard_${i}/console.ts.log"
    [ -s "$f" ] || continue
    # One "<phase> <RFC3339 timestamp>" line per phase found.
    while read -r p v; do
      at[$p]="$(date -d "$v" +%s.%N 2>/dev/null || echo)"
      printf 'shard%d\t%s\t%s\n' "$i" "$p" "${at[$p]}" >> "$OUT/timing.tsv"
    done < <(awk '
      function mark(name) { if (!(name in seen)) { seen[name] = 1; print name, $1 } }
      NR == 1 { mark("container_up") }
      /\[SQL\] TEST STARTED/ { mark("ctp_start") }
      /make locale now/ { mark("locale") }
      / MAKE [^ ]+ DATABASE/ { mark("createdb") }
      /Load Java Stored Procedure Classes/ { mark("sp_load") }
      / start database / { mark("server_start") }
      / Testing .* \(1\/[0-9]+ / { mark("first_case") }
      / Testing .* \([0-9]+\/[0-9]+ / { last = $1 }
      /Testing End!/ { mark("tc_end") }
      { end = $1 }
      END { if (last != "") print "last_case", last; if (end != "") print "container_end", end }
    ' "$f")
    # A Testing line is printed as its case starts, so the last case runs until
    # CQT's "Testing End!" (one case near the end of the suite takes ~74s).
    up="${at[container_up]:-}"; first="${at[first_case]:-}"; last="${at[tc_end]:-${at[last_case]:-}}"
    line="$(printf 'shard %-2d' "$i")"
    for n in ctp_start locale createdb sp_load server_start; do
      if [ -n "${at[$n]:-}" ] && [ -n "$up" ]; then
        line+="$(awk -v a="$up" -v b="${at[$n]}" -v k="$n" 'BEGIN{printf "  %s +%.0fs", k, b-a}')"
      else
        line+="  $n -"
      fi
    done
    if [ -n "$up" ] && [ -n "$first" ]; then
      line+="$(awk -v a="$up" -v b="$first" 'BEGIN{printf "  | setup %.0fs", b-a}')"
    fi
    if [ -n "$first" ] && [ -n "$last" ]; then
      line+="$(awk -v a="$first" -v b="$last" 'BEGIN{printf "  | tc %.0fs", b-a}')"
    fi
    printf '%s\n' "$line" >> "$OUT/timing.txt"
    unset at; declare -A at
  done
  info "timing: $(awk '/\| setup/ {s=$0; sub(/.*\| setup /,"",s); sub(/s.*/,"",s); s+=0; t=$0; sub(/.*\| tc /,"",t); sub(/s.*/,"",t); t+=0; if (n==0||s<smin) smin=s; if (s>smax) smax=s; if (n==0||t<tmin) tmin=t; if (t>tmax) tmax=t; n++} END{if (n) printf "container setup %d-%ds, tc %d-%ds over %d shard(s)", smin, smax, tmin, tmax, n; else printf "no shard timing"}' "$OUT/timing.txt") (details: $OUT/timing.txt)"
}

cleanup() {
  stop_core_watchdog 2>/dev/null || :
  [ -n "${WORK:-}" ] && rm -rf "$WORK" 2>/dev/null || :
}

main() {
  parse_args "$@"

  # Hidden self-test seam: validate a supplied split and exit.
  if [ "$ARG_VALIDATE_ONLY" -eq 1 ]; then
    WORK="$(mktemp -d)"
    trap cleanup EXIT
    ASSIGN_FILE="$VO_ASSIGN"
    SQL_LIST="$VO_SQL"
    SURVIVING_SQL="$(wc -l < "$SQL_LIST")"
    validate_split
    return $?
  fi

  # --merge-only: write merged reports alongside a finished run (no shards).
  if [ -n "$ARG_MERGE_ONLY" ]; then
    OUT="$(cd "$ARG_MERGE_ONLY" && pwd)"
    NSHARDS="$(find "$OUT" -maxdepth 1 -type d -name 'shard_*' 2>/dev/null | wc -l)"
    [ "$NSHARDS" -ge 1 ] || die "--merge-only: no shard_* dirs under $OUT"
    ARG_WEBCONSOLE=1
    info "merge-only: merging $NSHARDS shard result dir(s) into $OUT/webconsole ..."
    merge_results
    return 0
  fi

  # namespace preflight FIRST (real runs only) — before any work dirs exist.
  if [ "$ARG_DRYRUN" -eq 0 ]; then
    host_preflight
  fi

  choose_shards

  OUT="$ARG_OUT"
  mkdir -p "$OUT"
  OUT="$(cd "$OUT" && pwd)"
  WORK="$(mktemp -d "${OUT}/.work.XXXXXX")"
  trap cleanup EXIT
  mark_phase start

  # Which testcases ref, materialized as a worktree we own (host checkout untouched).
  if [ "$ARG_TC_ASIS" -eq 1 ]; then
    info "testcases: --testcases-as-is -> using $ARG_TC verbatim (ref resolution skipped)"
    TC_REF="as-is:$ARG_TC"; TC_REF_SRC="--testcases-as-is"
    TC_SHA="$(git -C "$ARG_TC" rev-parse HEAD 2>/dev/null || echo unknown)"
  else
    resolve_tc_ref
    materialize_tc_worktree "$ARG_TC" "$TC_REF" "$ARG_WT_ROOT"
    SCN="$TC_WORKTREE/$SUITE_SUBPATH"
    [ -d "$SCN" ] || die "scenario dir missing in the worktree: $SCN"
    SCN="$(cd "$SCN" && pwd)"
  fi
  resolve_pin
  build_provenance
  write_provenance

  resolve_colocate
  resolve_split
  resolve_weights
  info "discovering units under $SCN ..."
  discover_units
  balance_units
  report_pin
  write_run_pin
  expand_split_assignment
  expand_shard_sets
  validate_split
  emit_plan
  print_plan_summary

  if [ "$ARG_DRYRUN" -eq 1 ]; then
    info "--dry-run: plan + validation complete; not launching containers."
    return 0
  fi

  mark_phase planned
  setup_core_capture
  resolve_locale
  declare -ga SHARD_NAMES SHARD_RC SHARD_PIDS
  local i
  # In parallel: each shard's copies are its own files, and 16 in a row took 26s.
  local -a build_pids=()
  for (( i=0; i<NSHARDS; i++ )); do build_shard_workdir "$i" & build_pids+=( $! ); done
  for (( i=0; i<NSHARDS; i++ )); do
    wait "${build_pids[i]}" || die "shard $i: building its working copies failed (see the messages above)."
  done
  mark_phase workdirs_built
  for (( i=0; i<NSHARDS; i++ )); do launch_shard "$i"; done
  mark_phase launched
  start_core_watchdog
  wait_shards
  mark_phase shards_done
  stop_core_watchdog
  collect_shards
  local agg_rc=0
  aggregate || agg_rc=$?
  merge_results || :
  prune_shard_copies || :
  mark_phase pruned
  write_timing || :
  return "$agg_rc"
}

main "$@"
