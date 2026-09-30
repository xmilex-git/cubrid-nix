# cubrid-nix

CUBRID CI의 빌드·테스트 환경을 nix로 재현하는 레포의 공통 언어다.

## Language

**nix 개발 환경 (nix dev environment)**:
CUBRID 빌드(nix derivation)와 서버 실행·CTP에 쓰는 도구를 `flake.lock`으로 고정해 정의한 nix flake, 즉 이 레포 자체다. 배포판 패키지 없이 CI와 같은 버전의 도구로 빌드·검증하게 하는 추가 경로이며, workspace 호스트의 기존 흐름을 대체하지 않는다.
_Avoid_: nix 프로파일(`nix profile install`로 PATH에만 올린 묶음과 혼동), 컨테이너 이미지

**CI 툴체인 스냅샷 (CI toolchain snapshot)**:
CI 빌드 이미지 한 digest에 설치된 Rocky 8.10 RPM 가운데 제품에 닿는 것 — 컴파일러, 링커, libc와 커널 헤더, libstdc++, 링크되는 C 라이브러리, 코드를 생성하는 도구 — 을 내용 해시로 고정한 묶음이다. 호스트 배포판과 무관하게 `/nix/store`에서 돈다.
_Avoid_: sysroot(그 일부), 툴체인 이미지, RPM 설치(설치하지 않고 풀어서 쓴다)

**봉인 입력 (sealed inputs)**:
엔진 빌드가 도중에 네트워크에서 받던 파일(3rdparty 소스, 번들 JDK, Gradle 배포본과 의존성)을 내용 해시로 고정해 빌드 전에 공급한 것이다. 봉인된 빌드는 네트워크 없이 끝나며, 엔진이 입력을 바꾸면 봉인 목록을 갱신해 따라간다.
_Avoid_: 캐시(지워도 다시 받는 임시본과 혼동), 오프라인 빌드(수단과 혼동)

**설치본 (install)**:
빌드가 만든 실행 가능한 CUBRID 디렉터리다. `nix build`의 설치본은 `/nix/store` 아래에 있어 읽기 전용이다.
_Avoid_: 빌드(행위·빌드 트리와 혼동)

**실행 디렉터리 (run directory)**:
설치본 하나를 가리키면서 conf·DB·로그·임시 파일을 쓰는, 서버 한 벌이 도는 쓰기 가능한 `$CUBRID`다. CTP 샤드마다 하나씩 만든다.
_Avoid_: 설치본 사본(전체 복사로 오해)

**샤드 (shard)**:
러너가 스위트를 시간 균형으로 나눈 실행 단위로, 격리 단위(`unshare` 네임스페이스) 하나와 1:1이다. 부분 실행은 샤드 1개짜리 실행이다.
_Avoid_: 컨테이너(workspace 러너의 격리 단위), 노드, 버킷

**로케일 라이브러리 (locale library)**:
`cubrid_locales.txt`에 적힌 로케일을 `make_locale.sh`가 LDML에서 컴파일한 공유 라이브러리(`libcubrid_all_locales.so`)다. 서버는 그 로케일과 콜레이션을 이 라이브러리로 쓴다. CTP는 DB를 만들기 전에 이것을 만든다. 이 레포에서는 설치본마다 한 번 만들어, 모든 샤드와 이후 실행이 나눠 쓴다.
_Avoid_: 로케일 데이터(CUBRID 프로세스의 `setlocale`이 읽는 glibc 로케일 파일과 혼동), 로케일 빌드(엔진 빌드와 혼동)

**직접 샤드 (direct shard)**:
네임스페이스를 만들 수 없는 환경에서 러너가 격리 없이 하나만 돌리는 샤드다. CTP teardown이 이 사용자의 모든 `cub_*`를 죽이므로 CUBRID 전용 환경을 전제로 하고, fsync는 eatmydata로 끈다.
_Avoid_: 호스트 실행(격리 없는 CTP를 권하는 말로 들림), 폴백 모드

**사내 바이너리 캐시 (LAN binary cache)**:
새 환경이 `nix develop`과 빌드에 쓸 스토어 경로를 미리 서명해 둔 nix 파일 캐시다. 사내 서버가 이것을 내보낸다. 캐시가 닿는 머신은 도구를 빌드하지 않고 받기만 한다.
_Avoid_: 공개 캐시(cache.nixos.org와 혼동), 빌드 캐시(ccache와 혼동)

**클린룸 검증 (clean-room check)**:
nix만 설치한 새 컨테이너에서 보장 범위가 통과함을 보이는 수용 시험이다. 권한 있는 컨테이너와 기본 권한 컨테이너에서 한 번씩 돈다.
_Avoid_: 스모크(부분 확인과 혼동)

**보장 문구 (guarantee statement)**:
이 레포가 어떤 조건에서 무엇이 된다고 약속하는지 적은 README의 한 절이다. 클린룸 검증이 그 문구가 사실인지 증명한다.
_Avoid_: 요구 사항(환경에 대한 조건과 레포의 약속을 섞음)
