#!/usr/bin/env bash
# Install nix for this user only, with the cubrid-nix user store (ADR 0003): no root, no
# /nix, no daemon, no user namespaces needed. The store is at /var/tmp/cubrid-nix/store,
# a path any user can create, and it lives in CUBRID_NIX_HOME behind a symlink. It is
# safe to rerun: the environment is checked again, the configuration is rewritten, the
# store is kept.
#   ./install.sh [--profile] [--no-prefetch] [--build-missing]
#     --profile        source env.sh from ~/.profile and ~/.bashrc
#     --no-prefetch    do not fetch the dev shell's paths from the binary caches
#     --build-missing  build what the caches lack (from source: hours) instead of failing
# Environment, all optional:
#   CUBRID_NIX_HOME       store, state and nix itself   (default ~/.local/share/cubrid-nix)
#   CUBRID_NIX_LAN_CACHE  the LAN cache server, used when it answers within 3 s
#                         (default http://192.168.6.4; empty: none)
#   NIX_SSL_CERT_FILE     a CA bundle, when none of the usual paths has one
set -euo pipefail

profile=0 prefetch=1 build_missing=0
for a in "$@"; do
  case "$a" in
    --profile) profile=1 ;;
    --no-prefetch) prefetch=0 ;;
    --build-missing) build_missing=1 ;;
    *) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"; exit 2 ;;
  esac
done

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The caches' binaries name this path, so it is the same for everyone (ADR 0003 D1).
prefix=/var/tmp/cubrid-nix
store=$prefix/store
home=${CUBRID_NIX_HOME:-$HOME/.local/share/cubrid-nix}
# nix itself: the static build of the NixOS Hydra (ADR 0003 D2)
nix_version=2.35.3
nix_sha256=87d01ef8b4e6ee488c2defc4fde9a6fb3fd6ca5d344219c157fb426f93eeb507
nix_urls=(
  "https://github.com/xmilex-git/cubrid-nix/releases/download/nix-static/nix-$nix_version-x86_64-linux"
  https://hydra.nixos.org/build/346771304/download/1/nix
)
slug=var-tmp-cubrid-nix-store
github_cache=https://github.com/xmilex-git/cubrid-nix/releases/download/nix-cache-$slug
lan=${CUBRID_NIX_LAN_CACHE-http://192.168.6.4}
cache_key=cubrid-nix-cache-1:9tHaV41AhMl1GxTpdkaMjzH+V3/FiXx2F4hto1pcd+U=

fail() { echo "install.sh: $*" >&2; exit 1; }
row() { printf '  %-16s %s\n' "$1" "$2"; }

echo "environment (checked now; nothing here is assumed):"
arch=$(uname -m)
row arch "$arch"
[ "$arch" = x86_64 ] || fail "the caches and the CI toolchain are x86_64 only"
row kernel "$(uname -r)"
row user "$(id -un) (uid $(id -u))"
[ "$(id -u)" != 0 ] || echo "  (root works too, but nothing here needs it)"

# CPUs: what the cgroup's quota allows, not what nproc sees
cpus=$(nproc)
quota=""
if read -r q p 2>/dev/null < /sys/fs/cgroup/cpu.max && [ "$q" != max ]; then
  quota=$(( (q + p - 1) / p ))
elif read -r q 2>/dev/null < /sys/fs/cgroup/cpu/cpu.cfs_quota_us && [ "$q" -gt 0 ] \
    && read -r p < /sys/fs/cgroup/cpu/cpu.cfs_period_us; then
  quota=$(( (q + p - 1) / p ))
fi
[ -z "$quota" ] || [ "$quota" -ge "$cpus" ] || cpus=$quota
row cpus "$cpus (nproc $(nproc), cgroup quota ${quota:-none})"

mem=$(awk '/^MemTotal:/ { print int($2 / 1048576) }' /proc/meminfo)
lim=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo max)
case "$lim" in max|'') ;; *) [ "$lim" -ge $(( 1 << 50 )) ] || mem=$(( lim >> 30 )) ;; esac
row memory "${mem} GiB"

mkdir -p "$home"
home=$(cd "$home" && pwd -P)
disk=$(df -Pk "$home" | awk 'NR == 2 { print int($4 / 1048576) }')
row disk "${disk} GiB free at $home"
# the dev shell takes about 6 GiB, an optdebug build about 10 GiB more
[ "$disk" -ge 8 ] || fail "under 8 GiB free at $home"

if unshare -U true 2>/dev/null; then userns=1; else userns=0; fi
row namespaces "$([ "$userns" = 1 ] && echo "user namespaces work: build sandbox on, CTP in shards" || echo "none: no build sandbox, CTP in one direct shard")"
row core-dumps "ulimit -c $(ulimit -c) (hard $(ulimit -Hc)), core_pattern [$(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo unreadable)]"

cert=${NIX_SSL_CERT_FILE:-}
if [ -z "$cert" ]; then
  for c in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
      /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem; do
    [ -r "$c" ] && { cert=$c; break; }
  done
fi
[ -n "$cert" ] && [ -r "$cert" ] || fail "no CA bundle found: set NIX_SSL_CERT_FILE to one (TLS stays verified)"
row ca-bundle "$cert"

if command -v curl >/dev/null; then fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
elif command -v wget >/dev/null; then fetch() { wget -q -O "$2" "$1"; }
else fail "neither curl nor wget"; fi

# The store's path: a symlink in /var/tmp to this home, or this user's already.
[ -d /var/tmp ] && [ -w /var/tmp ] && [ -k /var/tmp ] || fail "/var/tmp is not a writable sticky directory here"
if [ -L "$prefix" ] && [ "$(stat -c %u "$prefix")" = "$(id -u)" ]; then
  [ "$(readlink "$prefix")" = "$home" ] || fail "$prefix points to $(readlink "$prefix"), not $home: remove it or set CUBRID_NIX_HOME to that"
elif [ -e "$prefix" ] || [ -L "$prefix" ]; then
  fail "$prefix exists and is not this user's symlink ($(stat -c '%U %F' "$prefix")): one user per host can have the user store"
else
  ln -s "$home" "$prefix"
fi
row store "$store -> $home/store"

mkdir -p "$home"/{bin,etc/nix,store,var/nix,var/log/nix,var/cache/ccache,var/build}

nix=$home/bin/nix
if [ ! -x "$nix" ] || [ "$(sha256sum < "$nix" | cut -d' ' -f1)" != "$nix_sha256" ]; then
  for u in "${nix_urls[@]}"; do
    echo "fetching nix $nix_version from $u"
    if fetch "$u" "$nix.part" && [ "$(sha256sum < "$nix.part" | cut -d' ' -f1)" = "$nix_sha256" ]; then
      chmod +x "$nix.part" && mv "$nix.part" "$nix"
      break
    fi
    echo "  failed or wrong sha256"
    rm -f "$nix.part"
  done
  [ -x "$nix" ] || fail "could not fetch nix $nix_version with sha256 $nix_sha256"
fi
# the static nix is one program for every nix-* command
for c in nix-build nix-channel nix-collect-garbage nix-copy-closure nix-env nix-hash \
    nix-instantiate nix-prefetch-url nix-shell nix-store; do
  ln -sfn nix "$home/bin/$c"
done

substituters=$github_cache
# the LAN cache only when it answers as this store's cache (another network may use the address)
if [ -n "$lan" ] && command -v curl >/dev/null \
    && curl -fsS --max-time 3 "$lan/$slug/nix-cache-info" 2>/dev/null | grep -qx "StoreDir: $store"; then
  substituters="$lan/$slug $substituters"
fi
row caches "$substituters"

cat > "$home/etc/nix/nix.conf" <<EOF
# Written by cubrid-nix install.sh (ADR 0003) on $(date -u +%FT%TZ); rerun it to change this.
store = local?store=$store&state=$home/var/nix&log=$home/var/log/nix
# $prefix is a symlink: the store's path must stay the same for everyone
allow-symlinked-store = true
experimental-features = nix-command flakes
# single-user: the builds run as this user
build-users-group =
sandbox = $([ "$userns" = 1 ] && echo true || echo false)
$([ "$userns" = 0 ] || echo "# the sandboxed CUBRID build finds its ccache here (nix/cubrid.nix)
extra-sandbox-paths = $prefix/var/cache/ccache")
build-dir = $home/var/build
# no public cache has paths for this store: only ours
substituters = $substituters
trusted-public-keys = $cache_key
ssl-cert-file = $cert
cores = $cpus
max-jobs = 1
flake-registry =
EOF

cat > "$home/env.sh" <<EOF
# cubrid-nix user environment (ADR 0003), written by install.sh. Source it in every new
# shell:  . '$home/env.sh'
# /var/tmp may be emptied between sessions; the store is valid while the link is back.
if [ ! -e '$prefix' ] && [ ! -L '$prefix' ]; then ln -s '$home' '$prefix'; fi
if [ "\$(readlink '$prefix' 2>/dev/null)" != '$home' ] || [ "\$(stat -c %u '$prefix')" != "\$(id -u)" ]; then
  echo "cubrid-nix: $prefix is not this user's link to $home; rerun install.sh" >&2
else
  # this nix.conf only: not ~/.config/nix/nix.conf, not a daemon of another nix
  export NIX_CONF_DIR='$home/etc/nix' NIX_USER_CONF_FILES='$home/etc/nix/nix.conf'
  # the defaults of every store nix opens: with the store setting alone, substituters
  # keep /nix/store and refuse this store's caches
  export NIX_STORE_DIR='$store' NIX_STATE_DIR='$home/var/nix' NIX_LOG_DIR='$home/var/log/nix'
  # caches of its own: an evaluation cached by a nix on another store names that store's paths
  export NIX_CACHE_HOME='$home/var/cache/nix'
  unset NIX_REMOTE
  export NIX_SSL_CERT_FILE='$cert'
  case ":\$PATH:" in *:'$home/bin':*) ;; *) export PATH='$home/bin':\$PATH ;; esac
fi
EOF

. "$home/env.sh"
got=$(nix eval --raw --expr builtins.storeDir)
[ "$got" = "$store" ] || fail "nix uses the store $got, not $store"
row nix "$(nix --version) at $nix"

if [ "$profile" = 1 ]; then
  for f in "$HOME/.profile" "$HOME/.bashrc"; do
    grep -qsF "$home/env.sh" "$f" || printf "\n# cubrid-nix (install.sh --profile)\n. '%s/env.sh'\n" "$home" >> "$f"
  done
  row profile "~/.profile and ~/.bashrc source env.sh"
fi

if [ "$prefetch" = 1 ]; then
  echo "fetching the dev shell's paths (the toolchain, the tools, gdb) ..."
  t0=$(date +%s)
  jobs=0
  [ "$build_missing" = 0 ] || jobs=1
  # max-jobs 0: whatever the caches lack fails here instead of building for hours
  if ! nix build --no-link --max-jobs "$jobs" "$repo#devShells.x86_64-linux.default.inputDerivation"; then
    fail "the caches lack the paths above (rerun with --build-missing to build them here)"
  fi
  nix develop "$repo" -c true
  row prefetch "$(( $(date +%s) - t0 )) s, store $(du -sh "$home/store" | cut -f1)"
fi

cat <<EOF
done. In every new shell:
  . $home/env.sh
then, in $repo:  make   (the recipes; they enter nix develop themselves)
EOF
