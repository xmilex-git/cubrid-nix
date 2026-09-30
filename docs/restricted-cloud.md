# 제한 클라우드에서 쓰기

root, `/nix`, user namespace, 코어 덤프가 없는 원격 환경(Codex 클라우드 등)에서 이 레포를 쓰는 방법이다.
결정과 이유는 [ADR 0003](adr/0003-user-store-without-root.md)에 있다. 아래 설정은 그 환경을 흉내 낸
컨테이너(`cleanroom/restricted`)에서 확인한 것이다. 실제 원격 환경에서 확인한 것은 아니다.

## 무엇이 되고 무엇이 안 되나

| 항목 | 이 환경에서 |
|---|---|
| nix 설치 | 된다. 사용자 홈에, root 없이 |
| 개발 셸 | 된다. GitHub 캐시에서 받는다 |
| optdebug 빌드(`make shell-build`) | 된다. 증분 빌드도 된다 |
| CI와 같은 빌드(`make build`) | 된다. 샌드박스 없이 돈다 |
| 서버, csql, PL/CSQL | 된다 |
| CTP sql·medium | 된다. 샤드 하나가 격리 없이 돈다. 이 사용자의 다른 CUBRID가 있으면 시작하지 않는다 |
| 셸 케이스 한 건 | 된다. 다른 CUBRID 프로세스, 공유 메모리, 포트 사용이 없을 때만 시작한다 |
| shell 스위트 전체 | 하지 않는다. 업스트림 CI가 돌린다 |
| gdb로 코어 읽기 | 된다. 다른 환경에서 같은 설치본이 만든 코어(외부 코어)를 읽는다 |
| 코어 만들기 | 안 된다. 커널이 코어를 쓰지 않는다 |
| 라이브 서버에 gdb 붙이기 | 하지 않는다. 이 레포의 규칙이다 |

## 설치 스크립트

환경의 설치(setup) 스크립트에 넣는다. 인터넷이 있을 때 한 번 돌고, 다시 돌아도 된다. 작업 저장소(엔진)의
루트에서 돈다고 가정한다.

```bash
set -euo pipefail
# cubrid-nix와 사용자 권한 nix: 환경을 검사하고, 캐시에서 개발 셸을 받는다
if [ -d ~/cubrid-nix/.git ]; then git -C ~/cubrid-nix pull -q --ff-only
else git clone -q https://github.com/xmilex-git/cubrid-nix ~/cubrid-nix; fi
~/cubrid-nix/install.sh --profile
# 엔진: build.sh는 2019-12-12 이후의 커밋 수로 버전을 매기고, CI는 서브모듈을 모두 빌드한다
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  git fetch -q --shallow-since=2019-12-01 origin
fi
git submodule update -q --init
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
already). Recipes run from ~/cubrid-nix; they enter `nix develop` themselves. ENGINE is the
engine checkout (the task's repository).

- Build: `make shell-build WORKTREE=$ENGINE` (MODE=release for release). The install is
  ~/cubrid-nix/.scratch/install/<checkout name>-optdebug-shell. After any source change run it
  again: the binary caches hold no build of your source. The first build takes the longest;
  later ones are incremental.
- Smoke: `make smoke INSTALL=<install>` (server, csql, PL/CSQL).
- Server by hand: `env=$(~/cubrid-nix/scripts/rundir.sh <install> <new run dir>) && . "$env"`,
  then cubrid/csql as usual; stop with `cubrid service stop`.
- CTP: `make ctp SUITE=sql|medium INSTALL=<install> TC_REF=<ref> [ONLY='<dir> ...']` (or PR=<n>).
  Here it runs one shard without isolation and refuses while this user runs other CUBRID
  processes. Never run ctp.sh directly.
- One shell case: `make shell-case INSTALL=<install> CASE=<dir under shell/> TESTCASES=<private-ex checkout>`.
  Never run a whole shell suite.
- Cores: this environment cannot write cores. Read a core that the same install wrote elsewhere:
  `nix build --no-link <install store path>` then, in ~/cubrid-nix,
  `nix develop -c scripts/gdb-core.sh <install> <core> <out dir>`. Never attach gdb to a live server.
- Report each check as PASS, FAIL or NOT RUN with its log; say "verified in this environment"
  only for what ran here.
```

## 검증

2026-09-30, `cleanroom/restricted`의 흉내 낸 컨테이너에서 확인했다. 실제 원격 환경에서 확인한 것은
아니다. 조건, 흉내 내지 못한 것, 찾아서 고친 결함은 [ADR 0003](adr/0003-user-store-without-root.md)의 검증
절에 있다.

| 항목 | 결과 |
|---|---|
| 설치, GitHub 캐시만 | 116초. 개발 셸 경로 137개(432.5MiB)를 받아 스토어 1.3GiB |
| 설치, 사내 캐시 | 17–23초 |
| 새 셸, `/var/tmp`를 비운 뒤 | 링크를 다시 만들고 사용자 스토어를 쓴다 |
| 엔진 clone(2019-12 이후 이력과 서브모듈) | 48–71초, 489MB |
| `make shell-build`, 처음 | 283초, RSS 합 최대 5.1GiB |
| 한 줄 고친 뒤 다시 | 35초 |
| `make build` | 302초, RSS 합 최대 5.0GiB(가장 큰 프로세스 2.7GiB) |
| 스모크(서버, csql, PL/CSQL) | 통과 |
| 코어 생성 | 안 된다. `ulimit -c`를 올릴 수 없고, SIGSEGV로 죽은 프로세스가 코어를 남기지 않는다 |
| 외부 코어 판독 | PASS. 6.35에서 SIGABRT로 만든 코어(4.8GB)를 GitHub 캐시에서 받은 같은 설치본으로 읽었다. 스레드 164개, 파일·줄이 붙은 CUBRID 프레임 608개, 지역 변수 20개, 빌드 ID 경고 0 |
| CTP sql `_01_object/_04_trigger`, 직접 샤드 | 82/82, 104초 |
| CTP medium `_07_mc_dep`, 직접 샤드 | 54/54, 51초 |
| 셸 케이스 `_01_utility/_17_loaddb/bug_xdbms184`, 직접 모드 | PASS(OK 2, NOK 0), 남은 것 없음, 11초 |
| 같은 홈에서 다시(설치, 스모크, 셸 케이스) | PASS. nix를 다시 받지 않았다 |
| 디스크 | 10GiB쯤: 스토어 2.7G, 엔진과 빌드 트리 4.2G, ccache 등 1.1G, CTP 테스트케이스 등 2.2G |

다시 돌리려면 6.35에서 `cleanroom/restricted/run.sh <private-ex 체크아웃> <외부 코어 디렉터리>`를 실행한다.
