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

## D11 — 보장 문구

> x86_64 리눅스 + nix. perf는 커널이 perf 이벤트를 허용해야 하고, CTP 병렬 실행은 user namespace
> 허용이 필요하다(없으면 perf는 빠지고 CTP는 직렬로 돈다). fsync 끄기는 커널 5.11 이상이면
> volatile overlay, 아니면 eatmydata다. 코어는 커널 `core_pattern`이 파일 경로일 때만 러너가 모은다.
> 처음 한 번은 네트워크가 필요하고, 빌드와 실행은 네트워크 없이 돈다.

## D12 — 클린룸 검증

- **결정:** `ubuntu:24.04` 컨테이너에 nix 2.35.2만 설치해 검증한다. nix 설치에 필요한 curl, xz,
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

## D13 — 최소성

패키지마다 "빠지면 무엇이 어떻게 실패하는지"를 근거표로 남기고 closure 크기를 기록한다. 극단적인
경량화는 하지 않는다. 일부러 많이 설치하지 않는다는 뜻이다.

## D14 — 기록

이 ADR과 `CONTEXT.md`가 결정과 용어의 원본이다. workspace의 `CONTEXT.md`에는 이 레포를 가리키는
포인터만 둔다. workspace 용어집의 **샤드**는 "컨테이너 1개"와 1:1이지만, 이 레포에서는 "격리 단위
(`unshare` 네임스페이스) 1개"와 1:1이다.
