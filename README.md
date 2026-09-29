# cubrid-nix

아무것도 설치되지 않은 x86_64 리눅스에 **nix만 설치하면**, CUBRID CI와 같은 툴체인과 도구 버전으로
엔진 빌드 → 서버 실행 → CTP → perf·gdb 분석까지 할 수 있게 하는 nix flake다.

> 상태: 구현 중. 결정과 이유는 [ADR 0001](docs/adr/0001-reproduce-ci-environment-with-nix.md),
> 용어는 [CONTEXT.md](CONTEXT.md)에 있다.

## 보장 문구

> x86_64 리눅스 + nix. perf는 커널이 perf 이벤트를 허용해야 하고, CTP 병렬 실행은 user namespace
> 허용이 필요하다(없으면 perf는 빠지고 CTP는 직렬로 돈다). fsync 끄기는 커널 5.11 이상이면
> volatile overlay, 아니면 eatmydata다. 코어는 커널 `core_pattern`이 파일 경로일 때만 러너가 모은다.
> 처음 한 번은 네트워크가 필요하고, 빌드와 실행은 네트워크 없이 돈다.

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

## 사용법

```bash
nix develop                                   # 이 셸 안에서 아래 레시피를 쓴다
just build <워크트리> optdebug                  # nix build: 소스 배포본처럼 내보내 CI처럼 빌드
just shell-build <워크트리> optdebug            # 워크트리에서 증분 빌드 (ccache)
just smoke <설치본>                             # 실행 디렉터리에서 서버·csql·PL/CSQL
just ctp sql <설치본> --pr <N>                  # CTP: unshare 샤드, volatile DB
just seal <워크트리>                            # 봉인 목록 갱신 (네트워크 필요)
```

`just build`의 결과는 `.scratch/install/<워크트리>-<mode>`에 링크된다. 워크트리는 서브모듈이 모두
초기화돼 있어야 한다(CI처럼 cubridmanager 포함).

## 진행

- [x] P1 CI 툴체인 스냅샷(RPM)과 컴파일러 래퍼
- [x] P2 CI 버전 빌드 도구
- [x] P3 봉인 입력과 갱신 레시피
- [x] P4 CUBRID derivation(optdebug, release)
- [ ] P5 개발 셸과 ccache
- [ ] P6 실행 디렉터리와 서버 스모크
- [ ] P7 CTP 러너 이식
- [ ] P8 클린룸 검증(권한 있음/기본 권한)과 근거표
