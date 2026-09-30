#!/usr/bin/env bash
# Inside a clean-room container (ADR 0001 D12), as an ordinary user whose /nix and home
# are volumes kept between the two phases. cleanroom/run.sh starts it:
#   inside.sh prepare <full|plain>   with network: nix, the dev shell, the sources,
#                                    every build input (the cold start)
#   inside.sh verify  <full|plain>   --network=none: builds, ccache rebuild, smoke, CTP,
#                                    and perf and gdb in full mode
# Only committed files are tested: the repo is cloned from its mount.
set -euo pipefail

phase=${1:?usage: inside.sh prepare|verify full|plain}
mode=${2:?usage: inside.sh prepare|verify full|plain}
R=$HOME/results
mkdir -p "$R"
mark() { printf '%s\t%s\t%s\n' "$phase" "$1" "$(date +%s)" >> "$R/timing.tsv"; echo "=== [$phase] $1 $(date -u +%FT%TZ)"; }
nx() { nix --extra-experimental-features 'nix-command flakes' "$@"; }
# downloads go through whatever proxy the host has; a transient 5xx fails one fetch
retry() { local n; for n in 1 2 3; do "$@" && return 0; echo "retry $n: $*" >&2; sleep 10; done; return 1; }
dev() { nx develop "$HOME/cubrid-nix" -c "$@"; }
ENGINE_REV=35f528e89f9918ec0ac1a272c0da4fec67c51078
SRC=$HOME/cubrid-nix/.scratch/src/cubrid
override=(--override-input cubrid-src "path:$SRC")

if [ "$phase" = prepare ]; then
  mark start
  # the latest stable nix, as the README installs it; CLEANROOM_NIX_VERSION pins one
  nix_url=https://nixos.org/nix/install
  [ -z "${CLEANROOM_NIX_VERSION:-}" ] || nix_url=https://releases.nixos.org/nix/nix-$CLEANROOM_NIX_VERSION/install
  curl -fsSL "$nix_url" | sh -s -- --no-daemon
  mkdir -p "$HOME/.config/nix" /nix/var/cache/ccache
  # full: the nix build sandbox (user namespaces); plain: none are allowed here
  cat > "$HOME/.config/nix/nix.conf" <<EOF
experimental-features = nix-command flakes
sandbox = $([ "$mode" = full ] && echo true || echo false)
extra-sandbox-paths = /nix/var/cache/ccache
${CUBRID_NIX_CACHE_URL:+extra-substituters = $CUBRID_NIX_CACHE_URL}
${CUBRID_NIX_CACHE_KEY:+extra-trusted-public-keys = $CUBRID_NIX_CACHE_KEY}
EOF
  . "$HOME/.nix-profile/etc/profile.d/nix.sh"
  nix --version
  mark nix_installed

  git_bin=$(nx build --no-link --print-out-paths /src/cubrid-nix#tool-git)/bin/git
  # nix runs the `git` on PATH to fetch the flake's git+https inputs (CTP): a bare Ubuntu has none
  export PATH="${git_bin%/git}:$PATH"
  "$git_bin" clone -q /src/cubrid-nix "$HOME/cubrid-nix"
  retry dev true
  mark devshell_ready

  # build.sh numbers the version by the commits since 2019-12-12: that much history suffices
  dev git clone -q --shallow-since=2019-12-01 https://github.com/CUBRID/cubrid.git "$HOME/cubrid"
  dev git -C "$HOME/cubrid" checkout -q "$ENGINE_REV"
  dev git -C "$HOME/cubrid" submodule update -q --init
  mark engine_cloned
  # one commit of develop: offline, the runner resolves the ref from the local branch
  dev git clone -q --depth 1 -b develop https://github.com/CUBRID/cubrid-testcases.git "$HOME/cubrid-testcases"
  mark testcases_cloned

  dev "$HOME/cubrid-nix/scripts/export-source.sh" "$HOME/cubrid" "$SRC"
  (cd "$HOME/cubrid-nix" && retry nx build --no-link "${override[@]}" \
     .#cubrid-optdebug.inputDerivation .#cubrid-release.inputDerivation)
  mark inputs_realized
  du -sh /nix/store | tee "$R/store-size-prepared.txt"
  exit 0
fi

# ---- verify: no network from here on ------------------------------------------------
. "$HOME/.nix-profile/etc/profile.d/nix.sh"
export NIX_CONFIG="substituters ="
cd "$HOME/cubrid-nix"
mark start
for m in optdebug release; do
  nx build -L --print-out-paths --out-link ".scratch/install/cubrid-$m" "${override[@]}" ".#cubrid-$m" \
    > "$R/build-$m.log" 2>&1
  mark "built_$m"
done
readlink -f .scratch/install/cubrid-optdebug .scratch/install/cubrid-release | tee "$R/installs.txt"

# a one-line change in the exported source: the sandbox rebuilds, ccache serves the rest
# the sandbox builds keep their cache in /nix/var/cache/ccache, not the dev shell's default
CCACHE_DIR=/nix/var/cache/ccache dev ccache -s > "$R/ccache-before.txt" 2>&1 || true
echo "/* clean-room rebuild */" >> "$SRC/src/query/query_executor.c"
nx build -L --no-link "${override[@]}" .#cubrid-optdebug > "$R/rebuild-optdebug.log" 2>&1
mark rebuilt_optdebug_ccache
CCACHE_DIR=/nix/var/cache/ccache dev ccache -s > "$R/ccache-after.txt" 2>&1 || true

for m in optdebug release; do
  dev just smoke ".scratch/install/cubrid-$m" "smoke-$m" > "$R/smoke-$m.log" 2>&1
  mark "smoke_$m"
done

export CUBRID_NIX_TESTCASES=$HOME/cubrid-testcases CUBRID_NIX_SRC=$SRC
if [ "$mode" = full ]; then
  dev just ctp sql .scratch/install/cubrid-optdebug --tc-ref develop > "$R/ctp-sql.log" 2>&1 || true
  mark ctp_sql
  dev just ctp medium .scratch/install/cubrid-optdebug --tc-ref develop > "$R/ctp-medium.log" 2>&1 || true
  mark ctp_medium
  dev bash /cleanroom/diag.sh .scratch/install/cubrid-optdebug "$R" > "$R/diag.log" 2>&1 || true
  mark diag
else
  # no namespaces: one direct shard over a subset (ADR 0001 D11)
  dev just ctp sql .scratch/install/cubrid-optdebug --tc-ref develop --only _01_object/_04_trigger \
    > "$R/ctp-sql-subset.log" 2>&1 || true
  mark ctp_sql_subset
fi
du -sh /nix/store | tee "$R/store-size-final.txt"
mark end
