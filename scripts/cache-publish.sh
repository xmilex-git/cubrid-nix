#!/usr/bin/env bash
# Publish the paths no public cache has, from a cache directory that `make cache-push`
# filled, as the flat assets of this repo's release for the store this nix uses:
# `nix-cache` for /nix/store (ADR 0002 D7), `nix-cache-<store dir>` for another (ADR 0003 D4).
#   cache-publish.sh [cache dir]
# - "Ours" is the closure of the cache roots minus what cache.nixos.org signed, and
#   minus flake inputs (named "source"), which every client fetches from GitHub.
# - Release assets cannot sit in directories, so each narinfo's URL loses its nar/
#   prefix. The signature covers the path, its hash, size and references, not URL.
# - Assets already there are left alone. Those no current path uses are deleted: a
#   release holds at most 1000 assets.
# - The result is verified through the release URL with the cache's public key, as a
#   client that has never seen it.
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
. "$repo_dir/scripts/cache-lib.sh"
dir=$(cd "${1:-$lan_dir}" && pwd)
key=${CUBRID_NIX_CACHE_KEY_FILE:-$HOME/.config/cubrid-nix/cache-key.secret}
[ -r "$key" ] || { echo "no signing key at $key (ADR 0002 D5)" >&2; exit 1; }
pub=$(nx key convert-secret-to-public < "$key")
tag=$release_tag
repo=$(cd "$repo_dir" && gh repo view --json nameWithOwner -q .nameWithOwner)
url=https://github.com/$repo/releases/download/$tag
out=$repo_dir/.scratch/cache-publish
rm -rf "${out:?}"
mkdir -p "$out/assets"

# a failure inside <(...) would go unnoticed and publish part of the roots
roots_txt=$("$repo_dir/scripts/cache-roots.sh")
mapfile -t roots <<< "$roots_txt"
nx path-info --json --json-format 1 --recursive "${roots[@]}" > "$out/path-info.json"
python3 - "$out/path-info.json" "$dir" "$out/assets" > "$out/ours.txt" <<'EOF'
import json, os, re, sys
info = json.load(open(sys.argv[1]))
cache, assets = sys.argv[2], sys.argv[3]
items = info.items() if isinstance(info, dict) else ((i['path'], i) for i in info)
for path, i in sorted(items):
    if any(s.startswith('cache.nixos.org-1:') for s in (i or {}).get('signatures') or []):
        continue
    if path.endswith('-source'):
        continue
    h = os.path.basename(path).split('-', 1)[0]
    src = os.path.join(cache, h + '.narinfo')
    if not os.path.exists(src):
        sys.exit('%s is not in %s; run `make cache-push` first' % (path, cache))
    text = open(src).read()
    m = re.search(r'^URL: nar/(\S+)$', text, re.M)
    if not m:
        sys.exit('no nar/ URL in ' + src)
    with open(os.path.join(assets, h + '.narinfo'), 'w') as f:
        f.write(text.replace('URL: nar/' + m.group(1), 'URL: ' + m.group(1)))
    os.symlink(os.path.join(cache, 'nar', m.group(1)), os.path.join(assets, m.group(1)))
    print(path)
EOF
# after cache.nixos.org (40): for /nix/store nixpkgs' paths come from there, and only ours
# reach GitHub; no public cache has the user store's paths, so all of them are here
printf 'StoreDir: %s\nWantMassQuery: 1\nPriority: 45\n' "$store_dir" > "$out/assets/nix-cache-info"
echo "ours: $(wc -l < "$out/ours.txt") paths, $(du -shL "$out/assets" | cut -f1)"
n=$(ls "$out/assets" | wc -l)
[ "$n" -le 1000 ] || { echo "$n assets: a release holds at most 1000 (ADR 0002 D7)" >&2; exit 1; }

if ! gh release view "$tag" -R "$repo" > /dev/null 2>&1; then
  gh release create "$tag" -R "$repo" --prerelease --title "nix binary cache" --notes "$(cat <<NOTES
The nix binary cache for machines the LAN cache does not reach (ADR 0002), for the
store $store_dir: the store paths no public cache has, signed with cubrid-nix-cache-1.
Add to nix.conf:

    extra-substituters = $url
    extra-trusted-public-keys = $pub

The assets are replaced by \`make cache-publish\`; they are not meant to be downloaded by hand.
NOTES
)"
fi
mapfile -t have < <(gh release view "$tag" -R "$repo" --json assets -q '.assets[].name')
mapfile -t want < <(cd "$out/assets" && ls)
declare -A has=() wants=()
for a in "${have[@]}"; do has[$a]=1; done
for a in "${want[@]}"; do wants[$a]=1; done
new=()
for a in "${want[@]}"; do [ -n "${has[$a]:-}" ] || new+=("$out/assets/$a"); done
if [ "${#new[@]}" -gt 0 ]; then
  echo "uploading ${#new[@]} asset(s) ..."
  gh release upload "$tag" -R "$repo" "${new[@]}"
fi
if [ -n "${has[nix-cache-info]:-}" ] && ! curl -fsSL "$url/nix-cache-info" | cmp -s - "$out/assets/nix-cache-info"; then
  gh release upload "$tag" -R "$repo" --clobber "$out/assets/nix-cache-info"
fi
for a in "${have[@]}"; do
  [ -n "${wants[$a]:-}" ] || { echo "deleting stale asset $a"; gh release delete-asset "$tag" "$a" -R "$repo" -y; }
done

mapfile -t ours < "$out/ours.txt"
# a release can answer 404 for a minute after an upload
for i in $(seq 1 12); do curl -fsSL -o /dev/null "$url/nix-cache-info" && break; sleep 10; done
# as a client that has never seen the cache
NIX_CACHE_HOME=$out/client XDG_CACHE_HOME=$out/client \
  nx store verify --store "$url" --trusted-public-keys "$pub" "${ours[@]}"
echo "release cache: $url (${#ours[@]} paths verified with $pub)"
