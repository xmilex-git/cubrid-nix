#!/usr/bin/env bash
# Record the sealed inputs a CUBRID worktree needs in nix/sealed/lock.json (ADR 0001 D7).
# Needs network. The 3rdparty tarballs need no entry: nix reads their URL and SHA256 from
# the source. Entries accumulate; content hashes keep older worktrees buildable.
#
#   1. the bundled JDK and the Gradle distribution, by URL
#   2. pl_server's Maven artifacts: pl_server is built once with network, with the
#      arguments the engine's CMake passes to gradlew, in a fresh Gradle home; every
#      file Gradle downloaded is recorded with the repository URL that serves it.
set -euo pipefail

ws=$(cd "${1:?usage: seal.sh <cubrid worktree>}" && pwd)
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lock=$repo/nix/sealed/lock.json
work=$repo/.scratch/seal/$(date +%Y%m%dT%H%M%S)
mkdir -p "$work"
nixx() { nix --extra-experimental-features 'nix-command flakes' "$@"; }

prefetch() { # url -> "<hash> <store path>"
  nixx store prefetch-file --json "$1" |
    python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["hash"], d["storePath"])'
}
add_file() { # url -> store path of the file
  local hash path
  read -r hash path < <(prefetch "$1")
  python3 - "$lock" "$1" "$hash" <<'EOF'
import json, sys
lock, url, h = sys.argv[1:]
d = json.load(open(lock))
old = d["files"].get(url)
if old and old != h:
    sys.exit("seal: %s changed content: lock has %s, server gives %s" % (url, old, h))
if not old:
    d["files"][url] = h
    json.dump(d, open(lock, "w"), indent=2)
    open(lock, "a").write("\n")
    print("sealed file:", url, file=sys.stderr)
EOF
  echo "$path"
}

jdk_url=$(sed -n 's/^ *set(JDK_URL "\(https:[^"]*linux[^"]*\)").*/\1/p' "$ws/pl_engine/cmake/install_jdk.cmake" | head -1)
dist_url=$(sed -n 's/^distributionUrl=//p' "$ws/pl_engine/gradle/wrapper/gradle-wrapper.properties" | sed 's/\\:/:/g')
add_file "$jdk_url" >/dev/null
dist=$(add_file "$dist_url")

# pl_server needs the JDBC jar of the same source: export like build.sh packages a source
# distribution, then build the jar as the engine's CMake does (gen_version, ant dist-cubrid).
temurin=$(nixx build --no-link --print-out-paths "$repo#tool-temurin8")
ant=$(nixx build --no-link --print-out-paths "$repo#tool-ant")
cmake=$(nixx build --no-link --print-out-paths "$repo#tool-cmake")
export JAVA_HOME=$temurin PATH=$temurin/bin:$ant/bin:$cmake/bin:$PATH
"$repo/scripts/export-source.sh" "$ws" "$work/src"
jdbc=$work/src/cubrid-jdbc
cmake -DCUBRID_JDBC_SOURCE_DIR="$jdbc" -DCUBRID_JDBC_OUTPUT_DIR="$jdbc/output" -P "$jdbc/cmake/gen_version.cmake"
ant dist-cubrid -buildfile "$jdbc/build.xml"
mkdir -p "$work/pl-lib"
cp "$jdbc"/cubrid-jdbc-*.jar "$work/pl-lib/"

mkdir -p "$work/gradle"
(cd "$work/gradle" && unzip -q "$dist")
gradle=$(echo "$work"/gradle/gradle-*/bin/gradle)

# Java does not read http(s)_proxy; hand them to Gradle as system properties.
proxy=()
for scheme in http https; do
  v=$(printenv "${scheme}_proxy" || printenv "${scheme^^}_PROXY" || true)
  if [ -n "$v" ]; then
    hp=${v#*://}; hp=${hp%%/*}; hp=${hp##*@}
    proxy+=("-D$scheme.proxyHost=${hp%:*}" "-D$scheme.proxyPort=${hp##*:}")
  fi
done
np=$(printenv no_proxy || printenv NO_PROXY || true)
[ -z "$np" ] || proxy+=("-Dhttp.nonProxyHosts=${np//,/|}")

GRADLE_USER_HOME=$work/gradle-home "$gradle" --no-daemon "${proxy[@]}" \
  -Dorg.gradle.java.installations.auto-download=false \
  build -x test -p "$work/src/pl_engine" -PbuildDir="$work/pl-build" -PcubridJdbcPath="$work/pl-lib"

python3 - "$lock" "$work/gradle-home/caches/modules-2/files-2.1" <<'EOF'
import base64, hashlib, json, os, sys, urllib.request
lock, cache = sys.argv[1:]
repos = ["https://repo.maven.apache.org/maven2", "https://plugins.gradle.org/m2"]
d = json.load(open(lock))
have = {e["path"]: e for e in d["maven"]}
added = 0
for root, _, files in os.walk(cache):
    for f in files:
        full = os.path.join(root, f)
        group, artifact, version = os.path.relpath(full, cache).split(os.sep)[:3]
        path = "/".join(group.split(".") + [artifact, version, f])
        h = "sha256-" + base64.b64encode(hashlib.sha256(open(full, "rb").read()).digest()).decode()
        if path in have:
            if have[path]["hash"] != h:
                sys.exit("seal: %s differs from the lock" % path)
            continue
        for r in repos:
            try:
                urllib.request.urlopen(urllib.request.Request(r + "/" + path, method="HEAD"), timeout=60)
                url = r + "/" + path
                break
            except Exception:
                url = None
        if url is None:
            sys.exit("seal: no repository serves " + path)
        have[path] = {"path": path, "url": url, "hash": h}
        added += 1
d["maven"] = sorted(have.values(), key=lambda e: e["path"])
json.dump(d, open(lock, "w"), indent=2)
open(lock, "a").write("\n")
print("sealed maven files: %d added, %d total" % (added, len(d["maven"])), file=sys.stderr)
EOF
echo "seal: done; review and commit nix/sealed/lock.json (work dir: $work)"
