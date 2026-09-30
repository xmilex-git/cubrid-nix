#!/usr/bin/env bash
# Server, csql and PL/CSQL on an install, in a fresh run directory (ADR 0001 D2). The
# ports are the install's defaults: run it where they are private.
#   smoke-install.sh <install> [name]
set -euo pipefail
usage="usage: smoke-install.sh <install> [name]"
install=${1:?$usage}
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
run=$repo/.scratch/run/${2:-smoke}-$(date -u +%Y%m%dT%H%M%SZ)
env=$("$repo/scripts/rundir.sh" "$install" "$run")
"$repo/scripts/smoke.sh" "$env"
