# The CUBRID build (ADR 0001 D3, D6): `build.sh -m <mode> build`, as the CI's
# `/entrypoint.sh build` runs it, on a source exported like a source distribution
# (scripts/export-source.sh), with the CI toolchain snapshot, the CI-version tools and
# the sealed inputs. The sandbox has no network: anything not sealed fails the build.
{ lib
, stdenvNoCC
, python3
, which
, file
, toolchain
, tools
, sealedFor
}:

{ src, mode }:

let
  ccacheDir = "${dirOf builtins.storeDir}/var/cache/ccache";
  sealed = sealedFor src;
  snapshot = toolchain.snapshot;
  # An exported source carries VERSION-DIST; any other source gets what build.sh stamps
  # without .git (see postPatch).
  version =
    if builtins.pathExists "${src}/VERSION-DIST" then lib.fileContents "${src}/VERSION-DIST"
    else "${lib.fileContents "${src}/VERSION"}.0000-unknown";
  buildDir = "build_x86_64_${mode}";
in
stdenvNoCC.mkDerivation {
  pname = "cubrid-${mode}";
  inherit version src;

  nativeBuildInputs = [
    toolchain
    tools.cmake
    tools.ninja
    tools.make
    tools.bison
    tools.perl
    tools.ant
    tools.temurin8
    tools.ccache
    tools.git
    python3
    which
    file
  ];

  # A source that was not exported (the default flake input) has no .git and no
  # VERSION-DIST files: stamp the versions build.sh and the CMake files fall back to.
  postPatch = ''
    if [ ! -e VERSION-DIST ]; then
      echo "$(cat VERSION).0000-unknown" > VERSION-DIST && rm VERSION
    fi
    if [ ! -e cubrid-jdbc/output/VERSION-DIST ]; then
      mkdir -p cubrid-jdbc/output
      printf '%s.0000' "$(cat cubrid-jdbc/VERSION)" > cubrid-jdbc/output/VERSION-DIST && rm cubrid-jdbc/VERSION
    fi
    if [ ! -e cubrid-cci/CCI-VERSION-DIST ]; then
      echo "$(cat cubrid-cci/BUILD_NUMBER).0000-unknown" > cubrid-cci/CCI-VERSION-DIST && rm cubrid-cci/BUILD_NUMBER
    fi
    # dlmalloc includes the system header by absolute path, which --sysroot does not
    # reach; the same header, glibc 2.28's, comes from the snapshot through <malloc.h>.
    substituteInPlace src/heaplayers/malloc_2_8_3.c \
      --replace-fail '#include "/usr/include/malloc.h"' '#include <malloc.h>'
  '';

  dontConfigure = true;
  # The install is the CI's build output: no strip (perf and gdb need the symbols,
  # ADR 0001 D10), no shebang rewriting of installed scripts, no rpath shrinking.
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR/home GRADLE_USER_HOME=$TMPDIR/gradle-home
    mkdir -p "$HOME" "$GRADLE_USER_HOME"
    export JAVA_HOME=${tools.temurin8}
    # bison and flex run the CI's m4
    export M4=${snapshot}/usr/bin/m4
    # the CI image sets these; ccache runs only where the build sees a writable cache dir
    # next to the store: <store parent>/var/cache/ccache (/nix/var/cache/ccache for /nix)
    export CC="ccache gcc" CXX="ccache g++" CCACHE_COMPILERCHECK=content
    if [ -d ${ccacheDir} ] && [ -w ${ccacheDir} ]; then
      export CCACHE_DIR=${ccacheDir}
    else
      export CCACHE_DISABLE=1
    fi
    export CMAKE_BUILD_PARALLEL_LEVEL=$NIX_BUILD_CORES

    # Sources unpacked during the build (OpenSSL's Configure, ...) start with
    # #!/usr/bin/env, which the sandbox lacks; its root belongs to the build user. Without
    # a sandbox the host has one.
    [ -e /usr/bin/env ] || { mkdir -p /usr/bin && ln -s "$(type -P env)" /usr/bin/env; }

    ${sealed.seed} "$PWD/${buildDir}" "$GRADLE_USER_HOME"
    bash ./build.sh -m ${mode} -p $out build

    runHook postBuild
  '';

  # build.sh has installed into $out. The bundled JDK stays as the CI's install has it:
  # the Temurin tarball's files, loaded in-process by cub_pl (libjvm.so) and never run.
  dontInstall = true;

  passthru = { inherit mode sealed; };
}
