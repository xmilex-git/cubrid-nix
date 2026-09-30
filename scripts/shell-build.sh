#!/usr/bin/env bash
# Incremental build of a worktree in place, in the dev shell (ADR 0001 D3): build.sh
# keeps build_x86_64_<mode> between runs and installs into <prefix>, with the same
# toolchain and sealed inputs as build.sh. Prints the install's path.
#   shell-build.sh <worktree> [optdebug|release] [prefix]
set -euo pipefail
usage="usage: shell-build.sh <worktree> [optdebug|release] [prefix]"
ws=$(cd "${1:?$usage}" && pwd)
mode=${2:-optdebug}
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
prefix=${3:-$repo/.scratch/install/$(basename "$ws")-$mode-shell}
[ -n "${CUBRID_CI_SNAPSHOT:-}" ] || { echo "run it in the dev shell (nix develop)" >&2; exit 1; }
missing=$(git -C "$ws" submodule status | awk '/^-/ { print $2 }' | tr '\n' ' ')
[ -z "$missing" ] || { echo "uninitialized submodules (the CI builds them all): $missing" >&2; exit 1; }
# A build tree configured with another CI toolchain snapshot compiles nothing again and
# keeps linking against that snapshot: its compiler record names the snapshot it saw.
rec=("$ws/build_x86_64_$mode"/CMakeFiles/*/CMakeCCompiler.cmake)
if [ -e "${rec[0]}" ] && ! grep -qF "$CUBRID_CI_SNAPSHOT" "${rec[0]}"; then
  echo "shell-build: $ws/build_x86_64_$mode was configured with another CI toolchain snapshot;" >&2
  echo "remove that directory to build with this one ($CUBRID_CI_SNAPSHOT)." >&2
  exit 1
fi
# The seed puts the sealed inputs the worktree declares in place. Only the three declaring
# files reach nix, as the flake's cubrid-src input (a pure evaluation, ADR 0003 D1).
decls=$repo/.scratch/sealed-declarations/$(basename "$ws")
for f in 3rdparty/CMakeLists.txt pl_engine/cmake/install_jdk.cmake \
    pl_engine/gradle/wrapper/gradle-wrapper.properties; do
  mkdir -p "$decls/$(dirname "$f")" && cp "$ws/$f" "$decls/$f"
done
seed=$(nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths \
  --override-input cubrid-src "path:$decls" "$repo#lib.x86_64-linux.sealedSeed")
"$seed" "$ws/build_x86_64_$mode" "$GRADLE_USER_HOME"
cd "$ws"
run=(./build.sh -m "$mode" -p "$prefix" build)
# src/heaplayers/malloc_2_8_3.c includes /usr/include/malloc.h by absolute path, which
# --sysroot does not reach. It comes after <malloc.h>, the snapshot's (the CI's glibc
# 2.28), so a host copy with the same include guard adds nothing (ADR 0003 D6): the CI
# preprocessor shows whether it does. A host without the file gets the snapshot's in a
# private mount namespace, where there are namespaces.
probe() { printf '#include <malloc.h>\n%s\n' "$1" | gcc -E -P -x c - 2>/dev/null || echo "(no such file)"; }
if [ "$(probe '')" = "$(probe '#include "/usr/include/malloc.h"')" ]; then
  echo "shell-build: the host's /usr/include/malloc.h adds nothing to the CI's; building in place"
  "${run[@]}"
elif unshare -Urm true 2>/dev/null; then
  echo "shell-build: the snapshot's malloc.h replaces the host's in a private mount namespace"
  unshare -Urm bash -c 'mount -t tmpfs tmpfs /usr/include && ln -s "$1" /usr/include/malloc.h && shift && exec "$@"' \
    _ "$CUBRID_CI_SNAPSHOT/usr/include/malloc.h" "${run[@]}"
else
  echo "shell-build: /usr/include/malloc.h is missing or adds declarations to the CI's," >&2
  echo "and there are no namespaces to replace it; build with build.sh (make build)." >&2
  exit 1
fi
echo "install: $prefix"
