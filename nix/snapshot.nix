# The CI toolchain snapshot (ADR 0001 D4, D9): the CI images' Rocky 8.10 RPMs
# unpacked into one tree that runs from the store on any Linux distribution.
{ lib, stdenvNoCC, rpm, cpio, patchelf, fetchRpms }:

let
  rpms = fetchRpms ./rpms/build-toolchain.json ++ fetchRpms ./rpms/runtime-data.json;
in
stdenvNoCC.mkDerivation {
  pname = "cubrid-ci-snapshot";
  version = "rocky8.10-gcc8.5.0-28-glibc2.28-251";

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  # These are the CI's binaries: only the explicit patchelf below may change them.
  dontFixup = true;

  nativeBuildInputs = [ rpm cpio patchelf ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/usr/bin $out/usr/sbin $out/usr/lib $out/usr/lib64
    # el8's filesystem RPM owns the usr-merge links; the loader is reached through lib64.
    ln -s usr/bin $out/bin
    ln -s usr/sbin $out/sbin
    ln -s usr/lib $out/lib
    ln -s usr/lib64 $out/lib64

    cd $out
    for r in ${lib.concatStringsSep " " rpms}; do
      rpm2cpio "$r" | cpio -idm --quiet --no-absolute-filenames
      # payload directories can be read-only and would block the next RPM
      chmod -R u+w $out
    done
    find $out -type f -perm /6000 -exec chmod ug-s {} +

    # binutils' %post creates ld through alternatives; the CI image resolves it to ld.bfd.
    ln -sfn ld.bfd $out/usr/bin/ld

    # Run from the store: the interpreter and DT_RPATH point into this tree. DT_RUNPATH
    # would not cover transitive dependencies, which then resolve from the host.
    find $out/usr/bin $out/usr/sbin $out/usr/libexec -type f -print0 |
      while IFS= read -r -d "" f; do
        if patchelf --print-interpreter "$f" >/dev/null 2>&1; then
          patchelf --set-interpreter $out/lib64/ld-linux-x86-64.so.2 \
                   --force-rpath --set-rpath $out/lib64:$out/usr/lib64 "$f"
        fi
      done

    runHook postInstall
  '';
}
