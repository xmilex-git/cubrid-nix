---
status: accepted
date: 2026-09-30
origin: xmilex-git/workspace 그릴링 세션 (2026-09-30)
---

# CUBRID CI의 빌드·테스트 환경을 nix로 재현한다

클라우드 같은 새 환경에서 CUBRID를 빌드하고 CTP를 돌리려면 지금은 배포판마다 다른 패키지를 손으로
맞춰야 한다. 그 결과가 CI와 같다는 보장도 없다. 이 레포는 **아무것도 설치되지 않은 x86_64 리눅스에
nix만 설치하면** 엔진 빌드 → 서버 실행 → CTP → perf·gdb 분석이 CI와 같은 툴체인과 도구 버전으로
되게 한다. "이것만 이 버전대로 깔면 돈다"를 `flake.lock`, RPM 해시, 봉인 입력 목록으로 표현한다.

workspace 호스트의 기존 흐름(`just build`, podman 기반 `just ctp`)은 그대로 둔다. 이 레포는
그것을 대체하지 않는 추가 경로다.

## D1 — 목적과 대상

- **결정:** 대상은 x86_64 glibc 리눅스 전반(VM, 컨테이너, WSL2, podman machine)이다. CUBRID는
  리눅스에서 `-DI386 -DX86`을 고정으로 정의하므로 x86_64만 본다. musl 기반(Alpine)은 제외한다.
- **이유:** 클라우드 작업 환경을 매번 새로 세팅하지 않고, 어디서나 같은 판정을 내기 위해서다.

## D2 — 보장 범위

- **포함:** optdebug·release 빌드, 서버 기동과 csql 질의, PL/CSQL 호출(cub_pl과 JVM 기동 확인),
  CTP sql 전체와 medium(공개 `cubrid-testcases`), gdb와 perf.
- **제외:** shell, ha_shell, 비공개 테스트케이스 리포.
- **이유:** shell은 로컬에서도 전체를 돌리지 않는 스위트다. ha_shell은 노드 두 개와 ssh가 필요하다.
  비공개 리포는 인증이 필요하다.

## D3 — 형태: flake, derivation 빌드, 개발 셸

- **결정:** `flake.nix`와 `flake.lock`으로 정의한다. CUBRID는 `nix build`(derivation)로 빌드한다.
  같은 정의에서 나오는 `nix develop` 셸에서 워크트리를 증분 빌드한다. 서버는 쓰기 가능한
  실행 디렉터리에서 돈다(`/nix/store`의 설치본은 읽기 전용이다).
- **고려한 것:**
  - `nix profile install` 묶음: 실행 파일을 PATH에 올릴 뿐, C 헤더·라이브러리·rpath가 컴파일러에
    연결되지 않는다. 빌드가 실패하거나 배포판 라이브러리를 몰래 집는다.
  - 입력만 봉인하고 빌드는 기존 경로(`just build`)로 하는 방식: 증분 빌드가 자연스럽지만, 클라우드
    재현성을 위해 빌드 자체를 nix가 맡는 쪽을 택했다. 증분 빌드는 개발 셸로 보완한다.
- **대가:** 소스가 바뀌면 `nix build`는 처음부터 다시 빌드한다. ccache(D5)로 완화한다.

## D4 — CI 툴체인 스냅샷: Rocky 8.10 RPM을 nix로 감싼다

- **결정:** CI 빌드 이미지(`cubridci/cubridci:build_rl8.10`,
  `sha256:f8ff31b3a5d7432cbf0f6e36ac82688f0cce0c961bbfc191ac2dc01612a8a887`, 2026-09-10)의 RPM 가운데
  **제품에 닿는 것**을 내용 해시로 고정해 nix로 감싼다. CUBRID가 실행될 때의 glibc도 이 2.28이다.
  - 컴파일러·링커: gcc, gcc-c++, cpp 8.5.0-28.el8_10, binutils 2.30-123.el8
  - libc와 헤더: glibc, glibc-devel, glibc-headers 2.28-251.el8_10.40, kernel-headers 4.18.0-553.159.1.el8_10
  - 런타임 라이브러리: libgcc, libstdc++(-devel, -static), libgomp, libxcrypt, ncurses 6.1
  - cc1의 의존: libmpc, mpfr, gmp, isl, zlib
  - 코드를 생성하는 도구: flex 2.6.1-9.el8(+ m4), systemtap-sdt-devel 4.9-3.el8(`dtrace`, `sys/sdt.h`),
    glibc-common(메시지 카탈로그 변환에 쓰는 `iconv`)
- **이유:** CI와 **같은 환경을 재현하는 것**이 목적이다. 2026-09-30 프로브에서 확인했다.
  - 23개 RPM이 Rocky 8.10 공식 저장소에 그대로 있고 해시와 서명이 맞는다.
  - 빈 `ubuntu:24.04` 컨테이너에서 이 툴체인이 C와 C++17을 `-Wall -Werror`로 빌드했고, 결과가
    glibc 2.28로 실행됐다. Ubuntu의 gcc, binutils, glibc는 쓰이지 않았다.
  - CI 이미지 안에서 직접 빌드한 결과와 기계어와 데이터가 같다. 다른 것은 경로 문자열과 build-id뿐이다.
- **손질 네 가지:**
  1. RPM은 `bin`, `sbin`, `lib`, `lib64` 링크를 filesystem 패키지에 맡긴다. 이 링크를 만들어야
     로더(`lib64/ld-linux-x86-64.so.2`)가 보인다.
  2. `usr/bin/ld`는 binutils의 설치 스크립트(alternatives)가 만드는 파일이라 RPM에 없다.
     `ld → ld.bfd`를 만든다. CI 이미지와 같은 결과다.
  3. 실행 파일의 라이브러리 경로는 DT_RPATH(`--force-rpath`)로 넣는다. DT_RUNPATH는 간접 의존을
     덮지 않아 호스트의 `libz`, `libdl` 등을 집는다. RPATH로 넣으면 그런 경우가 0건이다.
  4. 컴파일러 래퍼가 `--sysroot`와 `-B`(as, ld 위치)를 항상 붙인다. iconv는 `GCONV_PATH`가 필요하다.
- **고려한 것:**
  - nixpkgs 24.11 툴체인(gcc 8.5.0 원본, binutils 2.43.1, glibc 2.40): 버전은 고정되지만 CI와 같은 건
    gcc 버전뿐이다. nixpkgs는 glibc 2.28을 낸 적이 없다(19.09까지 2.27, 20.03부터 2.30).
  - glibc 2.28로 nix 툴체인 전체를 소스에서 다시 빌드: 비용과 깨질 위험이 크다.
- **대가:** 공개 nix 캐시가 없어 처음 한 번은 받아서 만든다. Rocky 저장소에 RPM 파일이 있어야 한다.
  다운로드 주소는 지금 위치(`pub/rocky/8.10`)와 나중에 옮겨 갈 위치(`vault/rocky/8.10`)를 둘 다 적는다.
- **갱신:** CI 빌드 이미지의 digest가 바뀌면, 그 이미지의 `rpm -qa`와 목록을 비교해 갱신하는
  레시피를 쓴다. 갱신은 의도해서만 한다.
- **되돌리기:** 래퍼만 nixpkgs `gcc8Stdenv`로 바꾸면 nixpkgs 툴체인으로 후퇴한다.

## D5 — 빌드 도구: CI와 같은 버전

- **결정:** 제품 코드를 만들지 않는 빌드 도구는 nix가 CI와 같은 버전으로 공급한다.
  - cmake 3.26.5, ninja 1.11.1, make 4.2.1, bison 3.0.5(CI도 소스에서 빌드한다), ant 1.10.9,
    perl 5.26.3, git 2.43.7
  - JDK: Temurin 8u442-b06(CI의 `/opt/jdk8`, `JAVA_HOME`)
  - 코드 스타일: GNU indent 2.2.11(2.2.12는 결과가 달라 CI가 고정), astyle 3.1, google-java-format 1.7
- **ccache 4.10.2:** 결과물에 영향을 주지 않는 캐시라 nixpkgs 버전을 쓴다. CI처럼
  `CC="ccache gcc"`, `CXX="ccache g++"`로 셸과 `nix build` 모두에 적용한다. `nix build`에는 nix 설정의
  `extra-sandbox-paths`로 캐시 디렉터리 하나만 연다. `/nix/store`의 컴파일러는 파일 시각이 모두
  같으므로 `compiler_check=content`로 둔다.
- **hardening:** RPM 툴체인은 nixpkgs의 컴파일러 래퍼를 거치지 않으므로 nixpkgs가 기본으로 넣는
  hardening 플래그(`_FORTIFY_SOURCE` 등)가 붙지 않는다. CI와 같은 플래그로 빌드된다.
- **고려한 것:** 빌드 도구도 CI 이미지의 RPM을 그대로 쓰는 것. 바이너리까지 같지만 perl 하나만 해도
  RPM이 수십 개로 나뉘어 딸려 온다. 빌드 결과를 정하는 것은 컴파일러, 링커, libc, 코드 생성기다(D4).

## D6 — 빌드 절차: CI처럼 `build.sh`

- **결정:** `nix build`와 셸 모두 CI와 같이 `build.sh -m optdebug|release`로 빌드한다. CI는
  `/entrypoint.sh build -m optdebug`, 즉 `./build.sh -p $CUBRID -m optdebug clean build`를 쓴다.
- **버전 번호:** `build.sh`와 CMake는 `.git`에서 2019-12-12 이후 커밋 수와 7자리 해시를 읽는다.
  nix 샌드박스에는 `.git`이 없고, nix가 주는 전체 커밋 수(`revCount`)는 이 규칙과 다르다.
  그래서 래퍼 레시피가 워크트리에서 git으로 계산해 넘기고, 빌드 전에 `VERSION`을
  `11.5.0.<커밋 수>-<해시>`로 채운다. `build.sh`와 CMake 모두 `VERSION`의 네 번째 필드를 먼저 쓴다.
  값이 없으면 `build.sh`처럼 `0000-unknown`이 되고 경고한다.
- **빌드 대상:** 기본은 `flake.lock`에 고정된 develop이다. 워크트리 경로를 주면 그 워크트리를 빌드한다
  (`--override-input`, 커밋하지 않은 수정 포함, git이 추적하지 않는 파일 제외).

## D7 — 봉인 입력

- **결정:** 빌드 **도중에** 네트워크에서 받던 것만 봉인한다. 봉인된 빌드는 네트워크 없이 끝난다.
  - 3rdparty 8종(expat, libedit, rapidjson, openssl, unixODBC, TBB, RE2, LZ4)은 엔진 소스의
    `3rdparty/CMakeLists.txt`에 URL과 SHA256이 있다. nix가 빌드하는 소스에서 바로 읽으므로 develop이
    버전을 올려도 따라간다. 빌드 트리의 `3rdparty/Download/<대상>/`에 넣어 두면 CMake가 해시를 보고
    다운로드를 생략한다(엔진 수정 없음).
  - 해시가 소스에 없는 것 — Temurin JDK(`vm/jdk8.tar.gz`), Gradle 배포본, pl_server의 Gradle 의존성 —
    은 누적 목록과 갱신 레시피로 관리한다. 목록에 없으면 빌드가 네트워크로 몰래 받지 않고 곧바로
    실패하며 갱신 레시피를 안내한다. 내용 해시로 구분되므로 여러 버전이 공존해도 된다.
- **경계:** git 커밋으로 고정되는 트리(엔진, 서브모듈 cci·jdbc, CTP, 테스트케이스)는 봉인 대상이
  아니다. 체크아웃 단계에서만 네트워크를 쓴다.

## D8 — CTP: nix 환경 안에서, `unshare` 샤드로

- **결정:** CTP는 nix 환경 안에서 직접 돌린다. 러너는 workspace의 `ctp_run.sh`를 통째로 옮기고
  실행 계층만 바꾼다.
  - **격리:** 샤드마다 `unshare -Urmipnf --mount-proc`로 PID·net·mount·IPC 네임스페이스를 따로
    둔다. CTP teardown의 `pkill cub`, `kill -9`가 샤드 밖에 닿지 않는다. 샤드마다 `/etc/hosts`와
    `/dev/shm`을 사본으로 붙인다(workspace fast-gate가 겪고 고친 두 문제: netns 안의 호스트 이름 해석,
    PID 네임스페이스 간 DMRB shm 이름 충돌).
  - **fsync:** DB는 volatile overlay(`volatile,userxattr`)에 둔다. 커널 5.11 미만이거나 user
    namespace가 없으면 eatmydata(LD_PRELOAD)로 fsync를 끈다.
  - **그대로 옮기는 것:** 분할, 가중치, 배치 고정(16샤드), colocate, 제외 목록, hang 감시, 출처 기록,
    시간 기록, 엔진 기본값 파라미터 고정. 메모리나 pid가 모자라면 샤드를 줄이고 LPT로 배치한다.
    user namespace가 없으면 직렬로 돈다.
  - **CTP 리비전:** `flake.lock`에 CTP(cubrid-testtools) 커밋을 고정한다. CI 이미지는 실행할 때마다
    develop 최신을 받는다. 테스트케이스 ref는 실행마다 명시한다(PR 또는 TC_REF).
  - **CTP 실행 도구:** nixpkgs 24.11 버전을 쓴다. CTP는 CUBRID 출력과 정답 파일을 비교하므로 셸 도구
    버전이 결과에 닿는 경우는 드물다. 문제가 생기면 그 도구만 CI 테스트 이미지 버전으로 바꾼다.
- **고려한 것:**
  - workspace의 `just ctp`(cubridci 이미지 + `/nix/store` 마운트): CI와 같은 CTP 실행 환경을 주지만
    podman이 필요하고, CTP를 nix 환경 안에서 돌린다는 선택과 어긋난다.
  - nix로 설치한 podman의 중첩: nix는 setuid `newuidmap`을 줄 수 없어 uid 하나만 매핑하는 모드나
    root로 돌아야 하고, 이미지 저장소·네트워크·cgroup 설정이 더 붙는다. CTP 격리에 필요한 것은
    PID·net·mount 네임스페이스뿐이다.

## D9 — 시간대·로케일 데이터

- **결정:** CI 테스트 이미지의 tzdata 2024a-1.el8과 glibc-langpack-en·ko(2.28-251.el8_10.40)를 RPM으로
  고정하고, 서버와 CTP 샤드가 `TZDIR`, `LOCPATH`로 보게 한다. 로케일 파일은 glibc 버전마다 형식이
  달라서 런타임 glibc 2.28과 같은 버전이어야 한다.
- **이유:** CI는 `TZ=Asia/Seoul`, `LANG=en_US.UTF-8`로 CTP를 돌린다. 빈 `ubuntu:24.04`에는
  `/usr/share/zoneinfo`가 없고 로케일은 C/C.utf8/POSIX뿐이다. 그 상태에서 glibc는 `TZ=Asia/Seoul`을
  경고 없이 UTC로 다룬다.

## D10 — 진단 도구와 심볼

- **결정:** gdb 15.2와 perf 6.6.94(nixpkgs 24.11)를 넣는다. 진단 도구라 CI와 같을 필요가 없다.
- **심볼:** nix는 기본으로 결과물의 디버그 정보를 지운다(strip). CUBRID derivation은 이를 끈다
  (`dontStrip`). CUBRID는 CI와 같은 `-ggdb`/`-ggdb3`, `-fno-omit-frame-pointer`로 빌드되므로
  함수 이름, 파일·줄, 프레임 포인터가 그대로 남는다. RPM의 glibc·libstdc++는 배포판처럼 strip돼 있다.
- **권한:** rootless 컨테이너에서 gdb는 추가 플래그 없이 코어를 읽는다. perf는 `perf_event_open`이
  허용돼야 한다(기본 seccomp에 그 호출 하나를 더한 프로필이면 된다). `perf_event_paranoid=2`에서는
  사용자 공간 이벤트만 잰다.
- **유지하는 규칙:** 라이브 서버 gdb attach 금지. 코어 판독만 한다.
- **시스템 라이브러리 debuginfo는 넣지 않는다 (사용자 결정 2026-09-30).** Rocky 8.10의 glibc·libstdc++
  debuginfo RPM(합 7 MB)을 넣으면 glibc 내부 함수의 줄 번호까지 보이지만, 필요 없다고 정했다. CI처럼
  glibc 프레임은 함수 이름만 보인다.

## D11 — 보장 문구

> x86_64 리눅스 + nix. perf는 커널이 perf 이벤트를 허용해야 하고, CTP 병렬 실행은 user namespace
> 허용이 필요하다(없으면 perf는 빠지고 CTP는 직렬로 돈다). fsync 끄기는 커널 5.11 이상이면
> volatile overlay, 아니면 eatmydata다. 코어는 커널 `core_pattern`이 파일 경로일 때만 러너가 모은다.
> 처음 한 번은 네트워크가 필요하고, 빌드와 실행은 네트워크 없이 돈다.

## D12 — 클린룸 검증

- **결정:** `ubuntu:24.04` 컨테이너에 최신 안정판 nix만 설치해 검증한다(P8 당시 2.35.2). nix 설치에 필요한 curl, xz,
  ca-certificates만 배포판에서 받는다.
  - 네트워크는 받을 때만 켜고(nix, 봉인 입력, RPM, 엔진·CTP·테스트케이스 체크아웃), 빌드와 실행은
    `--network=none`으로 한다. 봉인이 실제로 지켜지는지 이것으로 증명한다.
  - 두 번 돌린다. 권한 있는 컨테이너(user namespace, perf 허용)에서 전부 확인하고, 기본 권한
    컨테이너에서 권한 없이 되어야 하는 것(빌드, 서버, CTP 일부 직렬)을 확인한다.
- **통과 기준:** optdebug·release 빌드 성공, 서버·csql·PL/CSQL 성공, 같은 엔진·테스트케이스
  리비전에서 CTP sql·medium 통과 수가 CI 기준과 같음, perf 보고서에 CUBRID 함수 이름, gdb 코어
  backtrace에 파일·줄.
- **측정:** 콜드 스타트 시간과 ccache가 있을 때의 재빌드 시간. 콜드 스타트가 1시간을 넘으면 바이너리
  캐시 도입을 다시 논의한다.
- **바뀐 것 (2026-09-30):** 1시간을 넘지 않았지만, 사용자가 사내망 바이너리 캐시를 두기로 했다. 밖에서
  받는 것도 느리기 때문이다. [ADR 0002](0002-lan-binary-cache.md)를 본다.
- **바뀐 것 (2026-09-30):** nix 버전은 고정하지 않는다(사용자 결정).
  - `flake.lock`이 고정하는 것은 nixpkgs다. nix 버전이 달라도 derivation 경로는 같으므로, 사내 캐시도
    그대로 맞는다.
  - README와 클린룸은 기본으로 최신 안정판을 설치한다. 클린룸은 `CLEANROOM_NIX_VERSION`을 주면 그 버전으로
    다시 돈다.

## D13 — 최소성

패키지마다 "빠지면 무엇이 어떻게 실패하는지"를 근거표로 남기고 closure 크기를 기록한다. 극단적인
경량화는 하지 않는다. 일부러 많이 설치하지 않는다는 뜻이다.

## D14 — 기록

이 ADR과 `CONTEXT.md`가 결정과 용어의 원본이다. workspace의 `CONTEXT.md`에는 이 레포를 가리키는
포인터만 둔다. workspace 용어집의 **샤드**는 "컨테이너 1개"와 1:1이지만, 이 레포에서는 "격리 단위
(`unshare` 네임스페이스) 1개"와 1:1이다.

## 구현 메모 (2026-09-30, P1–P4 게이트)

결정은 그대로이고, 구현하며 확인한 사실만 적는다.

- **D4 스냅샷의 RPM은 30개다.** 처음 목록에 CI 빌드 이미지에 있는 두 개를 더했다.
  - `glibc-gconv-extra`: 메시지 카탈로그를 EUC-KR로 바꾸는 `iconv`가 쓴다.
  - `elfutils-libelf-devel`: `src/base/dynamic_load.h`가 `nlist.h`를 쓴다.
  - 두 파일 모두 CI 이미지의 것과 헤더 SHA256이 같다.
- **D6 빌드는 소스 사본만 고친다.** 엔진 저장소는 건드리지 않는다.
  - `VERSION-DIST` 세 개를 쓴다. 기본 flake 입력일 때는 `build.sh`처럼 `0000-unknown`이다.
  - `src/heaplayers/malloc_2_8_3.c`의 `#include "/usr/include/malloc.h"`를 `<malloc.h>`로 바꾼다. 같은 glibc 2.28 헤더가 `--sysroot`를 통해 들어온다.
  - 샌드박스에는 `/usr/bin/env`가 없어서, 빌드 중에 풀리는 OpenSSL `Configure` 등의 shebang을 위해 링크를 만든다.
- **D6 JNI 헤더는 Temurin 8u442의 것이다.** 엔진 CMake는 configure 시점에 아직 풀리지 않은 빌드 트리의 JDK를 가리킨다. 그래서 시드가 봉인된 JDK를 미리 풀어 둔다. CI에서는 FindJNI가 시스템 OpenJDK 8u504의 헤더를 찾는데, JDK 8의 JNI 헤더는 업데이트 사이에 바뀌지 않는다.
- **D7 봉인 목록의 Maven 파일은 71개다.** Maven Central에서 67개, Gradle 플러그인 포털에서 foojay 플러그인 4개다. 자동 탐지를 끈 Gradle이 JDK를 찾도록 `org.gradle.java.installations.fromEnv=JAVA_HOME`을 둔다.
- **D5 perl 5.26.3은 소스에서 세 군데를 손봤다.** Configure가 gcc 13을 gcc 1로 오인해 `-fno-strict-aliasing`를 빼는 버그, `errno.h` 경로, 샌드박스에 없는 `/bin/pwd`다. CI의 perl은 gcc 8로 빌드돼 첫 번째 버그를 밟지 않는다.
- **결과(develop `35f528e89`, 64코어):**
  - optdebug는 169초, release는 164초에 빌드된다. release는 `-Werror`로 통과하며 `src/`의 경고는 0건이다.
  - CUBRID의 ELF 37개가 모두 스냅샷 로더와 RPATH를 쓰고, RUNPATH는 0건이다. `vm/jdk8` 아래 94개는
    Temurin tarball의 파일 그대로다(CI 설치본과 같다: `install(DIRECTORY)`가 실행 비트를 떨어뜨려
    아무도 실행하지 않고, cub_pl이 `libjvm.so`를 프로세스 안에 올린다).
  - `cub_manager`가 포함된다(CI처럼 서브모듈 전부).
  - `cubrid_rel`은 `11.5.0.2629-35f528e`다.
- **D10 심볼(host 설치본, 같은 gcc 8.5.0-28):**
  - perf 6.6은 CUBRID 함수를 이름과 인라인 프레임까지 보여 준다. 프레임 포인터 호출 체인도 된다.
  - gdb 15.2는 코어에서 파일·줄·인자를 보여 준다.
  - perf의 addr2line 기본 제한 시간은 180 MB짜리 라이브러리에 짧아서 60초로 둔다.
  - `nix build` 결과물의 소스 경로는 `/build/source`이므로 gdb에 `substitute-path`가 필요하다.

## 구현 메모 (2026-09-30, P5–P7 게이트)

- **CTP(D8):** develop `35f528e89`의 optdebug 설치본으로 테스트케이스 develop `7bd8ebbc`를 돌렸다.
  - sql은 16샤드로 17,463건 모두 통과했다(301초).
  - medium은 975건 모두 통과했다(189초).
  - 코어와 hang은 0건이었다.
  - 이 엔진 커밋의 CI 테스트는 아직 없다. 바로 앞 커밋 `f1bd99ed4`의 nightly는 sql 17,471건(dirsplit
    제외 8건 포함)과 medium 975건을 모두 통과했고, 건수가 같다.
- **러너가 겪은 것:**
  - 샤드들이 같은 포트를 쓰므로 master 소켓 기본값 `/tmp/CUBRID<port>`가 샤드 사이에 겹친다. 그래서
    샤드마다 `CUBRID_TMP=$CUBRID/var/CUBRID_SOCK`을 둔다.
  - 샤드는 빈 환경(`exec -c`)에서 시작해 `shard.env`만 받는다. 호출한 쪽의 `CUBRID_TMP`,
    `LD_LIBRARY_PATH`, 자격 증명 변수가 새어 들지 않는다.
  - 샤드는 디스크 위에 자기 `/tmp`를 갖는다.
  - `/home`에 tmpfs를 올리면 `/home` 아래에 있던 샤드 경로가 가려진다. 그래서 로그는 파일 디스크립터로
    먼저 열어 둔다.
- **스모크(D2):** optdebug와 release 모두 서버, csql, PL/CSQL(JVM이 42를 돌려준다)을 통과했다. 떠 있는
  `cub_server`에 perf를 붙이면 CUBRID 함수가 이름으로 나오고, 프레임 포인터 호출 체인도 된다.
- **증분 빌드(D3):** 파일 하나를 고친 재빌드는 71초다. 빌드 트리를 지우고 다시 빌드하면 ccache 적중률이
  98%다. 호스트의 `/usr/include/malloc.h`가 스냅샷의 것과 같으면 그대로 쓰고, 다르면 mount 네임스페이스로
  스냅샷의 것을 보인다.

## 구현 메모 (2026-09-30, P8 클린룸)

빈 `ubuntu:24.04`에 nix 2.35.2만 설치했다. 검증 단계는 `--network=none`으로 돌렸다.

- **full(권한 있는 컨테이너):** D12의 기준을 모두 통과했다.
  - 콜드 스타트는 12–18분이다(64코어). 이 중 10–15분이 개발 셸 준비이고, 공개 캐시에 없는 CI 버전
    도구(perl, git, bison, indent, astyle)를 새로 빌드하는 시간이다. 1시간 기준 안이라 바이너리 캐시는
    두지 않는다(D12).
  - optdebug는 184초, release는 175초에 빌드된다. 스토어 경로는 호스트에서 빌드한 것과 같다.
  - 한 줄 고친 뒤의 재빌드는 85초이고 ccache 적중률은 98%다.
  - 스모크는 통과했다.
  - CTP sql은 16샤드로 17,463건 모두 통과했고(300초), medium은 975건 모두 통과했다(190초).
  - perf는 떠 있는 서버의 CUBRID 함수를 이름으로 보여 준다. gdb는 SIGABRT로 받은 코어에서
    `server.c:264` 같은 파일·줄을 보여 준다.
- **plain(기본 권한):** 빌드 샌드박스가 없다. CTP는 직접 샤드 하나가 eatmydata로 부분 실행 82건을
  모두 통과했다.
- **알려진 한계:**
  - 샌드박스 없는 빌드는 빌드 디렉터리가 매번 달라서 ccache 적중률이 45% 정도다. 샌드박스에서는
    `/build/source`로 고정돼 98%다.
  - CTP의 `ctp.sh`는 `#!/bin/sh`로 bash 문법을 써서 bash로 실행한다. CI(Rocky)의 `/bin/sh`는 bash다.
    dash인 배포판에서 sql·medium 전체는 이것만으로 통과했다.
  - nix의 fetchurl은 URL마다 한 번씩만 시도한다. 그래서 프록시의 일시적 5xx가 콜드 스타트를 실패시킬
    수 있고, 클린룸은 다운로드를 세 번까지 재시도한다. 사람이 쓸 때는 `nix develop`을 다시 실행하면
    받아 둔 것부터 이어서 한다.

## 구현 메모 (2026-09-30, 설치본별 로케일 라이브러리)

- **무엇이 바뀌었나(D8):** CTP는 DB를 만들기 전에 설치본의 `make_locale.sh`로 로케일 라이브러리
  (`libcubrid_all_locales.so`)를 컴파일한다. sql은 `sql/bin/run.sh`, medium은
  `common/script/util_compat_test.sh`에서 한다. 이 단계가 샤드마다 43초쯤 걸렸다. 이제 러너가 설치본마다
  한 번만 만든다.
  - **만드는 방법:** CTP와 같다.
    - 설치본의 실행 디렉터리에서 `cubrid_locales.all.txt`를 `cubrid_locales.txt`로 둔다.
    - `make_locale.sh -t 64bit`를 돌린다. `cubrid_rel`이 debug 빌드(optdebug 포함)를 말하면
      `-m debug`를 붙인다.
    - 툴체인과 로케일 변수는 샤드와 같다.
  - **둘 곳과 넣는 방법:** 결과는 `~/.cache/cubrid-nix/locale/<키>`에 둔다. 샤드마다 이 라이브러리와
    일찍 끝나는 `make_locale.sh`를 넣는다. 그러면 CTP의 `make_locale`은 라이브러리가 이미 있는 것을 보고
    바로 끝난다. 이 넣는 방법은 workspace 러너에서 옮겨 온 것이고, 전에는 `--locale-dir`를 줄 때만 썼다.
  - **키:** 라이브러리를 만드는 입력이다. genlocale 코드가 든 `libcubridsa.so`, `locales/`,
    `cubrid_locales.all.txt`, gcc 경로를 쓴다. 엔진을 다시 빌드하면 `libcubridsa.so`가 바뀐다. 그래서 새
    설치본은 첫 CTP 실행에서 자기 라이브러리를 만든다.
  - **동시 실행:** 라이브러리는 `flock`으로 한 번에 하나씩만 만든다. 기다린 실행은 만들어진 것을 쓴다.
- **CI와의 관계:** CI는 컨테이너마다 같은 스크립트로 이 라이브러리를 컴파일한다. 여기서는 같은 입력과
  같은 컴파일러로 한 번 만들어 나눠 쓴다.
- **비용:** 설치본의 첫 CTP 실행은 샤드를 띄우기 전에 43초쯤을 쓴다. 전에는 모든 샤드가 같은 시간을 동시에
  썼으므로, 첫 실행의 걸린 시간은 비슷하다. 줄어드는 것은 두 번째 실행부터의 시간과 샤드 수만큼 되풀이되던
  gcc다. 캐시는 저절로 지우지 않는다. 설치본 하나에 19MB쯤이고, 지우면 다음 실행이 다시 만든다.
- **검증(호스트, 같은 optdebug 설치본, 테스트케이스 `7bd8ebbc`):**
  - sql 16샤드와 medium을 캐시가 빈 채로 동시에 돌렸다. sql은 17,463/17,463, medium은 975/975로 전과
    같다.
  - 라이브러리는 medium 실행이 한 번 만들었다(45초). sql 실행은 락을 기다린 뒤 그것을 썼다.
  - 샤드의 로케일 단계(`make locale now`부터 `createdb`까지)는 43초에서 0–1초가 됐다. 어느 샤드 로그에도
    컴파일 흔적이 없다.
  - 43건짜리 부분 실행은 84초에서 44초가 됐다.
- **`/home` 아래의 설치본(D8, 같은 날 README 흐름 검증에서 찾음):**
  - 샤드는 `/mnt`, `/tmp`, `/home`을 덮는다. 실행 디렉터리는 설치본을 절대 경로로 가리킨다. 그래서 홈
    디렉터리 아래에 있는 `just shell-build` 설치본은 샤드 안에서 보이지 않았고, CTP는 한 건도 돌지 못했다.
  - 앞선 게이트는 `/nix/store` 설치본으로만 돌아서 이것이 드러나지 않았다.
  - 이제 그런 설치본은 덮기 전에 샤드 디렉터리에 붙여 두고, 레이아웃을 만든 뒤 제 경로에 다시 붙인다.
  - 커널 `core_pattern`이 덮이는 디렉터리를 가리키면 샤드의 코어가 모이지 않는 것은 그대로 남는다.
