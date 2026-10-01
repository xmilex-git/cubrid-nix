# cubrid-nix

아무것도 설치되지 않은 x86_64 리눅스에서 **root 없이 사용자 권한만으로**, CUBRID CI와 같은 툴체인과
도구 버전으로 엔진 빌드 → 서버 실행 → CTP → gdb 코어 분석까지 할 수 있게 하는 nix flake다. 아래
[따라 하기](#따라-하기)를 위에서부터 그대로 실행하면 된다.

> 결정과 이유는 [ADR 0001](docs/adr/0001-reproduce-ci-environment-with-nix.md)과
> [ADR 0003](docs/adr/0003-user-store-without-root.md)(사용자 권한 설치), 용어는 [CONTEXT.md](CONTEXT.md),
> 들어 있는 패키지와 그 이유는 [근거표](docs/packages.md)에 있다. root도 `/nix`도 user namespace도 없는
> 원격 환경(Codex 클라우드 등)에서 쓰는 법은 [제한 클라우드](docs/restricted-cloud.md)에 있다.

## 보장 문구

> x86_64 리눅스, 사용자 권한, 호스트에는 git과 curl(또는 wget), CA 번들만 있으면 된다. nix는
> `install.sh`가 사용자 홈에 설치하고, 스토어는 `/var/tmp/cubrid-nix/store`다. `/nix`가 있는 호스트는
> 그쪽을 써도 된다. CTP 병렬 실행과 nix 빌드 샌드박스는 user namespace가 필요하다. 없으면 CTP는 샤드
> 하나가 격리 없이 돌고, 이 사용자의 다른 CUBRID가 떠 있으면 시작하지 않는다. fsync 끄기는 커널 5.11
> 이상이면 volatile overlay, 아니면 eatmydata다. 코어는 커널이 코어를 쓸 수 있을 때만 생긴다. 쓸 수
> 없는 환경에서는 다른 곳에서 같은 설치본이 만든 코어를 읽는다. 처음 한 번은 네트워크가 필요하고, 빌드와
> 실행은 네트워크 없이 돈다.

## 따라 하기

1–3은 새 환경에서 한 번만 한다. 레시피는 `make`로 부른다. 레시피가 개발 셸(`nix develop`)에 스스로
들어가므로, 새 셸에서는 `env.sh`만 읽으면 된다. `make`를 인자 없이 실행하면 레시피 목록이 나온다.
레시피는 자식 회수 래퍼(`scripts/reap.py`) 아래에서 돈다. 그래서 PID 1이 고아 프로세스를 회수하지 않는
컨테이너에서도 좀비가 남지 않는다([ADR 0003](docs/adr/0003-user-store-without-root.md) D12).

### 1. 이 레포와 nix (사용자 권한)

```bash
git clone https://github.com/xmilex-git/cubrid-nix ~/cubrid-nix
~/cubrid-nix/install.sh --profile
. ~/.local/share/cubrid-nix/env.sh        # 새 셸마다. --profile이면 로그인 셸이 알아서 읽는다
```

- `install.sh`는 root 없이 돈다. 하는 일은 다음과 같다.
  - 환경을 검사한다: CPU quota, 메모리, 디스크, user namespace, 코어 덤프, CA 번들.
  - nix 2.35.3 정적 바이너리를 sha256을 확인하고 받는다.
  - 스토어를 `~/.local/share/cubrid-nix`에 만들고, `/var/tmp/cubrid-nix`를 그곳의 링크로 둔다.
  - `nix.conf`와 `env.sh`를 쓰고, 개발 셸의 경로를 바이너리 캐시에서 받는다.
- 스토어 경로는 누구에게나 `/var/tmp/cubrid-nix/store`라서 우리 바이너리 캐시를 그대로 쓴다. 호스트
  하나에서는 한 사용자만 이 스토어를 가질 수 있다.
- 다시 실행해도 된다. 환경을 다시 검사하고 설정을 다시 쓰며, 스토어는 그대로 둔다.
- 캐시에 없는 경로가 있으면 빌드하지 않고 멈춘다. 소스에서 빌드하면 몇 시간 걸리기 때문이다. 그래도
  빌드하려면 `--build-missing`을 준다.
- git이 없으면 `curl -L https://github.com/xmilex-git/cubrid-nix/archive/main.tar.gz | tar xz`로 받아도
  된다.

`/nix`가 있는 호스트에서는 공식 설치 스크립트로 `/nix`에 설치해도 된다. 그때는 [바이너리
캐시](#바이너리-캐시)의 `/nix/store`용 두 줄을 `nix.conf`에 넣는다.

```bash
curl -fsSL https://nixos.org/nix/install | sh -s -- --no-daemon
. ~/.nix-profile/etc/profile.d/nix.sh
mkdir -p ~/.config/nix /nix/var/cache/ccache
cat >> ~/.config/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
extra-sandbox-paths = /nix/var/cache/ccache
EOF
```

이 레포는 nix 버전에 묶이지 않는다. `flake.lock`이 고정하는 것은 nix 자체가 아니라 nixpkgs, 곧 빌드
도구들이다. `install.sh`의 nix는 설치의 출발점이고, 다른 일에는 다른 nix를 써도 된다.

### 2. CUBRID 소스

```bash
git clone --shallow-since=2019-12-01 https://github.com/CUBRID/cubrid ~/cubrid
git -C ~/cubrid submodule update --init
```

`build.sh`는 2019-12-12 이후의 커밋 수로 버전 번호를 매기므로 그만큼의 이력이 있어야 한다. 서브모듈은
CI처럼 모두 받는다. 다른 브랜치를 빌드하려면 이 체크아웃에서 브랜치를 바꾸고
`submodule update --init`을 다시 한다.

### 3. 빌드

```bash
cd ~/cubrid-nix
make shell-build WORKTREE=~/cubrid          # MODE=release도 된다
I=~/cubrid-nix/.scratch/install/cubrid-optdebug-shell    # 설치본. 아래 단계가 쓴다
```

- `~/cubrid`에서 `build.sh -m optdebug`를 CI 툴체인(gcc 8.5, glibc 2.28)과 ccache로 돌린다.
- 빌드 트리 `~/cubrid/build_x86_64_optdebug`가 남는다. 소스를 고친 뒤 같은 명령을 다시 실행하면 증분
  빌드다. 바이너리 캐시에는 사용자의 소스로 빌드한 것이 없으므로, 소스를 바꾸면 이 명령으로 다시 빌드한다.
- 병렬 작업 수는 cgroup의 CPU quota를 따른다. `CMAKE_BUILD_PARALLEL_LEVEL`로 바꿀 수 있다.
- 설치 위치를 바꾸려면 `PREFIX=~/CUBRID-release`처럼 준다.
- CI와 똑같은 절차로 한 벌을 만들려면 [CI와 같은 빌드](#ci와-같은-빌드)를 본다.

### 4. 서버와 csql

설치본은 건드리지 않는다. 서버는 설치본을 가리키는 실행 디렉터리에서 띄운다.

```bash
env=$(~/cubrid-nix/scripts/rundir.sh "$I" ~/cubrid-run/demo)
. "$env"                      # CUBRID, CUBRID_DATABASES, PATH가 실행 디렉터리를 가리킨다
cd "$CUBRID/tmp"              # csql은 작업 디렉터리에 csql.err를 쓴다
mkdir -p "$CUBRID_DATABASES/demodb"
(cd "$CUBRID_DATABASES/demodb" && cubrid createdb demodb en_US.utf8)
cubrid server start demodb
csql -u dba demodb -c "select 1 + 1"
```

- 끝낼 때는 `cubrid server stop demodb`와 `cubrid service stop`을 실행한다.
- 다른 셸에서 이 실행 디렉터리를 다시 쓰려면 `. ~/cubrid-run/demo/cubrid.env`만 하면 된다.
- 포트는 설치본 기본값(1523)이다. 같은 호스트에 다른 CUBRID가 떠 있으면
  `$CUBRID/conf/cubrid.conf`의 `cubrid_port_id`를 바꾼다.
- 서버, csql, PL/CSQL을 한 번에 확인하려면 `make smoke INSTALL="$I"`를 쓴다.

### 5. CTP

```bash
cd ~/cubrid-nix
make ctp SUITE=sql INSTALL="$I" TC_REF=develop                               # sql 전체: 16샤드, 5분쯤
make ctp SUITE=sql INSTALL="$I" TC_REF=develop ONLY=_01_object/_05_serial    # 일부만
make ctp SUITE=medium INSTALL="$I" TC_REF=develop                            # medium: 샤드 1개, 3분쯤
```

- **테스트케이스:** 첫 실행이 cubrid-testcases를 `.scratch/testcases/cubrid-testcases`로 받는다
  (네트워크가 필요하다). 이미 있는 체크아웃을 쓰려면 경로를 `CUBRID_NIX_TESTCASES=<경로>`로 준다.
- **ref:** 반드시 준다. 브랜치·태그·sha는 `TC_REF=`로 준다. 엔진 PR이면 `PR=<번호>`를 쓴다. 이때
  러너는 tc/pr-<번호> 브랜치를 쓰고, 그 브랜치가 없으면 develop으로 돌리면서 그렇다고 적는다. 엔진이
  develop 최신이 아니면 develop 테스트케이스와 결과가 어긋날 수 있다.
- **그 밖의 옵션:** `ARGS='--shards 4 --no-volatile'`처럼 러너(`ctp/ctp_run.sh --help`)에 그대로 넘긴다.
- **결과:** `.scratch/ctp/<suite>-<시각>/`에 남는다.
  - `failed.list`: 실패한 케이스. `ONLY=`에 그대로 넣을 수 있는 형태다.
  - `provenance.txt`: 설치본, CTP, 테스트케이스 sha.
  - `shard_N/console.log`와 `timing.txt`.
- **격리:** 샤드마다 PID·네트워크·mount 네임스페이스가 따로 있다. 그래서 CTP 정리 단계의 `pkill cub`이
  샤드 밖에 닿지 않는다. DB는 fsync를 하지 않는 volatile overlay에 둔다.
- **네임스페이스가 없으면:** 샤드 하나가 격리 없이 돈다. `pkill cub`이 이 사용자의 모든 CUBRID에 닿으므로,
  이 사용자의 CUBRID 프로세스가 이미 있으면 러너가 시작하지 않는다.
- **로케일 라이브러리:** CTP는 DB를 만들기 전에 로케일 라이브러리를 컴파일한다(43초쯤). 이 단계는
  설치본마다 한 번만 한다. 설치본의 첫 CTP 실행이 라이브러리를 만들어 `~/.cache/cubrid-nix/locale`에
  두고, 모든 샤드와 이후 실행이 그것을 쓴다. 이 디렉터리는 지워도 된다. 지우면 다음 실행이 다시 만든다.

### 6. 셸 케이스 하나

```bash
make shell-case INSTALL="$I" CASE=_01_utility/_17_loaddb/bug_xdbms184 TESTCASES=~/cubrid-testcases-private-ex
```

- CTP 셸 가이드가 케이스 하나를 돌리는 방식(`init_path`를 두고 `<케이스>/cases`에서 `sh <케이스>.sh`)을
  따른다. 스위트 전체를 돌리지는 않는다. shell 스위트는 업스트림 CI가 돌린다.
- 케이스, CTP, 실행 디렉터리를 `.scratch/shell-case/<케이스>-<시각>/`에 복사해 돌린다. 테스트케이스
  체크아웃과 설치본은 바뀌지 않는다.
- 케이스의 `init test`와 `finish`는 `pkill cub`을 하고, 이 사용자의 공유 메모리를 모두 지운다. user
  namespace가 있으면 케이스를 자기 PID·IPC·네트워크 네임스페이스에서 돌린다. 없으면 이 사용자의 CUBRID
  프로세스나 공유 메모리가 있거나 conf의 포트가 쓰이는 동안에는 시작하지 않는다.
- 판정은 `verdict.tsv`에 남는다. PASS는 `<케이스>.result`에 OK가 있고 NOK가 없으며, 끝난 뒤 프로세스,
  공유 메모리, 포트, 등록된 DB가 남지 않았다는 뜻이다.
- cubrid-testcases-private-ex는 비공개 저장소다. 체크아웃은 권한 있는 계정으로 받아 경로를 준다.

### 7. gdb로 코어 보기

```bash
cat /proc/sys/kernel/core_pattern          # 절대 경로여야 한다. 아니면 sudo sysctl kernel.core_pattern=/var/tmp/core.%e.%p
. ~/cubrid-run/demo/cubrid.env
cubrid service stop
ulimit -c unlimited                        # 서버를 띄우는 셸에서
cubrid server start demodb
kill -ABRT "$(pgrep -u "$USER" -x cub_server)"   # 시험용. optdebug 서버는 SIGABRT를 받으면 코어를 남긴다
core=$(ls -t /var/tmp/core.cub_server.* | head -1)   # core_pattern이 가리키는 디렉터리
cd ~/cubrid-nix && nix develop -c scripts/gdb-core.sh "$I" "$core" ~/gdb-out
```

- `gdb-core.sh`는 스레드 목록, 모든 스레드의 backtrace, 죽은 스레드의 지역 변수를 `~/gdb-out`에 쓰고
  판정한다. gdb를 직접 쓰려면 개발 셸에서 `gdb "$I/bin/cub_server" "$core"`를 실행한다.
- gdb에는 설치본의 `bin/cub_server`를 준다. 실행 디렉터리의 것은 셸 래퍼다.
- 개발 셸의 gdb는 CUBRID 스레드를 스냅샷 glibc 2.28의 libthread_db로 읽는다.
- gdb 출력 앞부분의 `/dev/shm/cubbase_dmrb_*` 경고는 이미 지워진 공유 메모리 파일에 대한 것이라 무시해도
  된다.
- optdebug 서버의 코어는 수 GB다(기본 conf에서 4.2GB). 다 본 코어는 지운다.
- 서버가 죽으면 cub_master가 곧바로 다시 띄운다. 끝나면 `cubrid service stop`을 실행한다.
- 컨테이너 안이면 `core_pattern`은 호스트에서 바꾼다.
- **코어 덤프가 막힌 환경:** 커널이 코어를 쓰지 않는다(`ulimit -Hc`가 0이거나 `core_pattern`이 보이지
  않는다). 다른 환경에서 같은 설치본이 만든 코어를 가져와 `gdb-core.sh`로 읽는다. 설치본은 바이너리
  캐시로 받아 바이트까지 같게 한다(`nix build --no-link <설치본의 스토어 경로>`). 빌드 ID가 다르면
  `gdb-core.sh`가 FAIL로 판정한다.
- `make build`로 만든 설치본은 `/build/source`에서 컴파일된다. 소스 줄까지 보려면 `make build`가
  출력하는 내보낸 소스 경로(`~/cubrid-nix/.scratch/src/cubrid`)를 `CUBRID_NIX_SRC`에 둔다.

## CI와 같은 빌드

```bash
cd ~/cubrid-nix
make build WORKTREE=~/cubrid    # MODE=release도 된다
```

- 작업 트리를 소스 배포본처럼 `.scratch/src/cubrid`로 내보낸다. 그다음 CI와 같은
  `build.sh -m optdebug -p <out> build`를 nix에서 네트워크 없이 돌린다.
- 3rdparty 소스, JDK, Gradle과 그 의존성은 빌드 전에 해시로 고정해 넣는다(봉인 입력).
- 결과는 읽기 전용인 nix 스토어에 있고, `.scratch/install/cubrid-optdebug`가 그것을 가리킨다. 같은
  소스와 같은 `flake.lock`이면 어느 머신에서든 같은 스토어 경로가 나온다.
- 3단계의 `$I` 대신 이 경로를 주면 4–7단계가 그대로 된다.

엔진이 번들 JDK나 Gradle을 바꾸면 봉인 목록을 갱신한다. 네트워크가 필요하다.

```bash
make seal WORKTREE=~/cubrid
```

3rdparty 목록은 엔진의 `3rdparty/CMakeLists.txt`에서 읽으므로 따로 할 일이 없다.

## 바이너리 캐시

새 환경이 빌드할 것을 미리 서명해 둔 nix 캐시다([ADR 0002](docs/adr/0002-lan-binary-cache.md)).
캐시는 스토어 경로마다 따로 있다. 공개 키는 모두 같다.

- **사용자 스토어**(`install.sh`): `install.sh`가 알아서 설정한다. GitHub 캐시를 쓰고, 사내 캐시가 3초
  안에 답하면 그것을 먼저 쓴다. 사용자 스토어의 경로는 공개 캐시에 없으므로 두 캐시가 closure 전부를
  담는다.
- **`/nix/store`**(공식 설치): `nix.conf`에 한쪽의 두 줄을 더한다. 사내망이면 사내 캐시를 쓴다.

  ```
  extra-substituters = http://192.168.6.4
  extra-trusted-public-keys = cubrid-nix-cache-1:9tHaV41AhMl1GxTpdkaMjzH+V3/FiXx2F4hto1pcd+U=
  ```

  외부 환경에서는 GitHub 캐시를 쓴다. 공개 캐시에 없는 우리 경로만 담았고, 나머지는 cache.nixos.org에서
  받는다.

  ```
  extra-substituters = https://github.com/xmilex-git/cubrid-nix/releases/download/nix-cache
  extra-trusted-public-keys = cubrid-nix-cache-1:9tHaV41AhMl1GxTpdkaMjzH+V3/FiXx2F4hto1pcd+U=
  ```

- 닿지 않는 캐시는 넣지 않는다. nix가 연결을 기다리느라 느려진다.
- HTTP 프록시를 쓰는 환경에서 사내 캐시를 쓰면 `no_proxy`에 `192.168.6.4`를 더한다.

`flake.nix`, `flake.lock`, `nix/`를 바꾼 뒤에는 스토어마다 `make cache-update`로 캐시를 갱신한다. 자세한
절차는 [캐시 갱신 지침](docs/cache-maintenance.md)에 있다.

## 알려진 한계

- user namespace를 만들 수 없는 환경에서는 세 가지가 달라진다.
  - `nix build`가 샌드박스 없이 돈다(`sandbox = false`). 빌드 디렉터리가 매번 달라서 ccache 적중률이
    낮다.
  - `make shell-build`는 호스트의 `/usr/include/malloc.h`가 더하는 선언이 없을 때만 된다. 엔진 소스 한
    곳이 이 파일을 절대 경로로 include하기 때문이다. 같은 include guard를 가진 glibc나 musl의 파일이면
    된다(ADR 0003 D6). 아니면 `make build`를 쓴다.
  - CTP는 샤드 하나가 격리 없이 돈다.
- 사용자 스토어는 호스트 하나에 한 사용자만 쓴다. `/var/tmp/cubrid-nix`가 다른 사용자의 것이면
  `install.sh`가 멈춘다.
- 사용자 스토어의 캐시가 모자라면 closure를 소스에서 빌드해야 한다. 몇 시간 걸린다.
- nix는 URL마다 한 번씩만 받기를 시도한다. 프록시나 미러의 일시적 오류로 실패하면 다시 실행한다.
  이미 받은 것은 다시 받지 않는다.
- `~/.cache/cubrid-nix/locale`은 저절로 비워지지 않는다. 설치본 하나에 19MB쯤이다.
- 커널 `core_pattern`이 `/home`, `/mnt`, `/tmp` 아래를 가리키면 CTP 샤드의 코어는 모이지 않는다. 샤드가
  그 디렉터리들을 덮기 때문이다.

## 무엇이 CI와 같은가

| 층 | 출처 | 버전 |
|---|---|---|
| 컴파일러, 링커, libc, libstdc++, 커널 헤더, 링크되는 C 라이브러리 | CI 빌드 이미지의 Rocky 8.10 RPM(해시 고정) | gcc 8.5.0-28, binutils 2.30-123, glibc 2.28-251, ncurses 6.1 |
| 코드를 생성하는 도구 | 같은 RPM 묶음 | flex 2.6.1, systemtap-sdt 4.9, iconv(glibc-common) |
| 빌드 도구 | nix, CI와 같은 버전 | cmake 3.26.5, ninja 1.11.1, make 4.2.1, bison 3.0.5, ant 1.10.9, perl 5.26.3, Temurin 8u442-b06, git 2.43.7 |
| 코드 스타일 도구 | nix, CI와 같은 버전 | GNU indent 2.2.11, astyle 3.1, google-java-format 1.7 |
| 시간대·로케일 데이터 | CI 테스트 이미지의 RPM | tzdata 2024a, glibc-langpack-en·ko 2.28 |
| CTP 실행 도구 | nixpkgs 24.11 | 문제가 생기면 CI 테스트 이미지 버전으로 교체 |
| 진단·캐시 | nixpkgs 24.11 | gdb 15.2, ccache 4.10.2 |

## 검증 결과

### 제한 클라우드 흉내 (ADR 0003)

흉내 낸 컨테이너(`cleanroom/restricted`)에서 확인했다. Debian trixie(gcc 14.2, make, Java 21), uid
1000, `/nix` 없음, user namespace 없음, 코어 덤프 없음, CPU 16개다. 메모리 한도는 걸 수 없어서 단계마다
RSS 합의 최대치를 쟀다. 실제 원격 환경에서 확인한 것은 아니다. 조건과 찾은 결함은
[ADR 0003](docs/adr/0003-user-store-without-root.md)의 검증 절에 있다.

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

### `/nix` 경로 (2026-09-30, develop `35f528e89`, 테스트케이스 develop `7bd8ebbc`)

빈 `ubuntu:24.04`에 nix 2.35.2만 설치한 컨테이너에서 확인했다(`cleanroom/run.sh`). 검증 단계는
`--network=none`으로 돌렸다. 이때는 perf가 있었고 레시피는 just였다.

| 항목 | 결과 |
|---|---|
| 콜드 스타트(nix 설치 → 개발 셸 → 소스 → 빌드 입력) | 12–18분(64코어) |
| optdebug / release 빌드 | 184초 / 175초. 스토어 경로는 호스트 빌드와 같다. |
| 한 줄 고친 뒤 재빌드 | 85초(ccache 적중률 98%) |
| 서버, csql, PL/CSQL 스모크 | 통과 |
| CTP sql(16샤드) / medium | 17,463/17,463 (300초) / 975/975 (190초) |
| gdb | 코어에서 파일·줄 |
| 기본 권한 컨테이너(네임스페이스 없음) | 빌드 샌드박스 없이 빌드하고, 직접 샤드 하나가 CTP 82건을 통과 |

설치본별 로케일 라이브러리와 `/home` 아래의 설치본은 호스트(Rocky 8)에서 확인했다. 같은 엔진과
테스트케이스로 돌렸고, `/nix/store` 설치본과 shell-build 설치본이 모두 sql 17,463/17,463과
medium 975/975를 통과했다. 샤드의 로케일 단계는 43초에서 0–1초가 됐고, 43건짜리 부분 실행은 84초에서
44초가 됐다.

closure를 줄인 뒤(ADR 0003) 호스트의 `/nix`에서 다시 확인했다. optdebug 빌드는 260초, 새 체크아웃의
shell-build는 306초였다. 스모크, CTP sql `_01_object/_04_trigger` 82/82, medium 975/975(테스트케이스
develop `f1c9f42a`), 셸 케이스 한 건, 커널 코어의 gdb 판독이 모두 통과했다. 개발 셸 closure는 경로
230개 1.48GiB에서 152개 1.20GiB가 됐다.

## 라이선스

[Apache License 2.0](LICENSE)이다. CUBRID와 같다.
