#!/usr/bin/env bash
# The roots of what a binary cache holds for a new environment (ADR 0002 D3), one store
# path per line; their closures are what the caches carry:
# - the inputs of the dev shell and of the CUBRID derivations (`make build`)
# - the bash that `nix develop` starts, with every output
# - the optdebug build of the default engine input (flake.lock's develop): an install any
#   machine gets byte for byte, which reads a core another machine wrote (ADR 0003 D9)
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
nx() { nix --extra-experimental-features 'nix-command flakes' "$@"; }
cd "$repo"
nx build --no-link --print-out-paths \
  .#devShells.x86_64-linux.default.inputDerivation \
  .#cubrid-optdebug.inputDerivation .#cubrid-release.inputDerivation
nx build --no-link --print-out-paths --inputs-from . 'nixpkgs#bashInteractive^*'
nx build --no-link --print-out-paths .#cubrid-optdebug
