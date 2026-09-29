# cubrid-nix recipes (ADR 0001). Run them inside `nix develop`.
#   just build <worktree> [optdebug|release]   nix build, as the CI builds (D6)
#   just shell-build <worktree> [mode] [prefix] incremental build in this shell (D3)
#   just seal <worktree>                        record new sealed inputs (D7), needs network
#   just smoke <install>                        server + csql + PL/CSQL in a run directory (D2)
#   just ctp <sql|medium> <install> [args]     CTP in unshare shards (D8)

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
      "(builtins.getFlake \"{{justfile_directory()}}\").lib.x86_64-linux.sealedSeedFor \"$ws\"")
    "$seed" "$ws/build_x86_64_{{mode}}" "$GRADLE_USER_HOME"
    cd "$ws"
    ./build.sh -m {{mode}} -p "$prefix" build
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
    if [ ! -d "$tc/.git" ]; then
      mkdir -p "$(dirname "$tc")"
      git clone --filter=blob:none https://github.com/CUBRID/cubrid-testcases.git "$tc"
    fi
    "{{justfile_directory()}}/ctp/ctp_run.sh" --suite "{{suite}}" --build "{{install}}" \
      --testcases "$tc" --out "{{scratch}}/ctp/{{suite}}-$(date -u +%Y%m%dT%H%M%SZ)" {{args}}

# Ports are the install's defaults: run it where they are private.
# Server, csql and PL/CSQL on an install, in a fresh run directory
smoke install name="smoke":
    #!/usr/bin/env bash
    set -euo pipefail
    run="{{scratch}}/run/{{name}}-$(date -u +%Y%m%dT%H%M%SZ)"
    env=$("{{justfile_directory()}}/scripts/rundir.sh" "{{install}}" "$run")
    "{{justfile_directory()}}/scripts/smoke.sh" "$env"
