#!/usr/bin/env bash
# Make a run directory (CONTEXT.md): a writable $CUBRID over a read-only install.
# - every file of the install is a symlink in real, writable directories, so CUBRID and
#   CTP can add files (locale libraries, logs) next to them;
# - conf and databases are copies, because CUBRID and CTP edit and append to them;
# - bin's programs are wrappers that give CUBRID processes, and only them, the locale
#   and gconv data of the snapshot's glibc 2.28 (ADR 0001 D9): programs on another
#   glibc must not read those files.
# Prints the path of the env file to source.
set -euo pipefail

usage="usage: rundir.sh <install> <run dir>"
inst=$(readlink -f "${1:?$usage}")
run=${2:?$usage}
[ ! -e "$run" ] || { echo "rundir: $run already exists" >&2; exit 1; }
[ -x "$inst/bin/cub_server" ] || { echo "rundir: $inst is not a CUBRID install" >&2; exit 1; }

# The install's programs name the snapshot's loader; its data files sit next to it.
interp=$(readelf -l "$inst/bin/cub_server" | sed -n 's/.*program interpreter: \(.*\)]$/\1/p')
snap=${interp%/lib64/ld-linux-x86-64.so.2}
[ -d "$snap/usr/lib/locale" ] || { echo "rundir: no snapshot behind $interp" >&2; exit 1; }
bash=$(command -v bash)

mkdir -p "$(dirname "$run")"
cp -as "$inst/." "$run/"
chmod -R u+w "$run"
for d in conf databases; do
  if [ -d "$inst/$d" ]; then
    rm -rf "${run:?}/$d"
    cp -rL "$inst/$d" "$run/$d"
    chmod -R u+w "$run/$d"
  fi
done
mkdir -p "$run/databases" "$run/log" "$run/tmp" "$run/var"

for f in "$inst"/bin/*; do
  [ -f "$f" ] && [ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] || continue
  n=$(basename "$f")
  rm "$run/bin/$n"
  printf '#!%s\nexport LOCPATH=%s GCONV_PATH=%s\nexec -a "$0" %s "$@"\n' \
    "$bash" "$snap/usr/lib/locale" "$snap/usr/lib64/gconv" "$f" > "$run/bin/$n"
  chmod +x "$run/bin/$n"
done

cat > "$run/cubrid.env" <<EOF
export CUBRID=$run
export CUBRID_DATABASES=$run/databases
export PATH=$run/bin:\$PATH
export TZDIR=$snap/usr/share/zoneinfo
EOF
echo "$run/cubrid.env"
