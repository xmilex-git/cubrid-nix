# 패키지 근거표 (ADR 0001 D13)

nix 개발 환경에 들어 있는 것마다, 빠지면 어느 단계가 어떻게 실패하는지 적는다. 극단적으로 줄이지는
않는다. 일부러 많이 넣지 않는다는 기준이다.

## 크기 (클린룸, 2026-09-30)

| 항목 | 크기 |
|---|---|
| CI 툴체인 스냅샷(RPM 30개와 데이터) | 270 MiB |
| CI 버전 도구 전체(`ci-tools`) | 715 MiB. perl의 `Config_heavy.pl`이 빌드에 쓴 nixpkgs gcc를 참조해서 커졌다. |
| 개발 셸과 빌드 입력까지 받은 스토어(콜드 스타트 직후) | 3.3 GiB |
| CUBRID 설치본 optdebug / release | 814 MB / 763 MB (closure 1.1 / 1.0 GiB) |
| 빌드 두 벌과 재빌드까지 한 스토어 | 6.0 GiB |

## CI 툴체인 스냅샷 (Rocky 8.10 RPM, `nix/rpms/*.json`)

| RPM | 빠지면 |
|---|---|
| gcc, gcc-c++, cpp | 컴파일이 안 된다. |
| binutils | as와 ld가 없어서 오브젝트를 만들거나 링크하지 못한다. `usr/bin/ld`는 `ld.bfd` 링크다. |
| glibc, glibc-devel, glibc-headers, kernel-headers | libc와 헤더가 없다. 런타임 glibc 2.28도 이것이다. |
| libgcc, libstdc++, libstdc++-devel, libstdc++-static | C++ 링크가 안 된다. CUBRID는 `-static-libstdc++`로 링크한다. |
| libgomp, isl | CI 이미지에 있다. gcc의 OpenMP와 Graphite용이고, 기본 빌드에서는 쓰지 않는다. CI와 같게 두려고 유지한다. |
| libmpc, mpfr, gmp, zlib | cc1이 뜨지 않는다. |
| libxcrypt, libxcrypt-devel | glibc-devel이 요구한다. `crypt`다. |
| ncurses-devel, ncurses-libs, ncurses-c++-libs | libedit(csql 행 편집) configure가 실패한다. |
| flex, m4 | csql과 loaddb 렉서, `FlexLexer.h`가 없다. |
| systemtap-sdt-devel | `dtrace`와 `sys/sdt.h`가 없다. `ENABLE_SYSTEMTAP`의 기본값이 ON이라 configure가 실패한다. |
| glibc-common, glibc-gconv-extra | `iconv`와 EUC-KR 변환기가 없어서 ko_KR.euckr 메시지 카탈로그를 만들지 못한다. |
| elfutils-libelf-devel | `nlist.h`가 없다(`src/base/dynamic_load.h`). |
| tzdata | `TZ=Asia/Seoul`이 경고 없이 UTC가 된다. |
| glibc-langpack-en, glibc-langpack-ko | CUBRID 프로세스의 `setlocale(en_US.UTF-8, ko_KR.UTF-8)`가 실패한다. 멀티바이트 폭이 C 로케일이 된다. |

## CI 버전 빌드 도구 (`nix/tools.nix`)

| 도구 | 빠지면 |
|---|---|
| cmake 3.26.5, ninja 1.11.1 | `build.sh`가 configure와 빌드를 하지 못한다. |
| make 4.2.1 | 3rdparty ExternalProject(OpenSSL, libedit, expat, unixODBC, LZ4, RE2)가 빌드되지 않는다. |
| bison 3.0.5 | csql과 loaddb 문법을 생성하지 못한다. |
| perl 5.26.3 | OpenSSL `Configure`(Time::Piece)가 돌지 않는다. |
| ant 1.10.9 | JDBC 드라이버를 빌드하지 못한다. CTP sql/medium은 `jdbc/cubrid_jdbc.jar`가 필요하다. |
| Temurin 8u442 | javac, ant, Gradle(pl_server)이 돌지 않는다. JNI 헤더도 여기서 온다. |
| git 2.43.7 | `build.sh`가 시작하지 않는다(`Git not found`). 소스 내보내기, 봉인, CTP 테스트케이스에도 쓴다. |
| python3 | systemtap의 `dtrace` 스크립트가 돌지 않는다. |
| which, file | `build.sh`와 libtool 검사가 쓴다. |
| ccache 4.10.2 | 빌드는 되지만 재빌드가 느리다. |
| GNU indent 2.2.11, astyle 3.1, google-java-format 1.7 | 빌드와 무관하다. CI의 코드 스타일 검사를 같은 결과로 돌리기 위해 넣는다. |

## CTP와 러너 (`flake.nix` 개발 셸)

| 패키지 | 빠지면 |
|---|---|
| util-linux (unshare, nsenter, mount) | 샤드를 격리하지 못한다. 러너가 직접 샤드 하나로 내려간다. |
| iproute2 (ip) | 샤드의 네트워크 네임스페이스에서 loopback을 켜지 못한다. |
| procps, lsof, bc, nettools, rsync, zip, gnutar, gzip | CTP 스크립트, 러너의 시나리오 복사, hang 증거 수집이 쓴다. |
| glibc 로케일(en_US, en_US.UTF-8, ko_KR) | CTP 도구가 `LC_ALL=en_US`를 쓸 수 없다. |
| eatmydata(스냅샷 glibc로 빌드) | volatile overlay를 못 쓰는 환경에서 fsync가 켜진 채로 돈다. |
| just, curl, unzip | 레시피와 봉인 갱신이 쓴다. |

## 진단

| 패키지 | 빠지면 |
|---|---|
| gdb 15.2 | 코어를 판독하지 못한다. 래퍼가 스냅샷 glibc의 `libthread_db`를 쓴다. |
| perf 6.6 | 프로파일을 잡지 못한다. addr2line 제한 시간을 60초로 둔다. |
