# cubrid-nix

아무것도 설치되지 않은 x86_64 리눅스에 **nix만 설치하면**, CUBRID CI와 같은 툴체인과 도구 버전으로
엔진 빌드 → 서버 실행 → CTP → perf·gdb 분석까지 할 수 있게 하는 nix flake다. 아래
[따라 하기](#따라-하기)를 위에서부터 그대로 실행하면 된다.

> 결정과 이유는 [ADR 0001](docs/adr/0001-reproduce-ci-environment-with-nix.md), 용어는
> [CONTEXT.md](CONTEXT.md), 들어 있는 패키지와 그 이유는 [근거표](docs/packages.md)에 있다.

## 보장 문구

> x86_64 리눅스 + nix. perf는 커널이 perf 이벤트를 허용해야 하고, CTP 병렬 실행은 user namespace
> 허용이 필요하다(없으면 perf는 빠지고 CTP는 직렬로 돈다). fsync 끄기는 커널 5.11 이상이면
> volatile overlay, 아니면 eatmydata다. 코어는 커널 `core_pattern`이 파일 경로일 때만 러너가 모은다.
> 처음 한 번은 네트워크가 필요하고, 빌드와 실행은 네트워크 없이 돈다. nix 말고는 설치할 것이 없다:
> git을 비롯한 도구는 `nix develop`이 준다.

## 따라 하기

1–3은 새 환경에서 한 번만 한다. 4부터는 `nix develop` 셸 안에서 실행한다.

### 1. nix 설치

배포판에서 받을 것은 nix 설치 스크립트가 쓰는 curl, xz, ca-certificates뿐이다. `/nix`가 없으면 설치
스크립트가 sudo로 한 번 만든다.

```bash
curl -fsSL https://releases.nixos.org/nix/nix-2.35.2/install | sh -s -- --no-daemon
. ~/.nix-profile/etc/profile.d/nix.sh
mkdir -p ~/.config/nix /nix/var/cache/ccache
cat >> ~/.config/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
extra-sandbox-paths = /nix/var/cache/ccache
EOF
```

`extra-sandbox-paths`는 `nix build`의 샌드박스가 ccache를 쓰게 한다. user namespace를 만들 수 없는
환경(권한 없는 컨테이너 등)이면 `sandbox = false`도 한 줄 더 둔다.

### 2. 이 레포와 개발 셸

```bash
nix run nixpkgs#git -- clone https://github.com/xmilex-git/cubrid-nix ~/cubrid-nix
cd ~/cubrid-nix
nix develop
```

첫 `nix develop`은 12–18분 걸린다(64코어). 공개 캐시에 없는 CI 버전 도구(perl, git, bison, indent,
astyle)를 소스에서 빌드하기 때문이다. 두 번째부터는 바로 뜬다. git, just, gdb, perf를 비롯해 아래
단계에 필요한 도구는 모두 이 셸에 있다.

### 3. CUBRID 소스

```bash
git clone --shallow-since=2019-12-01 https://github.com/CUBRID/cubrid ~/cubrid
git -C ~/cubrid submodule update --init
```

`build.sh`는 2019-12-12 이후의 커밋 수로 버전 번호를 매기므로 그만큼의 이력이 있어야 한다. 서브모듈은
CI처럼 모두 받는다. 다른 브랜치를 빌드하려면 이 체크아웃에서 브랜치를 바꾸고
`submodule update --init`을 다시 한다.

### 4. 빌드

```bash
cd ~/cubrid-nix
just shell-build ~/cubrid optdebug
I=~/cubrid-nix/.scratch/install/cubrid-optdebug-shell    # 설치본. 아래 단계가 쓴다
```

`~/cubrid`에서 `build.sh -m optdebug`를 CI 툴체인(gcc 8.5, glibc 2.28)과 ccache로 돌린다. 빌드 트리
`~/cubrid/build_x86_64_optdebug`가 남으므로, 소스를 고친 뒤 같은 명령을 다시 실행하면 증분 빌드다.
처음에는 3분쯤, 한 줄 고친 뒤에는 1분 남짓 걸린다(64코어). `release`도 되고, 세 번째 인자로 설치
위치를 정할 수 있다(`just shell-build ~/cubrid release ~/CUBRID-release`).

CI와 똑같은 절차로 한 벌을 만들려면 [CI와 같은 빌드](#ci와-같은-빌드)를 본다.

### 5. 서버와 csql

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
- 서버, csql, PL/CSQL을 한 번에 확인하려면 `just smoke "$I"`를 쓴다.

### 6. CTP

```bash
cd ~/cubrid-nix
just ctp sql "$I" --tc-ref develop                               # sql 전체: 16샤드, 5분쯤
just ctp sql "$I" --tc-ref develop --only _01_object/_05_serial  # 일부만
just ctp medium "$I" --tc-ref develop                            # medium: 샤드 1개, 3분쯤
```

- **테스트케이스:** 첫 실행이 cubrid-testcases를 `.scratch/testcases/cubrid-testcases`로 받는다
  (네트워크가 필요하다). 이미 있는 체크아웃을 쓰려면 경로를 `CUBRID_NIX_TESTCASES=<경로>`로 준다.
- **ref:** 반드시 준다. 브랜치·태그·sha는 `--tc-ref`로 준다. 엔진 PR이면 `--pr <번호>`를 쓴다. 이때
  러너는 tc/pr-<번호> 브랜치를 쓰고, 그 브랜치가 없으면 develop으로 돌리면서 그렇다고 적는다. 엔진이
  develop 최신이 아니면 develop 테스트케이스와 결과가 어긋날 수 있다.
- **결과:** `.scratch/ctp/<suite>-<시각>/`에 남는다.
  - `failed.list`: 실패한 케이스. `--only`에 그대로 넣을 수 있는 형태다.
  - `provenance.txt`: 설치본, CTP, 테스트케이스 sha.
  - `shard_N/console.log`와 `timing.txt`.
- **격리:** 샤드마다 PID·네트워크·mount 네임스페이스가 따로 있다. 그래서 CTP 정리 단계의 `pkill cub`이
  샤드 밖에 닿지 않는다. DB는 fsync를 하지 않는 volatile overlay에 둔다. user namespace가 없으면 샤드
  하나가 격리 없이 돈다. 그때는 이 사용자의 다른 CUBRID가 없는 전용 환경에서만 쓴다.
- **로케일 라이브러리:** CTP는 DB를 만들기 전에 로케일 라이브러리를 컴파일한다(43초쯤). 이 단계는
  설치본마다 한 번만 한다. 설치본의 첫 CTP 실행이 라이브러리를 만들어 `~/.cache/cubrid-nix/locale`에
  두고, 모든 샤드와 이후 실행이 그것을 쓴다. 이 디렉터리는 지워도 된다. 지우면 다음 실행이 다시 만든다.

### 7. perf

```bash
cat /proc/sys/kernel/perf_event_paranoid   # 2 이하여야 한다. 아니면 sudo sysctl kernel.perf_event_paranoid=2
. ~/cubrid-run/demo/cubrid.env
cubrid server start demodb                 # 5단계의 서버가 떠 있으면 건너뛴다. 부하는 다른 셸에서 csql로 준다
perf record -e cycles:u --call-graph fp -p "$(pgrep -u "$USER" -x cub_server)" -o ~/perf.data -- sleep 10
perf report -i ~/perf.data --no-children --sort dso,symbol
```

CUBRID는 심볼을 지우지 않고 프레임 포인터를 남기도록(`-fno-omit-frame-pointer`) 빌드된다. 그래서 함수
이름과 호출 체인이 나온다.

### 8. gdb로 코어 보기

```bash
cat /proc/sys/kernel/core_pattern          # 절대 경로여야 한다. 아니면 sudo sysctl kernel.core_pattern=/var/tmp/core.%e.%p
. ~/cubrid-run/demo/cubrid.env
cubrid service stop
ulimit -c unlimited                        # 서버를 띄우는 셸에서
cubrid server start demodb
kill -ABRT "$(pgrep -u "$USER" -x cub_server)"   # 시험용. optdebug 서버는 SIGABRT를 받으면 코어를 남긴다
core=$(ls -t /var/tmp/core.cub_server.* | head -1)   # core_pattern이 가리키는 디렉터리
gdb -batch -ex 'thread apply all bt 8' "$I/bin/cub_server" "$core"
```

- gdb에는 설치본의 `bin/cub_server`를 준다. 실행 디렉터리의 것은 셸 래퍼다.
- 개발 셸의 gdb는 CUBRID 스레드를 스냅샷 glibc 2.28의 libthread_db로 읽는다.
- gdb 출력 앞부분의 `/dev/shm/cubbase_dmrb_*` 경고는 이미 지워진 공유 메모리 파일에 대한 것이라 무시해도
  된다.
- optdebug 서버의 코어는 수 GB다(기본 conf에서 4.2GB). 다 본 코어는 지운다.
- 서버가 죽으면 cub_master가 곧바로 다시 띄운다. 끝나면 `cubrid service stop`을 실행한다.
- 컨테이너 안이면 `core_pattern`은 호스트에서 바꾼다.
- `just build`로 만든 설치본은 `/build/source`에서 컴파일된다. 소스 줄까지 보려면 `just build`가
  출력하는 내보낸 소스 경로(`~/cubrid-nix/.scratch/src/cubrid`)를 `CUBRID_NIX_SRC`에 둔다.

## CI와 같은 빌드

```bash
cd ~/cubrid-nix
just build ~/cubrid optdebug    # release도 된다
```

- 작업 트리를 소스 배포본처럼 `.scratch/src/cubrid`로 내보낸다. 그다음 CI와 같은
  `build.sh -m optdebug -p <out> build`를 nix 샌드박스에서 네트워크 없이 돌린다.
- 3rdparty 소스, JDK, Gradle과 그 의존성은 빌드 전에 해시로 고정해 넣는다(봉인 입력).
- 결과는 읽기 전용인 `/nix/store`에 있고, `.scratch/install/cubrid-optdebug`가 그것을 가리킨다. 같은
  소스와 같은 `flake.lock`이면 어느 머신에서든 같은 스토어 경로가 나온다.
- 4단계의 `$I` 대신 이 경로를 주면 5–8단계가 그대로 된다.

엔진이 번들 JDK나 Gradle을 바꾸면 봉인 목록을 갱신한다. 네트워크가 필요하다.

```bash
just seal ~/cubrid
```

3rdparty 목록은 엔진의 `3rdparty/CMakeLists.txt`에서 읽으므로 따로 할 일이 없다.

## 알려진 한계

- user namespace를 만들 수 없는 환경에서는 세 가지가 달라진다.
  - `nix build`가 샌드박스 없이 돈다(`sandbox = false`). 빌드 디렉터리가 매번 달라서 ccache 적중률이
    45% 정도다.
  - `just shell-build`는 호스트의 `/usr/include/malloc.h`가 CI의 것(glibc 2.28)과 같을 때만 된다. 엔진
    소스 한 곳이 이 파일을 절대 경로로 include하기 때문이다. 다르면 `just build`를 쓴다.
  - CTP는 샤드 하나가 격리 없이 돈다.
- 첫 `nix develop`은 12–18분이다. CI 버전 도구를 받아 올 바이너리 캐시가 없어서 소스에서 빌드한다.
- nix는 URL마다 한 번씩만 받기를 시도한다. 프록시나 미러의 일시적 오류로 실패하면 `nix develop`을 다시
  실행한다. 이미 받은 것은 다시 받지 않는다.
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
| 진단·캐시 | nixpkgs 24.11 | gdb 15.2, perf 6.6, ccache 4.10.2 |

## 검증 결과 (2026-09-30, develop `35f528e89`, 테스트케이스 develop `7bd8ebbc`)

빈 `ubuntu:24.04`에 nix 2.35.2만 설치한 컨테이너에서 확인했다(`cleanroom/run.sh`). 검증 단계는
`--network=none`으로 돌렸다.

| 항목 | 결과 |
|---|---|
| 콜드 스타트(nix 설치 → 개발 셸 → 소스 → 빌드 입력) | 12–18분(64코어) |
| optdebug / release 빌드 | 184초 / 175초. 스토어 경로는 호스트 빌드와 같다. |
| 한 줄 고친 뒤 재빌드 | 85초(ccache 적중률 98%) |
| 서버, csql, PL/CSQL 스모크 | 통과 |
| CTP sql(16샤드) / medium | 17,463/17,463 (300초) / 975/975 (190초) |
| perf / gdb | CUBRID 함수 이름 / 코어에서 파일·줄 |
| 기본 권한 컨테이너(네임스페이스 없음) | 빌드 샌드박스 없이 빌드하고, 직접 샤드 하나가 CTP 82건을 통과 |

설치본별 로케일 라이브러리와 `/home` 아래의 설치본은 호스트(Rocky 8)에서 확인했다. 같은 엔진과
테스트케이스로 돌렸고, `/nix/store` 설치본과 `just shell-build` 설치본이 모두 sql 17,463/17,463과
medium 975/975를 통과했다. 샤드의 로케일 단계는 43초에서 0–1초가 됐고, 43건짜리 부분 실행은 84초에서
44초가 됐다.

## 라이선스

[Apache License 2.0](LICENSE)이다. CUBRID와 같다.
