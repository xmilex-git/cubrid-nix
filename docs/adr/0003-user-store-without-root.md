---
status: accepted
date: 2026-09-30
---

# 사용자 권한만으로 설치한다: /nix 밖의 스토어와 줄인 closure

제한된 원격 환경(Codex 클라우드)에서도 이 레포를 쓰려고 한다. 그 환경은 이렇다.

- root도 sudo도 없고, `/nix`가 없으며 만들 수도 없다.
- user namespace가 없다. 그래서 nix의 chroot 스토어와 빌드 샌드박스, 러너의 샤드를 쓸 수 없다.
- 코어 덤프가 나오지 않고, `core_pattern`이 보이지 않는다.
- CPU는 16개, 메모리는 8GiB쯤이다(사용자가 전한 사양, 2026-09-30). 처음 받은 설명은 CPU quota 4,
  메모리 32GiB쯤이었다. 디스크는 22GiB쯤이다.
- gcc/g++ 14.2, make, Java 21 런타임은 있다. nix, gdb, cmake, ninja, javac는 없다.

위의 값은 그 환경의 한 시점 값이다. `install.sh`는 이 값들을 설치할 때마다 다시 검사한다.

사용자는 이렇게 정했다(2026-09-30).

- `/nix`를 요구하지 않는다. 기본값도 더 나은 디렉터리로 바꾼다.
- root 없이 사용자 권한만으로 되게 설계한다.
- just를 버리고 Makefile로 바꾼다.
- 쓰지 않는 perf를 뺀다. LLVM과 clang도 필요 없으면 뺀다.

## D1 — 스토어: `/var/tmp/cubrid-nix/store`, 실제 위치는 홈

- **결정:** 스토어 경로는 `/var/tmp/cubrid-nix/store`다. 실제 파일은 `~/.local/share/cubrid-nix`
  (`CUBRID_NIX_HOME`)에 있다. `/var/tmp/cubrid-nix`가 그 디렉터리를 가리키는 심볼릭 링크다.
  - nix는 스토어 경로에 심볼릭 링크가 끼는 것을 막는다. 그래서 `allow-symlinked-store = true`를 둔다.
  - 상태(`var/nix`)와 로그도 홈에 둔다. 스토어 경로만 모두에게 같으면 된다.
  - `env.sh`는 `NIX_STORE_DIR`, `NIX_STATE_DIR`, `NIX_LOG_DIR`도 내보낸다. `store` 설정만 두면 nix가
    여는 다른 스토어, 곧 substituter가 `/nix/store`를 기본값으로 가져서 이 스토어의 캐시를 거절한다
    (`binary cache ... is for Nix stores with prefix '/var/tmp/cubrid-nix/store', not '/nix/store'`).
    개발 셸 안에서는 stdenv의 `NIX_STORE`가 같은 일을 해서, 처음에는 개발 셸 밖의 설치에서만 드러났다.
  - nix의 캐시(`NIX_CACHE_HOME`)도 스토어마다 따로 둔다. 평가 캐시는 스토어 경로를 가리지 않아서, 한
    호스트에 `/nix`도 있으면 다른 스토어의 경로를 돌려준다.
- **이유:**
  - 스토어 경로는 결과물 안에 문자열로 박힌다. 인터프리터 경로, RPATH, 스크립트의 셔뱅이 그렇다.
    바이너리 캐시를 나눠 쓰려면 스토어 경로가 모든 머신에서 같아야 한다.
    - 홈 아래 경로는 사용자마다 달라서 캐시를 나눠 쓸 수 없다.
    - cache.nixos.org의 바이너리는 `/nix/store`를 가리키므로 이 스토어에는 쓸 수 없다. 이 스토어의
      closure는 우리가 한 번 소스에서 빌드해 우리 캐시로 준다(D3, D4).
  - `/var/tmp`는 FHS가 정한 디렉터리다. 어느 배포판에서나 모두가 쓸 수 있는 sticky 디렉터리라서, root
    없이 `cubrid-nix`를 만들 수 있다.
  - 실제 파일을 홈에 두는 이유는 두 가지다. systemd-tmpfiles는 `/var/tmp`에서 30일 동안 쓰지 않은 파일을
    지운다. 또 `/var/tmp`는 작은 파일 시스템일 수 있다.
    - 링크는 지워져도 된다. `env.sh`가 셸마다 링크를 확인하고, 없으면 다시 만든다.
- **조건:** 링크는 이 사용자의 것이어야 하고, 이 홈을 가리켜야 한다. 다른 사용자가 먼저 만든 링크는 쓰지
  않는다. 그 사용자의 스토어를 실행하게 되기 때문이다. 그래서 호스트 하나에서는 한 사용자만 이
  스토어를 쓸 수 있다.
- **대가:** 스토어 경로에 링크가 끼면, 경로를 끝까지 풀어 쓰는 빌드가 홈 쪽 경로를 결과물에 남길 수 있다.
  캐시에서 받은 경로에는 해당하지 않는다. 빌드는 이 레포의 CUBRID derivation과 몇 초짜리
  derivation에만 해당한다.
  - `--impure` 평가도 링크를 푼다. 그래서 이 flake를 스토어 경로로 읽을 때, nix가 쓰지 않은 실제 경로를
    찾는다(`…-source/flake.nix does not exist`). `builtins.getFlake`도 그렇다. 레시피는 pure 평가만 쓴다.
    `make shell-build`의 seed는 워크트리에서 봉인 입력을 선언하는 파일 셋만 복사해 `cubrid-src` 입력으로
    넘긴다. `make build`가 소스를 넘기는 방식과 같다.
- **고려한 것:**
  - chroot 스토어(`--store ~/nix`): 빌드와 실행에 user namespace가 필요하다.
  - proot, nix-portable: ptrace나 bwrap(user namespace)가 필요하다. 제3자 도구가 하나 더 든다.
  - 사용자마다 다른 경로(`/var/tmp/cubrid-nix-<uid>` 등): 캐시를 uid마다 따로 만들어야 한다.
  - `nix bundle`로 만든 이동 가능한 묶음: 개발 셸과 빌드가 되지 않는다.

## D2 — nix 자체: NixOS Hydra의 정적 빌드

- **결정:** nix는 Hydra가 만든 정적 바이너리 하나를 쓴다. root도 데몬도 필요 없다.
  - 출처는 NixOS Hydra `nix` 잡셋의 `buildStatic.nix-cli.x86_64-linux`, 빌드 346771304다. nix
    2.35.3이고 musl에 정적으로 링크돼 있다.
  - 파일은 37,909,048바이트이고 sha256은
    `87d01ef8b4e6ee488c2defc4fde9a6fb3fd6ca5d344219c157fb426f93eeb507`다. Hydra가 기록한 값과 같다.
    같은 스토어 경로가 cache.nixos.org에 서명돼 있다.
  - `install.sh`는 이 레포의 `nix-static` 릴리스에 둔 사본을 먼저 받고, 안 되면 Hydra에서 받는다. 어느
    쪽이든 sha256이 맞아야 설치한다.
- **추가 권한:** 없다. 사용자 파일만 쓰고, 데몬이나 setuid 없이 호출한 프로세스 안에서만 돈다.
- **버전:** ADR 0001 D12처럼 nix 버전은 이 레포와 묶이지 않는다. 이 바이너리는 설치에 쓰는
  출발점이다. 올리려면 `install.sh`의 버전, sha256, URL을 바꾼다.
  - 다른 일에는 사용자가 다른 nix를 써도 된다. `env.sh`를 읽지 않은 셸은 이 nix를 보지 않는다.
- **고려한 것:** 공식 설치 스크립트는 `/nix`를 만든다. nix를 소스에서 빌드하려면 이미 nix나 여러 빌드
  도구가 있어야 한다.

## D3 — closure를 줄인다

- **결정:** 이 스토어의 closure는 모두 소스에서 빌드된다(D1). 그래서 빌드에만 무겁게 드는 것을
  잘라 낸다. `/nix` 사용자도 같은 flake라 같은 변형을 쓴다.
  - perf를 뺀다(D11).
  - gdb는 source-highlight(boost)와 debuginfod 없이, 호스트 CPU만 지원하게 빌드한다.
  - procps는 systemd 없이 빌드한다. systemd의 BPF 프로그램 때문에 LLVM이 들어왔다.
  - iproute2는 iptables(boost), elfutils, libbpf 없이 빌드한다. 샤드는 `ip link set lo up`만 쓴다.
  - util-linux는 minimal을 쓴다.
  - curl은 minimal을 쓰고, git도 그것으로 빌드한다.
  - ccache는 매뉴얼 없이 빌드한다. asciidoctor는 Ruby가 필요하고, Ruby의 JIT는 Rust와 LLVM이
    필요하다. 테스트도 돌리지 않는다.
  - CI 스냅샷은 RPM을 bsdtar로 푼다. rpm 패키지는 매뉴얼을 pandoc(GHC)으로 만든다.
- **결과:** 소스에서 빌드할 derivation이 2,353개에서 731개로 줄었다. rustc, LLVM, clang, boost,
  GHC, pandoc, Ruby, systemd는 하나도 빌드하지 않는다.
- **LLVM과 clang:** 필요 없다. CUBRID는 CI의 gcc 8.5로 빌드한다. clang은 systemd의 BPF와 Ruby의
  JIT를 통해서만 들어왔다.
- **확인:** bsdtar로 푼 스냅샷의 NAR 해시가 rpm2cpio로 푼 것과 같아야 한다. `/nix`에서의 빌드, 서버,
  CTP, gdb도 그대로 돼야 한다. 결과는 검증 절에 있다.

## D4 — 캐시는 스토어 경로마다 따로 둔다

- **결정:** nix 캐시 하나는 스토어 경로 하나의 경로만 담는다(`nix-cache-info`의 `StoreDir`).
  그래서 사용자 스토어는 캐시를 따로 가진다.
  - 사내 캐시는 원래 디렉터리 아래의 `var-tmp-cubrid-nix-store/`다. 서버가 디렉터리를 그대로 내보내므로
    `http://192.168.6.4/var-tmp-cubrid-nix-store`로 받는다. 서버 컨테이너는 바꿀 것이 없다.
  - GitHub 캐시는 `nix-cache-var-tmp-cubrid-nix-store` 릴리스다.
  - 두 캐시 모두 closure 전부를 담는다. 다른 곳에는 이 스토어의 경로가 없기 때문이다. flake 입력의
    소스는 빼고, 클라이언트가 GitHub에서 받는다.
- **이름:** 스토어 경로의 `/`를 `-`로 바꾼 것이 디렉터리와 릴리스의 이름이다. `scripts/cache-lib.sh`가
  돌리는 nix의 스토어를 보고 정한다.
- **갱신:** `make cache-update`는 그것을 돌리는 nix의 스토어 캐시만 갱신한다. 두 스토어를 모두 맞추려면
  스토어마다 한 번씩 돌린다([docs/cache-maintenance.md](../cache-maintenance.md)).

## D5 — just 대신 Makefile

- **결정:** 레시피 본문은 `scripts/`의 스크립트로 옮기고, `Makefile`은 변수를 받아 스크립트를 부른다.
  - 레시피는 개발 셸 밖에서 부르면 스스로 `nix develop`에 들어간다.
  - 스크립트는 따로 불러도 된다.
- **이유:** 대상 환경에는 just가 없고, just를 쓰려면 받을 것이 하나 더 는다. GNU make는 있다. 개발
  셸에도 CI의 make 4.2.1이 있다.
- **대가:** 인자를 이름으로 준다(`make build WORKTREE=~/cubrid`). zsh는 `WORKTREE=~/...`의 `~`를 풀지
  않으므로 Makefile이 앞의 `~`를 `$HOME`으로 바꾼다.

## D6 — shell-build와 `/usr/include/malloc.h`

- **사실:** `src/heaplayers/malloc_2_8_3.c`는 `/usr/include/malloc.h`를 절대 경로로 include한다.
  `--sysroot`는 절대 경로에 닿지 않는다. 그러나 이 include는 `lea_heap.c`가 먼저 부른
  `memory_cwrapper.h`의 `<malloc.h>` 뒤에 온다. 그것은 스냅샷의 glibc 2.28 헤더다. 그래서 같은
  include guard(`_MALLOC_H`)를 가진 호스트 파일은 내용 없이 열렸다 닫힌다. CI 툴체인으로 `lea_heap.c`를
  전처리해 보면, `/usr/include/malloc.h`는 들어갔다가 줄 하나 없이 나온다.
- **결정:** `scripts/shell-build.sh`는 CI 전처리기로 확인한다. `<malloc.h>`만 전처리한 결과와, 거기에
  호스트 파일을 더 include한 결과를 비교한다.
  - 같으면: 호스트 파일이 더하는 것이 없으므로 그대로 빌드한다. glibc 2.41이나 musl도 guard가 같다.
  - 다르거나 파일이 없으면: user namespace가 있을 때만 mount namespace 안에서 스냅샷의 파일로 바꾼다.
  - 둘 다 안 되면: 이유를 적고 멈춘다. `make build`는 이 include를 derivation 안에서 고치므로 늘 된다.
- **이유:** 검사 없이 호스트 헤더를 쓰면, 파일이 다른 선언을 더할 때 CI와 다른 결과가 조용히 나온다.

## D7 — 네임스페이스가 없으면 거부로 격리한다

- **사실:** 네임스페이스가 없으면 CTP의 `pkill cub`와 셸 케이스의 `ipcrm`이 이 사용자의 모든 프로세스와
  공유 메모리에 닿는다. 샤드 밖을 막을 방법이 없다.
- **결정:** 러너의 직접 샤드(ADR 0001 D11)와 `make shell-case`는 이 사용자에게 `cub`로 시작하는
  프로세스가 있으면 시작하지 않는다. `pkill cub`가 죽일 이름들이다.
  - 셸 케이스는 이 사용자의 공유 메모리 세그먼트가 있거나 conf의 포트를 누가 쓰고 있어도 시작하지
    않는다. `finish`가 이 사용자의 세그먼트를 모두 지우기 때문이다.
  - 끝난 뒤에는 이 실행의 프로세스만 정리한다. 이 실행의 프로세스는 `CUBRID`가 이 실행의 디렉터리를
    가리키는 프로세스다.
- **한계:** 시작한 뒤에 다른 작업이 CUBRID를 띄우는 것은 막지 못한다. 그런 환경에서는 네임스페이스가
  있는 곳에서 돌린다.

## D8 — 셸 케이스 하나를 돌리는 명령

- **결정:** `make shell-case`(`scripts/shell-case.sh`)는 CTP 셸 가이드 2.3절과 CTP의
  `Test.runTestCase_linux`가 케이스 하나를 돌리는 방식을 그대로 따른다.
  - `init_path`, `CTP_HOME`, `CUBRID_CHARSET=en_US`를 둔다. `en_US`는 CTP의 기본값이다.
  - `<케이스>/cases`에서 `<케이스>.result`를 비우고 `<케이스>.sh`를 돌린다.
  - 스위트 러너는 아니다. shell 전체는 업스트림 CI가 맡는다(ADR 0001 D2).
- **쓰기 가능한 사본:** 설치본의 실행 디렉터리, CTP 사본, 케이스 사본을 `shell/` 아래 같은 상대 경로에
  만든다. 케이스는 자기 디렉터리에 결과와 DB를 쓰고, init.sh는 conf를 고쳤다가 되돌린다.
  테스트케이스 체크아웃과 설치본은 건드리지 않는다.
- **셸:** CTP는 `sh <케이스>.sh`로 돌린다. CI 이미지(Rocky)의 `sh`는 bash다. Debian 계열의 `sh`는 dash라서
  init.sh의 `function` 문법을 읽지 못한다. 그래서 bash로 돌린다.
- **판정:** 두 가지가 모두 맞으면 PASS다.
  - `<케이스>.result`에 OK 줄이 있고 NOK 줄이 없다.
  - 끝난 뒤 이 실행의 프로세스, 세그먼트, 포트가 남지 않았고, 등록된 DB가 없다.
  - 결과는 `verdict.tsv`에 남는다. 케이스 sha, 엔진, CTP, 모드, 정리 결과가 들어간다.

## D9 — 코어: 만들 수 없는 곳에서는 다른 곳에서 만든 코어를 읽는다

- **사실:** 코어 덤프가 막힌 환경(`RLIMIT_CORE` hard 0, `core_pattern`을 볼 수 없음)에서는 커널이
  코어를 쓰지 않는다. 라이브 서버에 gdb를 붙이는 것은 이 레포가 금한다.
- **결정:** 그런 환경에서는 다른 환경에서 만든 코어를 gdb로 읽는다(`scripts/gdb-core.sh`).
  - 코어를 만든 설치본과 같은 파일이어야 한다. 바이너리 캐시에서 받은 설치본은 바이트까지 같다.
    그래서 캐시는 기본 엔진 입력(`flake.lock`의 develop)으로 빌드한 optdebug 설치본도 담는다. 사용자의
    워크트리로 빌드한 설치본은 여전히 담지 않는다(ADR 0002 D3).
  - `gdb-core.sh`는 스레드 목록, 모든 스레드의 backtrace, 죽은 스레드의 지역 변수를 본다. 빌드 ID가
    맞지 않는다는 경고가 없는지도 본다.
- **구분:** 보고서에는 "외부 코어 판독: 됨"과 "그 환경에서 코어 생성: 안 됨"을 따로 적는다. 코어 생성
  시도의 결과(ulimit, `core_pattern`)도 근거로 남긴다.

## D10 — CPU quota

- **사실:** `build.sh`의 ninja 1.11은 cgroup의 CPU quota를 보지 않는다. 그래서 `nproc + 2`개의 작업을
  띄운다. 큰 호스트에서 quota가 4이면 컴파일러 수십 개가 메모리를 넘친다.
- **결정:** 개발 셸은 cgroup의 `cpu.max`(v2)나 `cpu.cfs_quota_us`(v1)를 읽어
  `CMAKE_BUILD_PARALLEL_LEVEL`을 정한다. `install.sh`는 같은 값을 nix의 `cores`에 둔다.
  - 사용자가 `CMAKE_BUILD_PARALLEL_LEVEL`을 이미 두었으면 그 값을 쓴다.

## D11 — perf를 뺀다

- **결정:** perf를 개발 셸에서 뺀다(사용자 결정 2026-09-30: 쓰지 않는다). ADR 0001 D10의 perf 부분을
  대신한다.
  - gdb와 심볼 규칙(strip 금지, 라이브 서버 attach 금지)은 그대로다.
  - perf는 closure에 리눅스 커널 소스 빌드를 더하고, 제한된 환경에서는 `perf_event_open`이 막혀 있다.

## D12 — 빌드, 서버, 테스트는 자식 회수 래퍼 아래에서 돈다

- **사실:** 제한 클라우드의 PID 1은 고아 프로세스를 회수하지 않는다(2026-10-01 보고). 빌드가 남긴 프로세스가
  PID 1 밑에서 좀비로 쌓였다.
  - 부모보다 오래 사는 프로세스는 PID 1에게 넘어간다. Gradle의 일회용 데몬은 Gradle 클라이언트보다 늦게
    끝나고, `cubrid server start`는 데몬을 띄운다.
  - 흉내 컨테이너도 PID 1을 `sleep infinity`로 두면 같다. 래퍼 없이 고아 하나를 만들면 좀비 하나가 남는다.
- **결정:** `scripts/reap.py`가 명령을 child subreaper(`prctl(PR_SET_CHILD_SUBREAPER)`)로 돌린다. 모든 make
  레시피가 그 아래에서 돈다.
  - 명령의 자손 가운데 고아가 된 것은 PID 1이 아니라 래퍼에게 온다. 래퍼는 그것들을 모두 회수한다.
  - 명령이 끝나면 남은 자손에게 SIGTERM을 보내고, 10초 뒤 남은 것에 SIGKILL을 보낸다. 무엇을 멈췄는지
    stderr에 적는다. `--wait`이면 멈추지 않고 그것들이 끝날 때까지 기다린다. 명령보다 오래 살아야 하는
    서버를 손으로 띄울 때 백그라운드로 쓴다.
  - 종료 코드는 명령의 것이다.
- **이유:** 개발 셸의 python3로 돌아서, flake도 캐시도 바뀌지 않는다. tini 같은 init은 자기 자식이 끝나면
  같이 끝나므로, 그 뒤에 끝나는 데몬은 다시 PID 1에게 간다.
- **대가:** 래퍼는 명령이 끝날 때 남은 자손을 멈춘다. 서버를 명령 하나보다 오래 띄우려면 `--wait`로 띄운다.

## D13 — `core_pattern`을 읽을 수 없으면 코어를 모으지 않고 계속한다

- **사실:** 제한 클라우드에서는 `/proc/sys/kernel/core_pattern`을 읽을 수 없다. 러너는 `set -e`에서 그 읽기가
  실패하자 케이스를 하나도 돌리지 않고 끝났다(2026-10-01 보고). 흉내 컨테이너는 그 파일을 빈 파일로
  가렸기 때문에 이 경로를 밟지 않았다.
- **결정:** 읽기가 실패하면 `CORE_MODE=none`, `CORE_DIR`를 빈 값으로 두고 경고한 뒤 계속한다. 읽은 값의 형식에
  따른 판정은 그대로다. pipe, 절대 경로, 상대 경로, 빈 값이다. 커널과 보안 설정은 건드리지 않는다.
- **확인:** `ctp/test_core_capture.sh`가 함수를 `ctp_run.sh`에서 그대로 떼어 `set -euo pipefail`로 돌린다.
  확인하는 경우는 파일 없음, 읽기 권한 없음, 디렉터리, 그리고 기존 네 형식이다. 고치기 전 함수로는 앞의
  셋이 exit 1로 실패한다. 흉내 컨테이너는 이제 `/proc/sys/kernel`을 가려 그 파일이 없게 한다.

## 검증

### 제한 클라우드 흉내, 둘째 (2026-10-01, cubrid-nix `5a7b361`)

- **바뀐 조건:** 제한 클라우드의 보고에 맞췄다. PID 1이 회수하지 않고(`sleep infinity`, 단계는
  `podman exec`로 돈다), `core_pattern`은 읽을 수 없다(`/proc/sys/kernel`을 가렸다). CPU는 4개이고, 저장소는
  `/workspace/<저장소명>`, 엔진은 전체 이력이다. 엔진 develop `a59140bdd`, cubrid-testcases develop `fde71bc5f`, CTP `4d0043a`, nixpkgs `50ab793`, nix 2.35.3, gcc 8.5.0, cmake 3.26.5, gdb 15.2.
- **결과:**

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

- **찾아서 고친 것:**
  - 러너의 코어 감시 루프는 멈출 때 서브셸만 죽였다. 그 안의 `sleep`은 고아로 남아, 회수하지 않는 PID 1의
    좀비가 될 뻔했다. 래퍼가 그것을 잡아 멈추고 기록했고, 하네스는 그 실행을 FAIL로 판정했다. 이제 sleep을
    백그라운드로 두고 trap이 함께 끝낸다.
  - git은 fetch 뒤의 자동 유지 보수를 떼어서 돌린다. 그것도 PID 1의 좀비로 남았다. 설치 스크립트와 하네스는
    `gc.autoDetach`와 `maintenance.autoDetach`를 끈다.
- **확인하지 않은 것:** 실제 Codex 클라우드, 메모리 한도, 이번 회차의 외부 코어 판독.

### 제한 클라우드 흉내 (2026-09-30, `cleanroom/restricted`, 엔진 develop `35f528e89`)

- **흉내 낸 조건:** Debian trixie(gcc 14.2.0, GNU make 4.4.1, OpenJDK 21), uid 1000, 만들 수 없는
  `/nix`, user namespace 없음(seccomp가 `unshare`와 `clone(CLONE_NEWUSER)`를 거절), `RLIMIT_CORE`
  hard 0, 가려진 `core_pattern`, CPU 16개(affinity).
- **흉내 내지 못한 것:** 메모리 한도와 디스크 크기. 이 호스트의 rootless cgroup v1은 둘 다 걸지 못한다.
  그래서 단계마다 RSS 합의 최대치를 재서 8GiB와 비교했다. 공유 페이지를 겹쳐 세므로 실제보다 크다.
  CPU도 cgroup quota가 아니라 affinity로 묶었으므로, D10의 quota 계산은 읽어서만 확인했다.
- **결과:** 테스트케이스 `7bd8ebbc`, CTP `4d0043a`, private-ex `e01a78bfc`, nixpkgs `50ab793`.

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

- **사용자 스토어 캐시:** closure는 경로 248개다. GitHub 릴리스에는 flake 입력의 소스를 뺀 246개
  (1,012MiB, 파일 493개)를, 사내 캐시에는 1.2GiB를 올렸다. 이 closure는 6.35(64코어)에서 소스로
  빌드했고, 중간에 다시 시작한 것까지 두 시간쯤 걸렸다.
- **찾아서 고친 결함:**
  - `store` 설정만 두면 substituter가 `/nix/store`를 기본값으로 가져 이 스토어의 캐시를 거절했다(D1).
  - `--impure` 평가와 `builtins.getFlake`는 링크가 낀 스토어에서 이 flake를 읽지 못했다(D1).
  - 평가 캐시가 스토어 경로를 가리지 않아, 한 호스트의 두 스토어가 서로의 경로를 받았다(D1).
  - libarchive의 bsdcpio 테스트는 XFS가 2^32보다 큰 inode 번호를 줄 때 실패했다. Hydra에서는 같은
    소스가 통과했으므로, 스토어가 `/nix` 밖일 때만 libarchive의 테스트를 건너뛴다(D3).
  - 새 빌드 트리에서 툴체인 검사가 `pipefail`로 말없이 멈췄다(D6).
  - GitHub 릴리스는 올린 직후 1분쯤 404를 돌려준다. 검증 전에 기다린다(D4).
  - 러너의 직접 샤드가 provenance에 `runner=unshare`로 적혔다. 이제 `direct`로 적는다.
- **확인하지 않은 것:** 실제 Codex 클라우드. 위는 흉내 낸 컨테이너의 결과다. 메모리 8GiB 한도와
  cgroup CPU quota를 실제로 걸어 보지는 못했다.

### `/nix` 경로 회귀 (2026-09-30, 6.35, 엔진 develop `35f528e89`)

closure를 줄인 flake로 `/nix`에서 다시 확인했다. 처음에는 세 곳이 실패했고, 고친 뒤 모두 통과했다.

- **찾은 결함:**
  - bsdtar는 앞서 만든 링크를 지나는 항목을 풀지 않는다(`Cannot extract through symlink sbin/ldconfig`).
    그래서 `-P`를 준다. 32개 RPM의 항목 7,318개는 모두 `./`로 시작하고 `..`가 없다.
  - asciidoctor를 빼면 ccache의 `man` 출력이 생기지 않아 빌드가 실패했다. 출력을 `out` 하나로 둔다.
  - `shell-case.sh`는 등록된 DB가 없을 때, 곧 깨끗하게 끝났을 때 `pipefail`로 판정을 쓰기 전에 멈췄다.
- **스냅샷:** bsdtar로 푼 스냅샷의 NAR 크기(282,983,568바이트)와 파일 목록이 rpm2cpio로 푼 것과 같다.
  바이트가 다른 파일 53개는 patchelf가 고친 프로그램이고, 스냅샷 자신의 스토어 경로만 다르다.
- **개발 셸 closure:** 경로 230개 1.48GiB에서 152개 1.20GiB가 됐다. perf, systemd, boost, gnupg가
  빠졌다.
- **결과:**

  | 항목 | 결과 |
  |---|---|
  | `make build` (optdebug) | 260초 |
  | 새 체크아웃의 `make shell-build` | 306초. 바뀐 것이 없을 때 다시 돌리면 61초 |
  | 스모크(두 설치본) | 통과 |
  | CTP sql `_01_object/_04_trigger` / medium 전체 | 82/82 / 975/975 (테스트케이스 develop `f1c9f42a`) |
  | 셸 케이스 `_01_utility/_17_loaddb/bug_xdbms184` | PASS(OK 2, NOK 0), 남은 것 없음, 네임스페이스 모드 |
  | gdb(커널 코어, SIGABRT) | PASS. 스레드 164개, 파일·줄이 붙은 CUBRID 프레임 608개, 지역 변수 20개 |

- **더 고친 것:** 이전 툴체인으로 configure한 빌드 트리에서는 `make shell-build`가 아무것도 다시
  컴파일하지 않고, 이전 스냅샷에 링크된 결과를 그대로 설치했다. 이제 빌드 트리의 컴파일러 기록
  (`CMakeCCompiler.cmake`)이 현재 스냅샷을 가리키지 않으면 멈추고, 그 디렉터리를 지우라고 알린다.
