#!/usr/bin/env bash
# Run a CTP suite on an install (ADR 0001 D8, D11) with ctp/ctp_run.sh, in the dev shell.
# Pass the testcases ref as the runner requires it (--tc-ref <ref> or --pr <N>); the
# testcases checkout is cloned on first use (needs network).
#   ctp.sh <sql|medium> <install> [ctp_run.sh options]
set -euo pipefail
usage="usage: ctp.sh <sql|medium> <install> [ctp_run.sh options]"
suite=${1:?$usage}
install=${2:?$usage}
shift 2
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tc=${CUBRID_NIX_TESTCASES:-$repo/.scratch/testcases/cubrid-testcases}
if [ ! -e "$tc/.git" ]; then
  mkdir -p "$(dirname "$tc")"
  git clone --filter=blob:none https://github.com/CUBRID/cubrid-testcases.git "$tc"
fi
exec "$repo/ctp/ctp_run.sh" --suite "$suite" --build "$install" --testcases "$tc" \
  --out "$repo/.scratch/ctp/$suite-$(date -u +%Y%m%dT%H%M%SZ)" "$@"
