#!/usr/bin/env bash
# Fill or update the LAN binary cache directory (ADR 0002): everything a new environment
# fetches or builds for `nix develop` and `make build`, nixpkgs' own paths and the
# flake's inputs included, signed and zstd-compressed into a nix file cache that
# `cache-server-image` serves. Paths already there are skipped.
#   cache-push.sh [cache dir] [secret key file]
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$repo/scripts/cache-lib.sh"
dir=${1:-$lan_dir}
key=${2:-$HOME/.config/cubrid-nix/cache-key.secret}
[ -r "$key" ] || { echo "no signing key at $key (ADR 0002 says how to make one)" >&2; exit 1; }
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
# substituters are asked in priority order, and cache.nixos.org's is 40
[ -e "$dir/nix-cache-info" ] || printf 'StoreDir: %s\nWantMassQuery: 1\nPriority: 30\n' "$store_dir" > "$dir/nix-cache-info"
grep -qx "StoreDir: $store_dir" "$dir/nix-cache-info" \
  || { echo "$dir holds another store's paths (nix-cache-info); this nix uses $store_dir" >&2; exit 1; }
to="file://$dir?compression=zstd&parallel-compression=true&secret-key=$key"
cd "$repo"
# a failure inside <(...) would go unnoticed and push part of the roots
roots_txt=$(scripts/cache-roots.sh)
mapfile -t roots <<< "$roots_txt"
# A path written to after it was built would be served with a wrong hash.
nx store verify --no-trust --recursive "${roots[@]}" \
  || { echo "modified store paths above: 'nix store repair <path>', then push again" >&2; exit 1; }
nx copy --to "$to" "${roots[@]}"
nx flake archive --to "$to"
# what a client gets: every path's content hash and this key's signature
pub=$(nx key convert-secret-to-public < "$key")
nx store verify --store "file://$dir" --trusted-public-keys "$pub" --recursive "${roots[@]}"
echo "cache: $dir ($(du -sh "$dir" | cut -f1)), store $store_dir, public key $pub"
