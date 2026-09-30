#!/usr/bin/env bash
# The clean-room check (ADR 0001 D12): fresh containers of a bare Ubuntu with only the
# nix installer's prerequisites, as an ordinary user. Two phases share /nix and the home:
#   prepare  with network: nix (the latest stable, or CLEANROOM_NIX_VERSION), the dev
#            shell, the sources, every build input
#   verify   --network=none: builds, a ccache rebuild, smoke, CTP (+ perf, gdb in full)
# Modes:
#   full   privileged container: nix build sandbox, parallel CTP shards, perf, gdb
#   plain  default permissions: no sandbox, one direct CTP shard (the degraded path)
# Results land in .scratch/cleanroom/<mode>-<time>/{prepare.log,verify.log,home/results/}.
set -euo pipefail

mode=${1:?usage: run.sh full|plain}
case "$mode" in full|plain) ;; *) echo "usage: run.sh full|plain" >&2; exit 2 ;; esac
repo=$(cd "$(dirname "$0")/.." && pwd)
base=$repo/.scratch/cleanroom/$mode-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$base/nix" "$base/home" "$base/cores"

# host networking while downloading: an HTTP proxy on the host's loopback (if any) must
# stay reachable, and podman passes the proxy variables through
podman build -q --network=host -t localhost/cubrid-nix-cleanroom:base "$repo/cleanroom" > "$base/image.txt"

args=(--rm --cgroupns=private --userns=keep-id --user "$(id -u):$(id -g)"
      -e HOME=/home/cn -e USER="$(id -un)" -w /home/cn
      -v "$base/nix:/nix" -v "$base/home:/home/cn"
      -v "$repo:/src/cubrid-nix:ro" -v "$repo/cleanroom:/cleanroom:ro")
# the kernel writes cores where the host's core_pattern points, resolved in the container
pat=$(cat /proc/sys/kernel/core_pattern)
case "$pat" in /*) args+=(-v "$base/cores:$(dirname "$pat")") ;; esac
[ "$mode" = full ] && args+=(--privileged)
# a LAN binary cache for the cold start (ADR 0002): CUBRID_NIX_CACHE_URL and its key
for v in CUBRID_NIX_CACHE_URL CUBRID_NIX_CACHE_KEY CLEANROOM_NIX_VERSION; do
  [ -z "${!v:-}" ] || args+=(-e "$v=${!v}")
done

t0=$(date +%s)
podman run "${args[@]}" --network=host localhost/cubrid-nix-cleanroom:base bash /cleanroom/inside.sh prepare "$mode" \
  > "$base/prepare.log" 2>&1 || { echo "prepare failed: $base/prepare.log" >&2; exit 1; }
t1=$(date +%s)
# CLEANROOM_PREPARE_ONLY=1 measures the cold start alone
if [ "${CLEANROOM_PREPARE_ONLY:-0}" != 1 ]; then
  podman run "${args[@]}" --network=none localhost/cubrid-nix-cleanroom:base bash /cleanroom/inside.sh verify "$mode" \
    > "$base/verify.log" 2>&1 || echo "verify exited non-zero: $base/verify.log" >&2
fi
t2=$(date +%s)
printf 'cold start (prepare): %ds\nverify: %ds\nresults: %s\n' $((t1 - t0)) $((t2 - t1)) "$base" | tee "$base/summary.txt"
