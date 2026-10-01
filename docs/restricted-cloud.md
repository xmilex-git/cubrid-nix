# 제한 클라우드에서 쓰기

root, `/nix`, user namespace, 코어 덤프가 없는 원격 환경(Codex 클라우드 등)에서 이 레포를 쓰는 방법이다.
결정과 이유는 [ADR 0003](adr/0003-user-store-without-root.md)에 있다. 아래 설정은 그 환경을 흉내 낸
컨테이너(`cleanroom/restricted`)에서 확인한 것이다. 실제 원격 환경에서 확인한 것은 아니다.

## 무엇이 되고 무엇이 안 되나

| 항목 | 이 환경에서 |
|---|---|
| nix 설치 | 된다. 사용자 홈에, root 없이. 바이너리는 sha256으로, 캐시는 서명으로 검증한다 |
| 개발 셸 | 된다. GitHub 캐시에서 받는다 |
| optdebug·release 빌드(`make shell-build`) | 된다. 증분 빌드도 된다 |
| CI와 같은 빌드(`make build`) | 된다. 샌드박스 없이 돈다 |
| 서버, csql, PL/CSQL | 된다 |
| CTP sql·medium | 된다. 샤드 하나가 격리 없이 돈다. 이 사용자의 다른 CUBRID가 있으면 시작하지 않는다. `core_pattern`을 읽을 수 없으면 코어를 모으지 않고 돈다 |
| 셸 케이스 한 건 | 된다. 다른 CUBRID 프로세스, 공유 메모리, 포트 사용이 없을 때만 시작한다 |
| shell 스위트 전체 | 하지 않는다. 업스트림 CI가 돌린다 |
| 좀비 프로세스 | 남지 않는다. PID 1이 회수하지 않아도, 레시피가 자식 회수 래퍼(`scripts/reap.py`) 아래에서 돈다 |
| gdb로 코어 읽기 | 된다. 다른 환경에서 같은 설치본이 만든 코어(외부 코어)를 읽는다 |
| 코어 만들기 | 안 된다. 커널이 코어를 쓰지 않는다 |
| 라이브 서버에 gdb 붙이기 | 하지 않는다. 이 레포의 규칙이다 |

## 환경 설정 (Codex)

| 항목 | 값 |
|---|---|
| 이름 | `cubrid` |
| 공개 범위 | Only me |
| 저장소 | `CUBRID/cubrid`(develop), `CUBRID/cubrid-testcases`(develop), `CUBRID/cubrid-testcases-private-ex`(develop), `xmilex-git/cubrid-nix`(main). 모두 https://github.com/ 아래에 있고, 작업 경로는 `/workspace/<저장소명>`이다 |
| 환경 변수 | `CUBRID_NIX_TESTCASES=/workspace/cubrid-testcases` (`make ctp`가 이 체크아웃을 쓴다) |
| 설치 스크립트 | 아래 |

## 설치 스크립트

환경의 설치(setup) 스크립트에 넣는다. 인터넷이 있을 때 한 번 돌고, 다시 돌아도 된다. 있는 체크아웃은
그대로 쓰고, 없는 것만 받는다. cubrid-testcases-private-ex는 비공개라서 그 환경의 GitHub 권한이 필요하다.

```bash
set -euo pipefail
W=/workspace
# git runs its automatic maintenance detached after a fetch; PID 1 here never reaps it
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=gc.autoDetach GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=maintenance.autoDetach GIT_CONFIG_VALUE_1=false
clone() { # 저장소명, GitHub 경로, 브랜치, clone 옵션
  [ -d "$W/$1/.git" ] || git clone -q ${4:-} -b "$3" "https://github.com/$2.git" "$W/$1"
}
clone cubrid-nix xmilex-git/cubrid-nix main
clone cubrid CUBRID/cubrid develop
clone cubrid-testcases CUBRID/cubrid-testcases develop --filter=blob:none
clone cubrid-testcases-private-ex CUBRID/cubrid-testcases-private-ex develop --filter=blob:none
# 사용자 권한 nix: 환경을 검사하고, 바이너리의 sha256과 캐시의 서명을 검증하며 개발 셸을 받는다.
# --profile: 새 셸이 ~/.profile과 ~/.bashrc에서 env.sh를 읽는다
"$W/cubrid-nix/install.sh" --profile
# 엔진: build.sh는 커밋 수로 버전을 매기고, CI는 서브모듈을 모두 빌드한다
cd "$W/cubrid"
[ "$(git rev-parse --is-shallow-repository)" = false ] || git fetch -q --unshallow origin
git submodule update -q --init
# 검증 기준과 다른 cubrid-nix면 그 SHA와 차이를 남긴다 (검증 기준: 54b79039ae827a708d71bcfccdd4e0910411244b)
git -C "$W/cubrid-nix" log -1 --format='cubrid-nix %H %s'
git -C "$W/cubrid-nix" log --oneline 54b79039ae827a708d71bcfccdd4e0910411244b..HEAD 2>/dev/null || :
```

- `install.sh`가 실패하면 설치는 실패다. 캐시에 없는 경로가 있으면 빌드하지 않고 멈춘다.
- 사내 캐시가 닿지 않는 환경이면 `install.sh`가 3초 만에 건너뛰고 GitHub 캐시만 쓴다.

## 시작 스킬

작업마다 읽히는 스킬(시작 지침)에 넣는다.

```markdown
---
name: cubrid-nix
description: Build, run and test CUBRID here with cubrid-nix (user store, no root, no namespaces).
---
Every shell command starts with `. ~/.local/share/cubrid-nix/env.sh` (a login shell does it
already). Recipes run from /workspace/cubrid-nix and enter `nix develop` themselves.

Run every build, server and test through `make` (each recipe runs under scripts/reap.py,
which reaps and stops what it leaves behind: PID 1 here reaps nothing). Never start a
build, a server or CTP outside it.

- Build: `make shell-build WORKTREE=/workspace/cubrid MODE=optdebug` (or MODE=release). The
  install is /workspace/cubrid-nix/.scratch/install/cubrid-<mode>-shell. After any source
  change run it again: the binary caches hold no build of your source. Later builds are
  incremental. `make build WORKTREE=/workspace/cubrid` builds as the CI does.
- Smoke: `make smoke INSTALL=<install>` (server, csql, PL/CSQL).
- A server by hand, outliving one command: in /workspace/cubrid-nix,
  `nohup nix develop -c scripts/reap.py --wait -- bash -c '. "$(scripts/rundir.sh <install> <new run dir>)" && cubrid server start <db>' > <log> 2>&1 &`;
  stop it with `cubrid service stop` from the same run directory's cubrid.env.
- CTP: `make ctp SUITE=sql|medium INSTALL=<install> TC_REF=develop [ONLY='<dir> ...']` (or PR=<n>);
  the testcases are /workspace/cubrid-testcases (CUBRID_NIX_TESTCASES). Here it runs one
  shard without isolation and refuses while this user runs other CUBRID processes. Report
  assigned, executed, passed, failed, skipped and not run from its ALL line. Never run
  ctp.sh directly. Do not run shell tests unless asked; then one case only:
  `make shell-case INSTALL=<install> CASE=<dir under shell/> TESTCASES=/workspace/cubrid-testcases-private-ex`.
- Cores: this environment cannot write cores. Reading a core made elsewhere is not verified
  here: `nix build --no-link <install store path>`, then in /workspace/cubrid-nix
  `nix develop -c scripts/reap.py -- scripts/gdb-core.sh <install> <core> <out dir>`.
  Never attach gdb to a live server.
- Report each check as PASS, FAIL or NOT RUN with its log; never report something that did
  not run as passed. Say "verified in this environment" only for what ran here.
```

## 검증

2026-10-01, `cleanroom/restricted`의 흉내 낸 컨테이너에서 확인했다. 실제 원격 환경에서 확인한 것은
아니다. 조건은 다음과 같다.

- Debian trixie(gcc 14.2, make, Java 21), uid 1000, `/nix` 없음, user namespace 없음, 코어 한도 0
- 회수하지 않는 PID 1(`sleep infinity`), 읽을 수 없는 `core_pattern`(파일 없음)
- CPU 4개, 저장소는 `/workspace/<저장소명>`

메모리 한도(32GiB)는 걸 수 없어서 단계마다 RSS 합의 최대치를 쟀다. 엔진 develop `a59140bdd`, cubrid-testcases develop `fde71bc5f`, CTP `4d0043a`, nixpkgs `50ab793`, nix 2.35.3, gcc 8.5.0, cmake 3.26.5, gdb 15.2.

| 항목 | 결과 |
|---|---|
| 설치, GitHub 캐시만 | PASS, 109초. 스토어 1.3GiB, 다시 돌리면 1초(받지 않음) |
| 새 셸 활성화(`/var/tmp`를 비운 뒤에도) | PASS |
| 엔진 clone: 전체 이력(커밋 11,431개, shallow 아님)과 서브모듈 | PASS, 94초 |
| cubrid-testcases develop(부분 clone) | PASS, 14초 |
| `ctp/test_core_capture.sh`: 파일 없음·권한 없음·디렉터리·빈 값·pipe·절대 경로·상대 경로 | 일곱 경우 PASS |
| 회수 래퍼 대조 실험 | PASS. 래퍼 없이 만든 고아는 PID 1의 좀비가 되고, 래퍼 아래에서는 좀비가 생기지 않는다 |
| `make shell-build` optdebug, 처음 / 한 줄 고친 뒤 | PASS, 855초(RSS 합 최대 2.2GiB) / 39초 |
| `make shell-build` release, 처음 | PASS, 892초(RSS 합 최대 1.7GiB) |
| 스모크(서버, csql, PL/CSQL), optdebug·release | PASS |
| 코어 생성 | 안 된다. `ulimit -c`를 올릴 수 없고 SIGSEGV로 죽은 프로세스가 코어를 남기지 않는다 |
| CTP sql `_01_object/_04_trigger`, 직접 샤드 | PASS. 배정 82, 실행 82, 통과 82, 실패 0, 건너뜀 0, 미실행 0, 코어 0. 남은 프로세스·포트·공유 메모리·DB 볼륨 없음. 91초 |
| CTP medium `_07_mc_dep`, 직접 샤드 | PASS. 배정 54, 실행 54, 통과 54, 실패 0, 건너뜀 0, 미실행 0, 코어 0. 남은 것 없음. 50초 |
| 끝난 뒤의 좀비, PID 1이 떠맡은 프로세스 | 대조 실험이 일부러 만든 좀비 1개뿐이고, 떠맡은 것은 없다 |
| 디스크 | 10GiB쯤: 스토어 1.6G, 엔진과 빌드 트리 4.5G, 테스트케이스 0.5G, ccache 등 1.1G, CTP 결과 등 1.8G |

다시 돌리려면 6.35에서 `cleanroom/restricted/run.sh`를 실행한다. 단계와 판정은 `cleanroom/restricted/inside.sh`에
있다. 다른 곳에서 만든 코어를 읽는 것(외부 코어 판독)은 이번에는 확인하지 않았다.
