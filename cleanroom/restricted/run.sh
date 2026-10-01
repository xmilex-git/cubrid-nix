#!/usr/bin/env bash
# The restricted-cloud acceptance (ADR 0003): a container shaped like the Codex cloud.
# - Debian trixie with gcc/g++ 14.2, make and a Java 21 runtime; the user is uid 1000
# - no /nix, and / is not writable; the repositories live in /workspace/<name>
# - no user namespaces: a seccomp profile refuses unshare, setns and clone with
#   CLONE_NEWUSER
# - no core dumps: RLIMIT_CORE is 0, and /proc/sys/kernel/core_pattern cannot be read
#   (RESTRICTED_CORE_PATTERN=absent, the default, masks /proc/sys/kernel; =empty makes
#   the file read as empty)
# - PID 1 reaps nothing (sleep infinity, the steps run through podman exec): an orphan
#   that exits stays a zombie
# - four CPUs (RESTRICTED_CPUS, default 0-3), by affinity set inside (runc resets an
#   inherited one): this host's rootless cgroup v1 ignores --cpus and --memory
# - its own network namespace with outbound NAT, and no LAN cache: GitHub is the only
#   binary cache, unless RESTRICTED_LAN_CACHE names the LAN server
# Not emulated: the memory limit (inside.sh reports each step's peak RSS instead) and the
# disk size (measured).
#   run.sh [cubrid-testcases-private-ex checkout] [external core dir]
# The external core dir holds a core (core.*) and install-path, the store path of the
# install that wrote it. cubrid-nix is cloned from its committed HEAD. Results:
# .scratch/restricted/<name>/home/results/ (steps.tsv, a log per step). The exit status
# is inside.sh's: 1 when a step failed.
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

case "${RESTRICTED_CORE_PATTERN:-absent}" in
  absent) mask=/proc/sys/kernel ;;
  empty) mask=/proc/sys/kernel/core_pattern ;;
  *) echo "run.sh: RESTRICTED_CORE_PATTERN is absent or empty" >&2; exit 2 ;;
esac
mkdir -p "$base/workspace"
args=(-d --rm --cgroupns=private --http-proxy=false
      --userns=keep-id:uid=1000,gid=1000 --user 1000:1000
      --security-opt "seccomp=$base/seccomp.json"
      --security-opt "mask=$mask"
      --ulimit core=0:0
      -e HOME=/home/cloud -e "CUBRID_NIX_LAN_CACHE=${RESTRICTED_LAN_CACHE:-}" -w /home/cloud
      -v "$base/home:/home/cloud" -v "$base/workspace:/workspace"
      -v "$repo:/src/cubrid-nix:ro" -v "$repo/cleanroom/restricted:/restricted:ro")
[ -z "$tcex" ] || args+=(-v "$(readlink -f "$tcex"):/private-ex:ro")
[ -z "$coredir" ] || args+=(-v "$(readlink -f "$coredir"):/core:ro")
for v in ENGINE_REF TC_REF RESTRICTED_STEPS; do
  [ -z "${!v:-}" ] || args+=(-e "$v=${!v}")
done

name=cubrid-nix-restricted-$(basename "$base")
t0=$(date +%s)
podman run --name "$name" "${args[@]}" localhost/cubrid-nix-restricted:base sleep infinity > /dev/null
rc=0
podman exec "$name" taskset -c "${RESTRICTED_CPUS:-0-3}" bash /restricted/inside.sh \
  > "$base/inside.log" 2>&1 || rc=$?
podman rm -f -t 0 "$name" > /dev/null
printf 'total: %ds\nexit: %d\nresults: %s\n' $(( $(date +%s) - t0 )) "$rc" "$base/home/results" | tee "$base/summary.txt"
cat "$base/home/results/steps.tsv" 2>/dev/null || :
exit "$rc"
