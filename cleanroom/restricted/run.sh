#!/usr/bin/env bash
# The restricted-cloud acceptance (ADR 0003): a container shaped like the Codex cloud.
# - Debian trixie with gcc/g++ 14.2, make and a Java 21 runtime; the user is uid 1000
# - no /nix, and / is not writable
# - no user namespaces: a seccomp profile refuses unshare, setns and clone with a
#   namespace flag
# - no core dumps: RLIMIT_CORE is 0 and /proc/sys/kernel/core_pattern is masked
# - sixteen CPUs (RESTRICTED_CPUS, default 0-15), by affinity set inside (runc resets an
#   inherited one): this host's rootless cgroup v1 ignores --cpus and --memory
# Not limited: memory. inside.sh samples it and reports each step's peak, to compare
# with the target's 8 GiB.
# - its own network namespace with outbound NAT, and no LAN cache: GitHub is the only
#   binary cache, unless RESTRICTED_LAN_CACHE names the LAN server (a faster run that
#   leaves the GitHub path to another one)
# Not emulated: the disk size (measured instead).
#   run.sh [cubrid-testcases-private-ex checkout] [external core dir]
# The external core dir holds a core (core.*) and install-path, the store path of the
# install that wrote it. The repository is cloned from its committed HEAD. Results:
# .scratch/restricted/<time>/home/results/ (steps.tsv, a log per step).
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
tcex=${1:-}
coredir=${2:-}
base=$repo/.scratch/restricted/${CLEANROOM_HOME_NAME:-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$base/home"

podman build -q --network=host --http-proxy=false -t localhost/cubrid-nix-restricted:base \
  "$repo/cleanroom/restricted" > "$base/image.txt"

# podman's default profile, with the namespace calls refused
python3 - /usr/share/containers/seccomp.json "$base/seccomp.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
newuser = 0x10000000  # CLONE_NEWUSER; the other namespace flags need capabilities this user lacks
for r in d['syscalls']:
    r['names'] = [n for n in r['names'] if n not in ('unshare', 'setns', 'clone', 'clone3')]
d['syscalls'] = [r for r in d['syscalls'] if r['names']]
d['syscalls'] += [
    {'names': ['unshare', 'setns'], 'action': 'SCMP_ACT_ERRNO', 'errnoRet': 1},
    {'names': ['clone'], 'action': 'SCMP_ACT_ALLOW',
     'args': [{'index': 0, 'value': newuser, 'valueTwo': 0, 'op': 'SCMP_CMP_MASKED_EQ'}]},
    {'names': ['clone'], 'action': 'SCMP_ACT_ERRNO', 'errnoRet': 1,
     'args': [{'index': 0, 'value': newuser, 'valueTwo': newuser, 'op': 'SCMP_CMP_MASKED_EQ'}]},
    # glibc falls back to clone when clone3 is missing
    {'names': ['clone3'], 'action': 'SCMP_ACT_ERRNO', 'errnoRet': 38},
]
json.dump(d, open(sys.argv[2], 'w'), indent=1)
EOF

args=(--rm --cgroupns=private --http-proxy=false
      --userns=keep-id:uid=1000,gid=1000 --user 1000:1000
      --security-opt "seccomp=$base/seccomp.json"
      --security-opt mask=/proc/sys/kernel/core_pattern
      --ulimit core=0:0
      -e HOME=/home/cloud -e "CUBRID_NIX_LAN_CACHE=${RESTRICTED_LAN_CACHE:-}" -w /home/cloud
      -v "$base/home:/home/cloud" -v "$repo:/src/cubrid-nix:ro"
      -v "$repo/cleanroom/restricted:/restricted:ro")
[ -z "$tcex" ] || args+=(-v "$(readlink -f "$tcex"):/private-ex:ro")
[ -z "$coredir" ] || args+=(-v "$(readlink -f "$coredir"):/core:ro")
for v in ENGINE_REV TC_REF RESTRICTED_STEPS; do
  [ -z "${!v:-}" ] || args+=(-e "$v=${!v}")
done

t0=$(date +%s)
podman run "${args[@]}" localhost/cubrid-nix-restricted:base taskset -c "${RESTRICTED_CPUS:-0-15}" bash /restricted/inside.sh \
  > "$base/inside.log" 2>&1 || echo "inside.sh exited non-zero: $base/inside.log" >&2
printf 'total: %ds\nresults: %s\n' $(( $(date +%s) - t0 )) "$base/home/results" | tee "$base/summary.txt"
cat "$base/home/results/steps.tsv" 2>/dev/null || :
