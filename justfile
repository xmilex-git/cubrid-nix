# cubrid-nix recipes (ADR 0001). Run them inside `nix develop`.
#   just build <worktree> [optdebug|release]   nix build, as the CI builds (D6)
#   just shell-build <worktree> [mode] [prefix] incremental build in this shell (D3)
#   just seal <worktree>                        record new sealed inputs (D7), needs network
#   just smoke <install>                        server + csql + PL/CSQL in a run directory (D2)
#   just ctp <sql|medium> <install> [args]     CTP in unshare shards (D8)
#   just cache-push <dir> [key]                 fill the LAN binary cache directory (ADR 0002)

set shell := ["bash", "-euo", "pipefail", "-c"]

scratch := justfile_directory() / ".scratch"
nix := "nix --extra-experimental-features 'nix-command flakes'"

default:
    @just --list

# The worktree is exported like a source distribution and built by build.sh in the
# sandbox with the CI toolchain and the sealed inputs, without network.
# Build a worktree with `nix build`, as the CI builds it
build worktree mode="optdebug":
    #!/usr/bin/env bash
    set -euo pipefail
    ws=$(cd "{{worktree}}" && pwd)
    name=$(basename "$ws")
    src="{{scratch}}/src/$name"
    "{{justfile_directory()}}/scripts/export-source.sh" "$ws" "$src"
    mkdir -p "{{scratch}}/install"
    {{nix}} build -L --print-out-paths --out-link "{{scratch}}/install/$name-{{mode}}" \
      --override-input cubrid-src "path:$src" "{{justfile_directory()}}#cubrid-{{mode}}"

# build.sh keeps build_x86_64_<mode> between runs and installs into <prefix>; same
# toolchain and sealed inputs as `build`.
# Incremental build of a worktree in place
shell-build worktree mode="optdebug" prefix="":
    #!/usr/bin/env bash
    set -euo pipefail
    ws=$(cd "{{worktree}}" && pwd)
    prefix="{{prefix}}"
    prefix=${prefix:-{{scratch}}/install/$(basename "$ws")-{{mode}}-shell}
    missing=$(git -C "$ws" submodule status | awk '/^-/ { print $2 }' | tr '\n' ' ')
    [ -z "$missing" ] || { echo "uninitialized submodules (the CI builds them all): $missing" >&2; exit 1; }
    seed=$({{nix}} build --no-link --print-out-paths --impure --expr \
      "(builtins.getFlake \"git+file://{{justfile_directory()}}\").lib.x86_64-linux.sealedSeedFor \"$ws\"")
    "$seed" "$ws/build_x86_64_{{mode}}" "$GRADLE_USER_HOME"
    cd "$ws"
    run=(./build.sh -m {{mode}} -p "$prefix" build)
    # src/heaplayers/malloc_2_8_3.c includes /usr/include/malloc.h by absolute path, which
    # --sysroot does not reach: unless the host's copy is the snapshot's (the CI's glibc
    # 2.28), give it the snapshot's in a private mount namespace.
    if cmp -s /usr/include/malloc.h "$CUBRID_CI_SNAPSHOT/usr/include/malloc.h"; then
      "${run[@]}"
    else
      unshare -Urm bash -c 'mount -t tmpfs tmpfs /usr/include && ln -s "$1" /usr/include/malloc.h && shift && exec "$@"' \
        _ "$CUBRID_CI_SNAPSHOT/usr/include/malloc.h" "${run[@]}"
    fi
    echo "install: $prefix"

# Record the sealed inputs a worktree needs in nix/sealed/lock.json (needs network)
seal worktree:
    "{{justfile_directory()}}/scripts/seal.sh" "{{worktree}}"

# Pass the testcases ref as the runner requires it, e.g. `just ctp sql <install> --pr 8022`
# or `--tc-ref develop`. The testcases checkout is cloned on first use (needs network).
# Run a CTP suite on an install in unshare shards with a volatile database dir
ctp suite install *args:
    #!/usr/bin/env bash
    set -euo pipefail
    tc="${CUBRID_NIX_TESTCASES:-{{scratch}}/testcases/cubrid-testcases}"
    if [ ! -e "$tc/.git" ]; then
      mkdir -p "$(dirname "$tc")"
      git clone --filter=blob:none https://github.com/CUBRID/cubrid-testcases.git "$tc"
    fi
    "{{justfile_directory()}}/ctp/ctp_run.sh" --suite "{{suite}}" --build "{{install}}" \
      --testcases "$tc" --out "{{scratch}}/ctp/{{suite}}-$(date -u +%Y%m%dT%H%M%SZ)" {{args}}

# Everything a new environment fetches or builds for `nix develop` and `just build`,
# nixpkgs' own paths and the flake's inputs included, signed and zstd-compressed into a
# nix file cache that `cache-server-image` serves. Paths already there are skipped.
# Fill or update the LAN binary cache directory (ADR 0002)
cache-push dir key="":
    #!/usr/bin/env bash
    set -euo pipefail
    key="{{key}}"
    key=${key:-$HOME/.config/cubrid-nix/cache-key.secret}
    [ -r "$key" ] || { echo "no signing key at $key (ADR 0002 says how to make one)" >&2; exit 1; }
    mkdir -p "{{dir}}"
    dir=$(cd "{{dir}}" && pwd)
    # substituters are asked in priority order, and cache.nixos.org's is 40
    [ -e "$dir/nix-cache-info" ] || printf 'StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 30\n' > "$dir/nix-cache-info"
    to="file://$dir?compression=zstd&parallel-compression=true&secret-key=$key"
    cd "{{justfile_directory()}}"
    mapfile -t roots < <({{nix}} build --no-link --print-out-paths \
      .#devShells.x86_64-linux.default.inputDerivation \
      .#cubrid-optdebug.inputDerivation .#cubrid-release.inputDerivation)
    # the shell `nix develop` starts, with every output
    mapfile -t -O "${#roots[@]}" roots < <({{nix}} build --no-link --print-out-paths \
      --inputs-from . 'nixpkgs#bashInteractive^*')
    # A path written to after it was built would be served with a wrong hash.
    {{nix}} store verify --no-trust --recursive "${roots[@]}" \
      || { echo "modified store paths above: 'nix store repair <path>', then push again" >&2; exit 1; }
    {{nix}} copy --to "$to" "${roots[@]}"
    {{nix}} flake archive --to "$to"
    # what a client gets: every path's content hash and this key's signature
    pub=$({{nix}} key convert-secret-to-public < "$key")
    {{nix}} store verify --store "file://$dir" --trusted-public-keys "$pub" --recursive "${roots[@]}"
    echo "cache: $dir ($(du -sh "$dir" | cut -f1)), public key $pub"

# Ports are the install's defaults: run it where they are private.
# Server, csql and PL/CSQL on an install, in a fresh run directory
smoke install name="smoke":
    #!/usr/bin/env bash
    set -euo pipefail
    run="{{scratch}}/run/{{name}}-$(date -u +%Y%m%dT%H%M%SZ)"
    env=$("{{justfile_directory()}}/scripts/rundir.sh" "{{install}}" "$run")
    "{{justfile_directory()}}/scripts/smoke.sh" "$env"
