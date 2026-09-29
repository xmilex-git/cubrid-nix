#!/usr/bin/env bash
# Export a CUBRID worktree the way build.sh packages a source distribution (ADR 0001 D6):
# the tracked files of the repository and of every submodule, with uncommitted edits,
# and the full versions written where a checkout without .git reads them:
#   VERSION-DIST                     instead of VERSION               (engine)
#   cubrid-jdbc/output/VERSION-DIST  instead of cubrid-jdbc/VERSION   (JDBC)
#   cubrid-cci/CCI-VERSION-DIST      instead of cubrid-cci/BUILD_NUMBER (CCI)
# The serials count commits after the same dates build.sh and the CMake files use.
set -euo pipefail

usage="usage: export-source.sh <cubrid worktree> <dest dir>"
ws=$(cd "${1:?$usage}" && pwd)
dest=${2:?$usage}

serial() { # repo dir, date -> 4-digit number of commits after the date
  git -C "$1" rev-list --after "$2" --count HEAD | awk '{ printf "%04d", $1 }'
}
short() { git -C "$1" rev-parse --short=7 HEAD; }

# The CI checks out every submodule (its entrypoint runs `git submodule update --init`),
# cubridmanager included, so a build without one would not be the CI's build.
missing=$(git -C "$ws" submodule status | awk '/^-/ { print $2 }' | tr '\n' ' ')
if [ -n "$missing" ]; then
  echo "export-source: uninitialized submodules: $missing" >&2
  echo "  initialize them first: git -C $ws submodule update --init $missing" >&2
  exit 1
fi

rm -rf "$dest"
mkdir -p "$dest"
git -C "$ws" ls-files -z --recurse-submodules |
  tar -C "$ws" --null --ignore-failed-read -T - -cf - | tar -C "$dest" -xf -

printf '%s.%s-%s\n' "$(cat "$ws/VERSION")" "$(serial "$ws" 2019-12-12)" "$(short "$ws")" \
  > "$dest/VERSION-DIST"
rm -f "$dest/VERSION"

mkdir -p "$dest/cubrid-jdbc/output"
printf '%s.%s' "$(cat "$ws/cubrid-jdbc/VERSION")" "$(serial "$ws/cubrid-jdbc" 2021-03-30)" \
  > "$dest/cubrid-jdbc/output/VERSION-DIST"
rm -f "$dest/cubrid-jdbc/VERSION"

printf '%s.%s-%s\n' "$(cat "$ws/cubrid-cci/BUILD_NUMBER")" "$(serial "$ws/cubrid-cci" 2021-07-14)" \
  "$(short "$ws/cubrid-cci")" > "$dest/cubrid-cci/CCI-VERSION-DIST"
rm -f "$dest/cubrid-cci/BUILD_NUMBER"

echo "exported $ws -> $dest ($(cat "$dest/VERSION-DIST"))"
