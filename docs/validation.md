# Validation record

These are recorded results from the project's cleanroom runs. Timings and resource
figures describe those environments; they are not performance guarantees. The
restricted environments were simulated in containers, not validated on a live
cloud service. This document preserves earlier README results and summarizes the
later [restricted-cloud record](restricted-cloud.md#검증).

## Restricted environment, 4 CPUs — 2026-10-01

`cleanroom/restricted` ran Debian trixie with host GCC 14.2, Make, and Java 21 as
UID 1000. It had no `/nix`, user namespaces, or core dump support. The hard core
limit was zero and `core_pattern` was unreadable. PID 1 was `sleep infinity` and
did not reap orphaned processes. Checkouts were under `/workspace`, with a CPU
quota of four. A 32 GiB memory limit could not be imposed, so stages measured
peak sums of process RSS instead.

| Input | Revision or version |
|---|---|
| Engine, develop | `a59140bdd` |
| cubrid-testcases, develop | `fde71bc5f` |
| CTP | `4d0043a` |
| nixpkgs | `50ab793` |
| Tools | Nix 2.35.3, GCC 8.5.0, CMake 3.26.5, GDB 15.2 |

| Check | Recorded result |
|---|---|
| Installation, GitHub cache only | PASS; 109 s, 1.3 GiB store. Rerun: 1 s, no download. |
| New-shell activation, including after clearing `/var/tmp` | PASS |
| Engine clone with full history and submodules | PASS; 94 s, 11,431 commits, not shallow |
| Partial clone of cubrid-testcases develop | PASS; 14 s |
| Core-policy handling | All seven checks passed: missing file, denied access, directory, empty value, pipe, absolute path, relative path |
| Child-reaper control experiment | PASS; the unwrapped orphan became a PID 1 zombie, while the wrapped command left none |
| First incremental optdebug build / rebuild after one-line edit | PASS; 855 s, peak RSS sum 2.2 GiB / 39 s |
| First incremental release build | PASS; 892 s, peak RSS sum 1.7 GiB |
| Server, csql, and PL/CSQL smoke checks | PASS for optdebug and release |
| Core generation | Unavailable; the limit could not be raised, and SIGSEGV did not produce a core |
| SQL `_01_object/_04_trigger`, direct shard | PASS; assigned 82, executed 82, passed 82, failed 0, skipped 0, not run 0, cores 0; 91 s |
| Medium `_07_mc_dep`, direct shard | PASS; assigned 54, executed 54, passed 54, failed 0, skipped 0, not run 0, cores 0; 50 s |
| Test cleanup | No remaining run processes, ports, shared memory, or DB volumes |
| Final process state | Only the one zombie deliberately created by the control experiment remained; no adopted live processes |
| Disk use | About 10 GiB: store 1.6 G, engine and build trees 4.5 G, testcases 0.5 G, ccache and related files 1.1 G, CTP results and related files 1.8 G |

Reading an external core was **not run in this validation**. The earlier run below
checked it. Reproduction steps and verdicts are in `cleanroom/restricted/run.sh`
and `cleanroom/restricted/inside.sh`. The operating notes record cubrid-nix commit
`54b79039ae827a708d71bcfccdd4e0910411244b` as the setup baseline and require later
differences to be recorded.

## Earlier restricted environment, 16 CPUs

This simulated container used Debian trixie, UID 1000, 16 CPUs, no `/nix`, no user
namespaces, and no core dumps. The memory limit could not be imposed; measurements
are peak sums of process RSS. Conditions and defects found are documented in
[ADR 0003](adr/0003-user-store-without-root.md).

| Check | Recorded result |
|---|---|
| Installation, GitHub cache only | 116 s; 137 development-shell paths, 432.5 MiB downloaded, 1.3 GiB store |
| Installation, LAN cache | 17–23 s |
| New shell after clearing `/var/tmp` | Symlink restored; user store reused |
| Engine clone, history since December 2019 and submodules | 48–71 s, 489 MB |
| First incremental build | 283 s, peak RSS sum 5.1 GiB |
| Rebuild after one-line edit | 35 s |
| Sealed build | 302 s, peak RSS sum 5.0 GiB; largest process 2.7 GiB |
| Server, csql, and PL/CSQL smoke check | Passed |
| Core generation | Unavailable; core limit could not be raised, SIGSEGV produced no core |
| External core inspection | PASS; a 4.8 GB SIGABRT core from host 6.35, using the same install from the GitHub cache: 164 threads, 608 CUBRID frames with file and line, 20 locals, zero build-ID warnings |
| SQL `_01_object/_04_trigger`, direct shard | 82/82, 104 s |
| Medium `_07_mc_dep`, direct shard | 54/54, 51 s |
| Shell case `_01_utility/_17_loaddb/bug_xdbms184`, direct mode | PASS; OK 2, NOK 0, no leftover resources, 11 s |
| Rerun in the same home: installation, smoke, shell case | PASS; Nix was not downloaded again |
| Disk use | About 10 GiB: store 2.7 G, engine and build trees 4.2 G, ccache and related files 1.1 G, CTP testcases and related files 2.2 G |

## `/nix` store — 2026-09-30

A clean `ubuntu:24.04` container had only Nix 2.35.2 installed before flake setup.
Engine develop was `35f528e89`; testcase develop was `7bd8ebbc`. `cleanroom/run.sh`
ran validation stages with `--network=none` after setup. This historical version
used Just recipes and included perf.

| Check | Recorded result |
|---|---|
| Cold start: Nix, development shell, source, build inputs | 12–18 min on 64 cores |
| optdebug / release build | 184 s / 175 s; same store paths as the host build |
| Rebuild after one-line edit | 85 s, ccache hit rate 98% |
| Server, csql, and PL/CSQL smoke check | Passed |
| Full SQL suite, 16 shards | 17,463/17,463, 300 s |
| Full medium suite | 975/975, 190 s |
| GDB | Source files and lines visible in the core |
| Container without namespaces | Unsandboxed build; 82 CTP cases passed in one direct shard |

## Host follow-up checks

The per-install locale cache and installs under `/home` were checked on the Rocky
Linux 8 host with the same engine and testcases. Both `/nix/store` and incremental
installs passed SQL **17,463/17,463** and medium **975/975**. The shard locale stage
fell from 43 s to 0–1 s; a 43-case subset fell from 84 s to 44 s.

After the closure reductions in ADR 0003, checks were repeated with the host's
`/nix` store. The optdebug build took 260 s and an incremental build from a fresh
checkout took 306 s. Smoke, the 82-case SQL trigger subset, medium **975/975**
(testcase develop `f1c9f42a`), one shell case, and GDB inspection of a kernel core
all passed. The development-shell closure shrank from 230 paths / 1.48 GiB to
152 paths / 1.20 GiB.
