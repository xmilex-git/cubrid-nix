# Sealed inputs (ADR 0001 D7). The 3rdparty tarballs are read from the engine source
# being built, where their URL and SHA256 are pinned, so they follow the source. The
# bundled JDK, the Gradle distribution and pl_server's Maven artifacts have no hash in
# the source and come from nix/sealed/lock.json, which scripts/seal.sh extends.
{ lib, fetchurl, linkFarm, writeText, writeShellScript, python3 }:

let
  lock = lib.importJSON ./sealed/lock.json;

  lines = file: lib.splitString "\n" (builtins.readFile file);
  # the capture lists of the lines of `file` that `re` matches as a whole
  matches = re: file: lib.filter (m: m != null) (map (builtins.match re) (lines file));
  firstMatch = what: re: file:
    let ms = matches re file;
    in if ms == [ ] then throw "sealed inputs: cannot find ${what} in ${file}" else lib.head ms;

  sealedFile = what: url:
    if lock.files ? ${url} then
      fetchurl { inherit url; hash = lock.files.${url}; }
    else
      throw ''
        sealed input missing from nix/sealed/lock.json: ${what}
          ${url}
        record it with: scripts/seal.sh <cubrid worktree>   (ADR 0001 D7)'';

  mavenRepo = linkFarm "cubrid-sealed-maven"
    (map (e: { name = e.path; path = fetchurl { inherit (e) url hash; }; }) lock.maven);

  # pl_server asks for a Java 8 toolchain. With auto-detection off Gradle does not even
  # consider the JVM it runs on, so the toolchain is named explicitly: $JAVA_HOME.
  gradleProperties = writeText "gradle.properties" ''
    org.gradle.daemon=false
    org.gradle.java.installations.auto-download=false
    org.gradle.java.installations.auto-detect=false
    org.gradle.java.installations.fromEnv=JAVA_HOME
  '';

  # Leaves the sealed repository and the build's own file repositories (the flatDir of
  # the JDBC jar); removes remote repositories and ~/.m2.
  gradleInit = writeText "cubrid-sealed.gradle" ''
    def sealed = new File('${mavenRepo}').toURI()
    def isOpen = { r -> r.name == 'MavenLocal' || (r instanceof MavenArtifactRepository && r.url.scheme != 'file') }
    beforeSettings { settings ->
      settings.pluginManagement.repositories.clear()
      settings.pluginManagement.repositories.maven { url = sealed }
    }
    allprojects {
      afterEvaluate { p ->
        p.repositories.removeAll(p.repositories.findAll(isOpen))
        p.repositories.maven { url = sealed }
      }
    }
  '';

  # gradlew keeps a distribution in wrapper/dists/<name>/<base-36 MD5 of its URL>.
  gradleDistHash = writeShellScript "gradle-dist-hash" ''
    exec ${python3}/bin/python3 -c '
    import hashlib, sys
    n = int(hashlib.md5(sys.argv[1].encode()).hexdigest(), 16)
    s = ""
    while n:
        n, r = divmod(n, 36)
        s = "0123456789abcdefghijklmnopqrstuvwxyz"[r] + s
    print(s or "0")' "$1"
  '';
in
src:
let
  cmakeLists = "${src}/3rdparty/CMakeLists.txt";
  pairs = re: lib.listToAttrs
    (map (m: lib.nameValuePair (lib.elemAt m 0) (lib.elemAt m 1)) (matches re cmakeLists));
  urls = pairs "[[:space:]]*set\\(WITH_([A-Z0-9_]+)_URL[[:space:]]+\"([^\"]+)\"\\).*";
  hashes = pairs "[[:space:]]*set\\(WITH_([A-Z0-9_]+)_URL_HASH[[:space:]]+\"SHA256=([0-9a-fA-F]+)\"\\).*";
  targets = pairs "[[:space:]]*set\\(([A-Z0-9_]+)_TARGET[[:space:]]+([A-Za-z0-9_]+)\\).*";
  need = attrs: what: k:
    attrs.${k} or (throw "3rdparty/CMakeLists.txt: no ${what} for WITH_${k}_URL");

  thirdparty = lib.mapAttrsToList
    (k: url: {
      target = need targets "*_TARGET" k;
      file = baseNameOf url;
      tarball = fetchurl { inherit url; sha256 = need hashes "URL_HASH" k; };
    })
    urls;

  jdkUrl = lib.head (firstMatch "the Linux JDK_URL"
    "[[:space:]]*set\\(JDK_URL[[:space:]]+\"(https://[^\"]*linux[^\"]*)\"\\).*"
    "${src}/pl_engine/cmake/install_jdk.cmake");
  jdk = sealedFile "bundled JDK (pl_engine/cmake/install_jdk.cmake)" jdkUrl;

  distUrl = builtins.replaceStrings [ "\\:" ] [ ":" ] (lib.head (firstMatch "distributionUrl"
    "distributionUrl=(.*)" "${src}/pl_engine/gradle/wrapper/gradle-wrapper.properties"));
  distZip = baseNameOf distUrl;
  distName = lib.removeSuffix ".zip" distZip;
  gradleDist = sealedFile "Gradle distribution (pl_engine/gradle/wrapper)" distUrl;
in
{
  inherit thirdparty jdk gradleDist mavenRepo;

  # cubrid-seed <build dir> <gradle user home>: put every sealed input where the build
  # would otherwise download it. CMake skips a download whose file already matches.
  seed = writeShellScript "cubrid-seed" ''
    set -euo pipefail
    b=''${1:?usage: cubrid-seed <build dir> <gradle user home>}
    g=''${2:?usage: cubrid-seed <build dir> <gradle user home>}
    ${lib.concatMapStrings (t: ''
      mkdir -p "$b/3rdparty/Download/${t.target}"
      cp -f ${t.tarball} "$b/3rdparty/Download/${t.target}/${t.file}"
    '') thirdparty}
    mkdir -p "$b/vm"
    # install_jdk.cmake downloads the tarball whenever it is missing: keep it in place.
    [ -e "$b/vm/jdk8.tar.gz" ] || cp -f ${jdk} "$b/vm/jdk8.tar.gz"
    # CMake's FindJNI reads the JDK's headers at configure time, before the build
    # extracts the JDK: extract it like install_jdk.cmake does.
    if [ ! -e "$b/vm/jdk8" ]; then
      tar -xzf "$b/vm/jdk8.tar.gz" -C "$b/vm"
      mv "$b"/vm/jdk8u* "$b/vm/jdk8"
      rm -rf "$b/vm/jdk8/man" "$b/vm/jdk8/sample" "$b/vm/jdk8/src.zip"
    fi
    d="$g/wrapper/dists/${distName}/$(${gradleDistHash} '${distUrl}')"
    mkdir -p "$d" "$g/init.d"
    [ -e "$d/${distZip}" ] || cp -f ${gradleDist} "$d/${distZip}"
    cp -f ${gradleProperties} "$g/gradle.properties"
    cp -f ${gradleInit} "$g/init.d/cubrid-sealed.gradle"
    chmod -R u+w "$b/3rdparty/Download" "$b/vm" "$g"
  '';
}
