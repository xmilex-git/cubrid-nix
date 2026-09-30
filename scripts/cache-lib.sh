# Sourced by the cache scripts: where the binary caches of the store this nix uses live
# (ADR 0002, ADR 0003 D4). A cache holds one store directory's paths, so the user store
# has caches of its own: a subdirectory of the LAN cache directory, which the LAN server
# serves at http://<server>/<slug>, and a release of its own.
nx() { nix --extra-experimental-features 'nix-command flakes' "$@"; }
store_dir=$(nx eval --raw --expr builtins.storeDir)
slug=""
[ "$store_dir" = /nix/store ] || slug=$(printf '%s' "${store_dir#/}" | tr / -)
lan_base=${CUBRID_NIX_CACHE_DIR:-/bench/ssd/cubrid-nix-cache/cache}
lan_dir=$lan_base${slug:+/$slug}
release_tag=nix-cache${slug:+-$slug}
