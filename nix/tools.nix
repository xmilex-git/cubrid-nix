# Build tools at the CI build image's versions (ADR 0001 D5). They run as separate
# processes on nixpkgs' glibc; everything that reaches the product comes from the
# CI toolchain snapshot instead (nix/snapshot.nix, nix/toolchain.nix).
{ lib
, stdenv
, stdenvNoCC
, fetchurl
, autoPatchelfHook
, unzip
, bash
, m4
, zlib
, libxcrypt
, gnumake42
, gitMinimal
, curlMinimal
, ccache
, buildPackages
}:

let
  # The CI's JAVA_HOME (/opt/jdk8). Headless: the GUI and sound libraries of the
  # JDK stay unresolved, nothing in the build or in CTP opens a window.
  temurin8 = stdenv.mkDerivation {
    pname = "temurin-jdk";
    version = "8u442-b06";
    src = fetchurl {
      url = "https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u442-b06/OpenJDK8U-jdk_x64_linux_hotspot_8u442b06.tar.gz";
      hash = "sha256-WwoBRed5BVKpyHZ7RoAHTEYo7CduW7J4th2Fz5D6yvo=";
    };
    nativeBuildInputs = [ autoPatchelfHook ];
    buildInputs = [ zlib stdenv.cc.cc.lib ];
    autoPatchelfIgnoreMissingDeps = [ "*" ];
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a . $out/
      runHook postInstall
    '';
  };

  # Kitware's release binary of the CI's cmake version.
  cmake = stdenv.mkDerivation {
    pname = "cmake";
    version = "3.26.5";
    src = fetchurl {
      url = "https://github.com/Kitware/CMake/releases/download/v3.26.5/cmake-3.26.5-linux-x86_64.tar.gz";
      hash = "sha256-EwlBrj/+Sp7jOVUUeHEVonOo0c4Vy5cUlLtF9+WLs8M=";
    };
    nativeBuildInputs = [ autoPatchelfHook ];
    buildInputs = [ stdenv.cc.cc.lib ];
    installPhase = ''
      runHook preInstall
      rm -f bin/cmake-gui
      mkdir -p $out
      cp -a bin share $out/
      runHook postInstall
    '';
  };

  ninja = stdenv.mkDerivation {
    pname = "ninja";
    version = "1.11.1";
    src = fetchurl {
      url = "https://github.com/ninja-build/ninja/releases/download/v1.11.1/ninja-linux.zip";
      hash = "sha256-uQG6luSG3ON3+aBw7U7z953rRfT/4pOPjn3cac+z33c=";
    };
    nativeBuildInputs = [ unzip autoPatchelfHook ];
    buildInputs = [ stdenv.cc.cc.lib ];
    sourceRoot = ".";
    installPhase = ''
      runHook preInstall
      install -Dm755 ninja $out/bin/ninja
      runHook postInstall
    '';
  };

  # The CI builds bison 3.0.5 from the GNU tarball as well. m4 is found at run time
  # through $M4; the build environment points it at the snapshot's m4 1.4.18.
  bison = stdenv.mkDerivation {
    pname = "bison";
    version = "3.0.5";
    src = fetchurl {
      url = "https://ftp.gnu.org/gnu/bison/bison-3.0.5.tar.xz";
      hash = "sha256-B1zvLoFGQuMOEOgVXpMCLkqRyjimWqHVRn1Olp+X8zg=";
    };
    nativeBuildInputs = [ m4 buildPackages.perl ];
    enableParallelBuilding = true;
    doCheck = false;
  };

  # OpenSSL's Configure needs perl with Time::Piece; both are in perl's core.
  perl = stdenv.mkDerivation {
    pname = "perl";
    version = "5.26.3";
    src = fetchurl {
      url = "https://www.cpan.org/src/5.0/perl-5.26.3.tar.gz";
      hash = "sha256-t1rkDegpL6UwIbNes1UvyvZdeJHOTFtmaNZlywIzxJM=";
    };
    buildInputs = [ libxcrypt ];
    postPatch = ''
      # Configure's `case "$gccversion" in 1*)` also matches gcc 10..13: it adds
      # -fpcc-struct-return and leaves out -fno-strict-aliasing, and miniperl then
      # crashes (miscompiled at -O2). Match gcc 1.x only.
      sed -i -e '/case "\$gccversion" in$/{n;s/^\([[:space:]]*\)1\*)/\1[1].*)/}' Configure
      # Cwd.pm looks for /bin/pwd, which the build sandbox lacks; its PATH fallback
      # runs with PATH cleared ("Can't figure out your cwd!" in cpan/Encode).
      substituteInPlace dist/PathTools/Cwd.pm --replace-fail "/bin/pwd" "$(type -P pwd)"
    '';
    configurePhase = ''
      runHook preConfigure
      sh ./Configure -des -Dprefix=$out -Dman1dir=none -Dman3dir=none -Dcc=cc \
        -Dlocincpth="${lib.getDev stdenv.cc.libc}/include ${libxcrypt}/include" \
        -Dloclibpth="${lib.getLib libxcrypt}/lib" \
        -Dlibpth="${lib.getLib stdenv.cc.libc}/lib ${lib.getLib libxcrypt}/lib" \
        -Dglibpth="${lib.getLib stdenv.cc.libc}/lib" \
        -Uinstallusrbinperl -Accflags=-fcommon
      runHook postConfigure
    '';
    doCheck = false;
  };

  # The JDBC build uses core tasks only (javac, jar, javadoc, copy, ...), so the two
  # jars of the Ant 1.10.9 release are the whole tool.
  antJar = fetchurl {
    url = "https://repo1.maven.org/maven2/org/apache/ant/ant/1.10.9/ant-1.10.9.jar";
    hash = "sha256-BxVHivWF6oChiYVhPr7Nx5IhItRbLDyXD/mzUs3bdfw=";
  };
  antLauncherJar = fetchurl {
    url = "https://repo1.maven.org/maven2/org/apache/ant/ant-launcher/1.10.9/ant-launcher-1.10.9.jar";
    hash = "sha256-/M6JH1fzvnIUn/lqwqgFdBZbPgg5hmuV0kUo8wJ9UME=";
  };
  ant = stdenvNoCC.mkDerivation {
    pname = "ant";
    version = "1.10.9";
    dontUnpack = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/share/ant/lib $out/bin
      cp ${antJar} $out/share/ant/lib/ant.jar
      cp ${antLauncherJar} $out/share/ant/lib/ant-launcher.jar
      cat > $out/bin/ant <<EOF
      #!${bash}/bin/bash
      : "\''${JAVA_HOME:=${temurin8}}"
      exec "\$JAVA_HOME/bin/java" \$ANT_OPTS -classpath $out/share/ant/lib/ant-launcher.jar \
        -Dant.home=$out/share/ant -Dant.library.dir=$out/share/ant/lib \
        org.apache.tools.ant.launch.Launcher "\$@"
      EOF
      chmod +x $out/bin/ant
      runHook postInstall
    '';
  };

  git = (gitMinimal.override { curl = curlMinimal; }).overrideAttrs (_: {
    version = "2.43.7";
    src = fetchurl {
      url = "https://www.kernel.org/pub/software/scm/git/git-2.43.7.tar.xz";
      hash = "sha256-ZX4jdEVdnmL2zbPnxV2Ge221QE10TpfhEsxbDbaHoZ8=";
    };
    doInstallCheck = false;
  });

  # GNU indent 2.2.11 from the tarball CUBRID's code-style check builds (2.2.12
  # formats differently). Only the program is built; the manual needs texi2html.
  indent = stdenv.mkDerivation {
    pname = "indent";
    version = "2.2.11";
    src = fetchurl {
      url = "https://github.com/CUBRID/3rdparty/raw/develop/indent/indent-2.2.11.tar.gz";
      hash = "sha256-qv9gzk0lXvuYXw63jMpNGtdmxuBRZmBzBQZWtnU6CJM=";
    };
    env.NIX_CFLAGS_COMPILE = "-fcommon";
    __structuredAttrs = true;
    makeFlags = [ "SUBDIRS=intl src" ];
    installFlags = [ "SUBDIRS=intl src" ];
  };

  astyle = stdenv.mkDerivation {
    pname = "astyle";
    version = "3.1";
    src = fetchurl {
      name = "astyle_3.1_linux.tar.gz";
      url = "https://sourceforge.net/projects/astyle/files/astyle/astyle%203.1/astyle_3.1_linux.tar.gz/download";
      hash = "sha256-y8xM+ZYpRTS7VvAl1vGZ6/3oGqTCccy9XuHBoxknRdc=";
    };
    sourceRoot = "astyle/build/gcc";
    makeFlags = [ "release" ];
    enableParallelBuilding = true;
    installPhase = ''
      runHook preInstall
      install -Dm755 bin/astyle $out/bin/astyle
      runHook postInstall
    '';
  };

  googleJavaFormatJar = fetchurl {
    url = "https://github.com/CUBRID/3rdparty/raw/develop/google-java-format/google-java-format-1.7-all-deps.jar";
    hash = "sha256-CJTuAgGe6LSs1t8J+1C6xHLnGZ4aXwQfjaWNCHMGlKo=";
  };
  google-java-format = stdenvNoCC.mkDerivation {
    pname = "google-java-format";
    version = "1.7";
    dontUnpack = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      printf '#!${bash}/bin/bash\nexec ${temurin8}/bin/java -jar ${googleJavaFormatJar} "$@"\n' > $out/bin/google-java-format
      chmod +x $out/bin/google-java-format
      runHook postInstall
    '';
  };
in
{
  inherit temurin8 cmake ninja bison perl ant git indent astyle google-java-format;
  # without the manual (asciidoctor needs Ruby, whose JIT needs Rust and LLVM), so without
  # its man output, and without the tests
  ccache = (ccache.override { asciidoctor = null; }).overrideAttrs (_: { doCheck = false; outputs = [ "out" ]; });
  make = gnumake42;
}
