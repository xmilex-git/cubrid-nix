#!/usr/bin/env bash
# Resolve CTP storage before staging copies or starting containers.
#
# Runs live on the NVMe home disk by default (2026-09-21): a run on the mounted HDD
# spent most of its wall clock in I/O (install copies, DB volumes). Cores stay on
# the HDD (CORE_STORE in ctp_run.sh). What a run leaves behind is small once
# prune_shard_copies() has dropped the working copies, and `just ctp-prune`
# deletes old runs after their evidence was read.
set -euo pipefail
mount="${CTP_ARTIFACT_MOUNT:-/home}"
case "$mount" in /*) ;; *) echo "ERROR: CTP_ARTIFACT_MOUNT must be absolute" >&2; exit 1 ;; esac
mount="$(readlink -f "$mount")"
mountpoint -q "$mount" || { echo "ERROR: CTP artifact disk is not mounted: $mount (no local fallback)" >&2; exit 1; }
repo="$(cd "$(dirname "$0")/../../../.." && pwd -P)"
root="$mount/$(id -un)/ctp-run-out/$(basename "$repo")"
mkdir -p "$root"
root="$(cd "$root" && pwd -P)"
[ "$(findmnt -n -o TARGET -T "$root")" = "$mount" ] || { echo "ERROR: CTP output escaped artifact mount: $root" >&2; exit 1; }
[ -w "$root" ] || { echo "ERROR: CTP output is not writable: $root" >&2; exit 1; }
printf '%s\n' "$root"
