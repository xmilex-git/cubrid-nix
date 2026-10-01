# Usage

Start with the [README](../README.md#quick-start) to install the environment and
clone CUBRID. Commands below run from `~/cubrid-nix` inside `nix develop`. If GNU
Make is available on the host, recipes enter the development shell automatically
when called outside it. Source the installer's `env.sh` in each new shell.

## Installation

`install.sh` checks the CPU quota, memory, disk space, user namespaces, core dump
policy, and CA bundle. It downloads static Nix 2.35.3 with SHA-256 verification,
writes `nix.conf` and `env.sh`, and fetches tools from signed binary caches.

Files live in `~/.local/share/cubrid-nix`. A symlink exposes them at
`/var/tmp/cubrid-nix`, giving every installation the same store path for cache
reuse. Only one user per host can own this path; the installer refuses to use
another user's store. `env.sh` restores the symlink if `/var/tmp` was cleared.

Rerunning the installer checks the environment and rewrites settings while
keeping the store. If a cache is missing a required path, installation stops.
`--build-missing` allows a source build instead, which can take hours.

Without Git, download the repository archive:

```bash
curl -fL https://github.com/xmilex-git/cubrid-nix/archive/main.tar.gz | tar xz
cd cubrid-nix-main
./install.sh --profile
```

Nix itself is not pinned by `flake.lock`; the lock pins nixpkgs and other flake
inputs. The installer's version is a bootstrap choice. You can use a different
Nix installation in a shell that has not sourced this `env.sh`.

### Using an existing `/nix` store

The flake also supports `/nix/store`. If you use the official single-user
installer, creating `/nix` may need sudo:

```bash
curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon
. ~/.nix-profile/etc/profile.d/nix.sh
mkdir -p ~/.config/nix /nix/var/cache/ccache
cat >> ~/.config/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
extra-sandbox-paths = /nix/var/cache/ccache
EOF
```

Add the settings from [Binary caches](#binary-caches). Without user namespaces,
also set `sandbox = false`.

## Builds

### Incremental builds

```bash
make shell-build WORKTREE=~/cubrid
I=~/cubrid-nix/.scratch/install/cubrid-optdebug-shell
```

This runs the engine's `build.sh -m optdebug` with GCC 8.5, glibc 2.28, and ccache.
The worktree keeps `build_x86_64_optdebug`, so running the command after an edit
is incremental. The caches do not contain builds of your edited source; rebuild
after each source change.

The default install path uses the worktree's basename:
`.scratch/install/<worktree-name>-<mode>-shell`. Use `MODE=release` or
`PREFIX=<path>` to select the mode and install directory. Parallelism follows
the cgroup CPU quota; `CMAKE_BUILD_PARALLEL_LEVEL` overrides it.

Switch branches in the engine checkout, then run `git submodule update --init`
again. The script refuses to reuse a build tree configured with a different
toolchain snapshot; use a fresh build tree for the new snapshot.

### Sealed builds

```bash
make build WORKTREE=~/cubrid
I=~/cubrid-nix/.scratch/install/cubrid-optdebug
```

The recipe exports the worktree to `.scratch/src/<worktree-name>` and runs
`build.sh -m optdebug -p <out> build` in Nix without network access. Third-party
sources, the bundled JDK, Gradle, and its dependencies are supplied as hash-pinned
sealed inputs before the build.

The output is read-only in the Nix store. `.scratch/install/<worktree-name>-<mode>`
points to it. The same exported source and flake inputs produce the same store
path across machines. Use this install with the same smoke, CTP, and GDB commands.

When the engine changes its bundled JDK or Gradle inputs, update the seal. This
step needs network access:

```bash
make seal WORKTREE=~/cubrid
```

The third-party source list is read from the engine's `3rdparty/CMakeLists.txt`.

## Servers and csql

For a complete server, csql, and PL/CSQL check:

```bash
make smoke INSTALL="$I"
```

The recipe starts and stops services under the child reaper, using a fresh
writable run directory without modifying the install. Default ports must be free.

For an interactive database, create a run directory and keep the service under
the reaper. In one terminal, inside `nix develop`:

```bash
scripts/reap.py --wait -- bash -c '
  . "$(scripts/rundir.sh "$1" "$HOME/cubrid-run/demo")"
  cd "$CUBRID/tmp"
  mkdir -p "$CUBRID_DATABASES/demodb"
  (cd "$CUBRID_DATABASES/demodb" && cubrid createdb demodb en_US.utf8)
  cubrid server start demodb </dev/null >>"$CUBRID/log/server-control.log" 2>&1
' _ "$I"
```

The command waits for the service. `rundir.sh` requires a new directory. If
another installation uses port 1523, choose a free `cubrid_port_id` in the run
directory's `conf/cubrid.conf` before starting the server.

In a second terminal, activate the development environment and run:

```bash
. ~/cubrid-run/demo/cubrid.env
cd "$CUBRID/tmp"
csql -u dba demodb -c 'select 1 + 1'

# When finished
cubrid server stop demodb </dev/null >>"$CUBRID/log/server-control.log" 2>&1
cubrid service stop </dev/null >>"$CUBRID/log/server-control.log" 2>&1
```

The run directory owns its configuration, databases, logs, and temporary files.
Source its `cubrid.env` to reuse it from another shell. `csql` writes `csql.err`
in its working directory. Server-control output goes to a file because capturing
it through a pipe can hang.

## Regression tests

### SQL and medium

```bash
make ctp SUITE=sql INSTALL="$I" TC_REF=develop
make ctp SUITE=sql INSTALL="$I" TC_REF=develop ONLY=_01_object/_05_serial
make ctp SUITE=medium INSTALL="$I" TC_REF=develop
```

Use the runner through `make ctp`; do not call CTP directly. Its teardown kills
processes by name, so isolation and the runner's checks are part of the workflow.

- **Testcases:** the first run clones `cubrid-testcases` into
  `.scratch/testcases/cubrid-testcases`, requiring network access. Set
  `CUBRID_NIX_TESTCASES=<path>` to use an existing checkout.
- **Revision:** pass `TC_REF=<branch|tag|sha>` or `PR=<engine-pr>`. A PR selects
  `tc/pr-<number>`; if missing, the runner records a fallback to `develop`.
  Testcases from `develop` may not match an older engine revision.
- **Options:** `ARGS='--shards 4 --no-volatile'` passes options to the runner.
  Run `ctp/ctp_run.sh --help` for the full list. Medium and subsets use one shard.
- **Results:** `.scratch/ctp/<suite>-<timestamp>/` keeps `failed.list`, install,
  CTP and testcase revisions in `provenance.txt`, and per-shard console logs and
  timing records. Entries from `failed.list` can be passed to `ONLY=`.

With namespaces, shards have separate PID, network, and mount namespaces. CTP
teardown cannot reach outside the shard. Test databases use a volatile overlay
where supported (kernel 5.11 or later), otherwise eatmydata, to disable fsync.

Without namespaces, the runner uses one direct shard. It refuses to start if
this user has CUBRID processes. Other jobs must not start CUBRID under that
account during the run; the startup check cannot prevent that race.

CTP compiles locale libraries once per install before creating databases.
`~/.cache/cubrid-nix/locale` shares them across shards and later runs. It is safe
to clear this cache; the next run rebuilds it. It is not pruned automatically
and uses about 19 MB per install in the recorded runs.

### A single shell case

```bash
make shell-case INSTALL="$I" \
  CASE=_01_utility/_17_loaddb/bug_xdbms184 \
  TESTCASES=~/cubrid-testcases-private-ex
```

This follows the CTP shell guide's single-case procedure. It copies the case,
CTP, and a run directory into `.scratch/shell-case/<case>-<timestamp>/`; the
testcase checkout and install are unchanged. Upstream CI runs the full shell suite.

Case setup and teardown kill CUBRID processes and remove this user's shared
memory. With namespaces, the case has its own PID, IPC, and network namespaces.
Without them, the runner refuses to start while this user has CUBRID processes,
shared-memory segments, or while configured ports are in use.

`verdict.tsv` records the result. PASS requires an OK line and no NOK lines in
the case result, plus no remaining processes, shared memory, ports, or registered
databases from the run. `cubrid-testcases-private-ex` is private; clone it with
an authorized account and pass the checkout path.

## Core dumps

Inspect a core offline with the install that produced it:

```bash
nix develop -c scripts/reap.py -- scripts/gdb-core.sh \
  "$I" /path/to/core ~/cubrid-nix/.scratch/gdb-out
```

The script records threads, every thread's backtrace, and locals in the crashing
thread, with a verdict. For interactive inspection inside `nix develop`:

```bash
gdb "$I/bin/cub_server" /path/to/core
```

Use the install's executable; the run directory's executable is a shell wrapper.
GDB loads the matching glibc 2.28 `libthread_db`. Do not attach it to a live server.
For `make build` installs, resolve `/build/source` with the exported source:

```bash
export CUBRID_NIX_SRC=~/cubrid-nix/.scratch/src/cubrid
```

Core generation depends on the kernel's `core_pattern` and the server's core-size
limit. Check them on the host; a container cannot change its host's policy. If
the hard limit is zero or the policy prevents core generation, read a core made
elsewhere with the same install. Fetch a cached install with
`nix build --no-link <install-store-path>`. Analysis reports FAIL if GDB warns
that the binary does not match the core.

CTP does not collect shard cores when `core_pattern` points below `/home`, `/mnt`,
or `/tmp`, because shards mount over those directories. Cores can occupy several
GiB; remove them after investigation. Warnings about missing
`/dev/shm/cubbase_dmrb_*` files refer to removed shared-memory files.
`cub_master` may restart a crashed server; stop services when finished.

## Binary caches

Caches are separate for each store path but share the same signing key.

For the **user store**, `install.sh` configures the GitHub release cache and uses
the LAN cache first if it responds within three seconds. Both contain the full
tool closure; the public Nix cache does not serve this store path.

For **`/nix/store`**, add one of these pairs to `nix.conf`. On the internal network:

```ini
extra-substituters = http://192.168.6.4
extra-trusted-public-keys = cubrid-nix-cache-1:9tHaV41AhMl1GxTpdkaMjzH+V3/FiXx2F4hto1pcd+U=
```

Outside that network:

```ini
extra-substituters = https://github.com/xmilex-git/cubrid-nix/releases/download/nix-cache
extra-trusted-public-keys = cubrid-nix-cache-1:9tHaV41AhMl1GxTpdkaMjzH+V3/FiXx2F4hto1pcd+U=
```

For `/nix/store`, the release cache holds this project's paths absent from
`cache.nixos.org`; the public cache supplies the rest. Unreachable caches delay
Nix, so leave them out. With an HTTP proxy and the LAN cache, add `192.168.6.4`
to `no_proxy`.

After changes to `flake.nix`, `flake.lock`, or `nix/`, maintainers run
`make cache-update` once per store. See [Cache maintenance](cache-maintenance.md).

## Troubleshooting

| Symptom | Check |
|---|---|
| Installer rejects the user store | `/var/tmp/cubrid-nix` must belong to this user and point to the configured home. Only one user per host can own it. |
| Required cache path is missing | The user-store cache needs the full closure. `--build-missing` permits a source build, which can take hours. |
| Incremental build rejects `malloc.h` | Without namespaces, the host file must add no declarations after the CI header. Use `make build` if the check fails or the file is missing. |
| Poor ccache hit rate without namespaces | Unsandboxed Nix builds use changing build directories. |
| Download fails behind a proxy or mirror | Nix attempts a URL once. Rerun after a transient failure; fetched inputs are retained. |
| CTP has no cores | Check kernel policy, limits, and whether shard mounts hide the configured path. |

See [ADR 0003](adr/0003-user-store-without-root.md) for the design behind these constraints.
