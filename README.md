<p align="center">
  <img src="docs/assets/banner.png" alt="CUBRID and Nix connected to a cloud computing environment" width="960">
</p>

<h1 align="center">cubrid-nix</h1>

<p align="center">The CUBRID CI toolchain, on your Linux machine.</p>

<p align="center">
  <a href="flake.nix"><img src="https://img.shields.io/badge/Nix-flake-5277C3?logo=nixos&amp;logoColor=white" alt="Nix flake"></a>
  <img src="https://img.shields.io/badge/platform-x86__64%20Linux-555" alt="Platform: x86_64 Linux">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-555" alt="License: Apache 2.0"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="docs/usage.md">Usage</a> ·
  <a href="docs/validation.md">Validation</a> ·
  <a href="docs/adr/0001-reproduce-ci-environment-with-nix.md">Design</a>
</p>

Build CUBRID with the compiler, libraries, and build-tool versions used in CI,
then run regression tests and inspect core dumps in the same environment. The
host distribution can be different: the toolchain comes from pinned Rocky Linux
8.10 RPMs, managed by a Nix flake.

- **Build, edit, rebuild.** Incremental `optdebug` and `release` builds with ccache,
  or a sealed Nix build that runs without network access.
- **Run CTP.** SQL tests split into isolated shards; medium tests use a single shard.
  Each run keeps its results, logs, and input revisions.
- **Read core dumps.** GDB uses the toolchain's glibc and unstripped CUBRID binaries
  to show source lines, threads, and local variables.

The installer runs as an ordinary user. It downloads Nix and the development
tools from signed binary caches. CUBRID source lives in a separate checkout.

## Quick start

You need **x86_64 Linux**, a user account with a writable home and `/var/tmp`,
Git, curl or wget, and a CA bundle. Allow about **10 GiB of disk space** for a
build and test workspace; see the [recorded measurements](docs/validation.md)
for context. Initial setup and the first testcase checkout need network access.
Builds and runs can work offline once their inputs are available.

### 1. Set up the environment

```bash
git clone https://github.com/xmilex-git/cubrid-nix ~/cubrid-nix
~/cubrid-nix/install.sh --profile
. ~/.local/share/cubrid-nix/env.sh

cd ~/cubrid-nix
nix develop
```

The installer checks the host, verifies the Nix download, and fetches the
development environment. Store files live in `~/.local/share/cubrid-nix`, exposed
at `/var/tmp/cubrid-nix/store` through a symlink. One user per host can own this store.

Run the remaining commands in the development shell. It includes Git, Make,
GDB, and the build tools. In a new shell, source `env.sh` again; `--profile` also
adds it to `~/.profile` and `~/.bashrc`. If the host has GNU Make, the recipes can
be called outside `nix develop` and will enter the development environment themselves.

### 2. Build CUBRID

```bash
git clone --shallow-since=2019-12-01 https://github.com/CUBRID/cubrid ~/cubrid
git -C ~/cubrid submodule update --init

make shell-build WORKTREE=~/cubrid
I=~/cubrid-nix/.scratch/install/cubrid-optdebug-shell
```

The retained history lets CUBRID's `build.sh` calculate its version number.
All submodules are initialized, as in CI.

Edit the engine source and run `make shell-build` again to rebuild. Use
`MODE=release` for a release build, or `PREFIX=~/CUBRID-release` to choose an
install location. Build parallelism follows the cgroup CPU quota and can be
overridden with `CMAKE_BUILD_PARALLEL_LEVEL`.

For a sealed build in the Nix store:

```bash
make build WORKTREE=~/cubrid
I=~/cubrid-nix/.scratch/install/cubrid-optdebug
```

Both commands use the CI toolchain. `make build` exports the worktree and supplies
hash-pinned third-party sources, JDK, Gradle, and dependencies before building.
Its install is read-only. [Build details →](docs/usage.md#builds)

### 3. Check the install

```bash
make smoke INSTALL="$I"
```

This creates a database, starts the server, checks csql and PL/CSQL, and stops the
services. It uses a fresh run directory and the install's default ports; use an
environment where those ports are available.

### 4. Run regression tests

```bash
# A subset of the SQL suite
make ctp SUITE=sql INSTALL="$I" TC_REF=develop ONLY=_01_object/_05_serial

# Full suites: SQL defaults to 16 shards; medium always uses one
make ctp SUITE=sql INSTALL="$I" TC_REF=develop
make ctp SUITE=medium INSTALL="$I" TC_REF=develop
```

Always select the testcase revision: `TC_REF=<branch|tag|sha>` or `PR=<engine-pr>`.
Choose testcases that match the engine you built. A PR selects `tc/pr-<number>`;
if that branch is missing, the runner uses `develop` and records the fallback.

Results go to `.scratch/ctp/<suite>-<timestamp>/`, including `failed.list`,
`provenance.txt`, and per-shard logs. To use an existing testcase checkout, set
`CUBRID_NIX_TESTCASES` to its path. [CTP options and single shell cases →](docs/usage.md#regression-tests)

> **Without user namespaces**, CTP runs one shard without isolation and refuses to
> start while this user has other CUBRID processes. Keep that account dedicated
> to the run: the check cannot prevent another job from starting CUBRID afterward.

## Environment and limits

| Capability | With user namespaces | Without user namespaces |
|---|---|---|
| Nix build | Sandboxed | Runs with `sandbox = false` |
| Incremental build | Uses the CI headers; substitutes the host's `malloc.h` when needed | Requires a compatible host `malloc.h`; otherwise use `make build` |
| CTP SQL | Isolated shards | One direct shard, with a process check before starting |
| Core dumps | Subject to the host kernel's policy | Subject to the host kernel's policy |

CTP uses a volatile overlay on kernels that support it (5.11 or later), otherwise
eatmydata, to disable fsync for test databases. Cores are collected only when the
kernel can write them; shard mounts also affect which paths are visible. GDB can
read a core from another machine when it has the matching install.

The Make recipes run under a child reaper so orphaned processes are stopped and
reaped even in containers whose PID 1 does not do that. For hosts without root,
`/nix`, user namespaces, or core dumps, see the [restricted cloud setup](docs/restricted-cloud.md).

## What matches CI?

| Component | Source | Selected versions |
|---|---|---|
| Compiler, linker, libraries, headers, code generators | Hash-pinned Rocky 8.10 RPMs from the CI build image | GCC 8.5.0, binutils 2.30, glibc 2.28, flex 2.6.1 |
| Build tools | Nix packages at CI versions | CMake 3.26.5, Ninja 1.11.1, Make 4.2.1, Bison 3.0.5, Temurin 8u442 |
| Formatting tools | Nix packages at CI versions | GNU indent 2.2.11, AStyle 3.1, google-java-format 1.7 |
| Timezone and locale data | CI test-image RPMs | tzdata 2024a, glibc language packs 2.28 |
| Test utilities and diagnostics | Pinned nixpkgs 24.11 | GDB 15.2, ccache 4.10.2 |

The [package inventory](docs/packages.md) lists the full versions and why each
package is included. `flake.lock` pins the flake inputs; Nix itself is not a flake
input. The installer currently bootstraps Nix 2.35.3.

## Validation

Recorded checks cover a clean Ubuntu container and a simulated restricted Debian
environment. These are specific runs, not timing guarantees or a claim of
validation on a live cloud service.

| Recorded environment | Checks |
|---|---|
| Ubuntu 24.04, `/nix` store, 2026-09-30 | optdebug and release builds; server, csql, PL/CSQL; SQL **17,463/17,463**; medium **975/975**; GDB core inspection |
| Restricted Debian container, 4 CPUs, 2026-10-01 | optdebug and release builds; smoke checks for both; SQL trigger subset **82/82**; medium subset **54/54**; process reaping and cleanup |

See the [validation record](docs/validation.md) for revisions, timings, resource
measurements, earlier runs, and checks that were not run.

## Documentation

| Guide | Contents |
|---|---|
| [Usage](docs/usage.md) | Builds, servers, CTP, single shell cases, core dumps, caches, and troubleshooting |
| [Validation](docs/validation.md) | Recorded cleanroom results and their limits |
| [Restricted cloud setup](docs/restricted-cloud.md) | Setup scripts and operating instructions for restricted hosts |
| [Package inventory](docs/packages.md) | Tool versions, dependencies, and package choices |
| [Architecture decisions](docs/adr/0001-reproduce-ci-environment-with-nix.md) | CI parity, caches, and installation without root |
| [Cache maintenance](docs/cache-maintenance.md) | Updating the LAN and GitHub binary caches |
| [Terminology](CONTEXT.md) | Shared definitions used in the design notes |

The usage and validation guides are in English. The existing design and setup
notes are in Korean. Run `make` to list the available recipes.

## License

[Apache License 2.0](LICENSE).
