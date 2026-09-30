# 바이너리 캐시 갱신 지침

캐시는 스토어마다 두 곳에 있다. 스토어는 `/nix/store`와 사용자 스토어 `/var/tmp/cubrid-nix/store`다.
결정과 이유는 [ADR 0002](adr/0002-lan-binary-cache.md)와 [ADR 0003](adr/0003-user-store-without-root.md) D4에 있다.

| 스토어 | 캐시 | 주소 | 담은 것 |
|---|---|---|---|
| `/nix/store` | 사내 | `http://192.168.6.4` | 새 환경에 필요한 것 전부 |
| `/nix/store` | GitHub | `https://github.com/xmilex-git/cubrid-nix/releases/download/nix-cache` | 공개 캐시에 없는 우리 경로만 |
| 사용자 스토어 | 사내 | `http://192.168.6.4/var-tmp-cubrid-nix-store` | 새 환경에 필요한 것 전부 |
| 사용자 스토어 | GitHub | `https://github.com/xmilex-git/cubrid-nix/releases/download/nix-cache-var-tmp-cubrid-nix-store` | flake 입력의 소스를 뺀 전부 |

사내 캐시는 사내망에서, GitHub 캐시는 사내 캐시에 닿지 않는 외부 환경에서 쓴다. 사용자 스토어의 경로는
공개 캐시에 없으므로 GitHub 캐시가 closure 전부를 담는다.

## 언제 갱신하나

`flake.nix`, `flake.lock`, `nix/` 가운데 하나라도 바꾼 커밋을 main에 푸시했을 때 갱신한다.

- 도구 버전, CI 툴체인 스냅샷, 봉인 목록, 개발 셸이 바뀐 경우다.
- nixpkgs, CTP, 기본 엔진 입력을 갱신한 경우(`nix flake update ...`)도 여기에 든다.
- 엔진 develop이 3rdparty, JDK, Gradle을 바꿨으면 먼저 입력을 따라가 커밋한다.
  - `nix flake update cubrid-src`를 실행한다.
  - JDK나 Gradle이 바뀌었으면 `make seal WORKTREE=<엔진 워크트리>`도 실행한다.

그 밖의 변경(README, 러너 스크립트, CTP 표)에는 할 일이 없다.

## 어떻게 갱신하나

6.35(`35-ilhansong_data3`)에서 스토어마다 한 번씩 실행한다. `make`는 그것을 돌리는 nix의 스토어를 보고
그 스토어의 캐시만 갱신한다. 개발 셸 밖의 셸에서 실행한다.

```bash
cd ~/dev/cubrid-nix
make cache-update                                        # /nix/store: 호스트의 nix
bash -c '. /bench/ssd/cubrid-nix-store/env.sh && make cache-update'   # 사용자 스토어
```

- **사내 캐시:** `/bench/ssd/cubrid-nix-cache/cache`(사용자 스토어는 그 아래
  `var-tmp-cubrid-nix-store/`)를 채우고, 내용 해시와 서명을 검증한다.
  - 6.4 서버는 이 디렉터리를 그대로 읽으므로 다시 띄울 필요가 없다.
- **GitHub 캐시:** 그 스토어의 릴리스에 올린다. `/nix/store`는 공개 캐시에 없는 우리 경로만 올린다.
  - 없는 파일만 올리고, 더는 쓰지 않는 파일은 지운다.
  - 끝에 GitHub 주소로 받아 서명을 검증한다.
- **필요한 것:** 서명 비밀 키 `~/.config/cubrid-nix/cache-key.secret`과 `gh` 로그인.
- **6.35의 사용자 스토어:** `/bench/ssd/cubrid-nix-store`에 있다. `/var/tmp/cubrid-nix`가 그곳을
  가리킨다(`CUBRID_NIX_HOME=/bench/ssd/cubrid-nix-store ./install.sh --no-prefetch`로 만든 것).
  - 사용자 스토어의 closure는 캐시를 채우기 전에 여기서 소스로 빌드해 둔다. 처음 한 번은 몇 시간 걸린다.
    nixpkgs를 올리면 다시 그만큼 걸린다.
- **바뀐 것이 없을 때:** 다시 실행해도 된다. 올라가 있는 것은 건너뛴다.
- **한쪽만 할 때:** `make cache-push`는 사내 캐시만, `make cache-publish`는 GitHub 캐시만 갱신한다.

## 확인

```bash
curl --noproxy '*' -fsS http://192.168.6.4/nix-cache-info
curl -fsSL https://github.com/xmilex-git/cubrid-nix/releases/download/nix-cache/nix-cache-info
curl --noproxy '*' -fsS http://192.168.6.4/var-tmp-cubrid-nix-store/nix-cache-info
curl -fsSL https://github.com/xmilex-git/cubrid-nix/releases/download/nix-cache-var-tmp-cubrid-nix-store/nix-cache-info
```

앞의 둘은 `StoreDir: /nix/store`, 뒤의 둘은 `StoreDir: /var/tmp/cubrid-nix/store`가 나와야 한다.
우선순위는 사내 캐시가 30, GitHub 캐시가 45다. cache.nixos.org는 40이다.

## 서버 이미지를 바꿨을 때만

`flake.nix`의 `cacheServerImage`(nginx)를 바꿨을 때만 한다. 캐시 내용이 바뀐 것은 여기에 해당하지 않는다.

1. 6.35에서 이미지를 만든다.

   ```bash
   nix build .#cache-server-image
   cp -L result /bench/ssd/cubrid-nix-cache/cubrid-nix-cache-image.tar.gz
   ```

2. 6.2에서 root로 다시 띄운다.

   ```bash
   podman load -i /data2/35-ilhansong_data3/cubrid-nix-cache/cubrid-nix-cache-image.tar.gz
   podman rm -f cubrid-nix-cache
   podman run -d --name cubrid-nix-cache --restart=always --network ipv1 --ip 192.168.6.4 \
     -v /data2/35-ilhansong_data3/cubrid-nix-cache/cache:/cache:ro localhost/cubrid-nix-cache:latest
   ```

   6.2 호스트에서는 ipvlan 컨테이너 IP에 닿지 않는다. 확인은 6.35에서 위의 `curl`로 한다.

## 문제가 생기면

- **캐시에 든 경로가 해시 검사에 걸릴 때:** 호스트 스토어의 그 경로가 빌드 뒤에 바뀐 것이다.
  1. `nix store repair <경로>`로 고친다.
  2. 캐시 디렉터리에서 그 경로의 `.narinfo`와 NAR 파일을 지운다.
  3. `make cache-update`를 다시 실행한다.
- **클라이언트가 지운 NAR을 찾을 때:** 이미 받은 narinfo를 기억하는 클라이언트는 404를 받는다. 그
  클라이언트에서 `~/.cache/nix/binary-cache-v*.sqlite`를 지운다.
- **갱신했는데 클라이언트가 새 경로를 빌드하려 할 때:** 캐시를 채우기 전에 같은 경로를 찾아본
  클라이언트는 "없음"을 1시간 기억한다. 같은 파일을 지우거나 1시간 기다린다.
- **서명 키를 잃었을 때:** ADR 0002 D5대로 새 키로 두 캐시를 다시 채우고, README의 공개 키를 바꾼다.
