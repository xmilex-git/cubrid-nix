#!/usr/bin/env bash
# Build a worktree with `nix build`, as the CI builds it (ADR 0001 D6): the worktree is
# exported like a source distribution and built by build.sh with the CI toolchain and
# the sealed inputs, without network. Prints the install's path.
#   build.sh <worktree> [optdebug|release]
set -euo pipefail
usage="usage: build.sh <worktree> [optdebug|release]"
ws=$(cd "${1:?$usage}" && pwd)
mode=${2:-optdebug}
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$repo/.scratch
name=$(basename "$ws")
src=$scratch/src/$name
"$repo/scripts/export-source.sh" "$ws" "$src"
mkdir -p "$scratch/install"
nix --extra-experimental-features 'nix-command flakes' build -L --print-out-paths \
  --out-link "$scratch/install/$name-$mode" \
  --override-input cubrid-src "path:$src" "$repo#cubrid-$mode"
