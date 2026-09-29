# Wrappers over the CI toolchain snapshot (ADR 0001 D4). gcc always compiles against
# the snapshot's glibc and headers, and links outputs so that they load the snapshot's
# glibc through DT_RPATH, like the CI's runtime does with /lib64.
{ runCommand, bash, python3, snapshot }:

runCommand "cubrid-ci-toolchain" { passthru = { inherit snapshot; }; } ''
  s=${snapshot}
  mkdir -p $out/bin $out/lib $out/nix-support

  wrap() {
    local name=$1
    shift
    printf '#!${bash}/bin/bash\n%s\n' "$*" > $out/bin/$name
    chmod +x $out/bin/$name
  }

  # The link options go through a specs file so that they reach the linker only when
  # gcc links; as command-line -Wl options they would make `gcc -v` try a link.
  cat > $out/lib/cubrid-ci.specs <<EOF
  %rename link cubrid_ci_link

  *link:
  %(cubrid_ci_link) %{!static:%{!static-pie:--dynamic-linker=$s/lib64/ld-linux-x86-64.so.2}} --disable-new-dtags -rpath $s/lib64:$s/usr/lib64

  EOF

  # gcc finds cc1 and its libraries from argv[0], so the wrappers keep the real path there.
  for d in gcc:gcc cc:gcc g++:g++ c++:g++; do
    wrap "''${d%%:*}" "exec $s/usr/bin/''${d#*:} --sysroot=$s -B$s/usr/bin/ -specs=$out/lib/cubrid-ci.specs \"\$@\""
  done
  wrap cpp "exec $s/usr/bin/cpp --sysroot=$s \"\$@\""
  # flex runs m4 from a compiled-in /usr/bin/m4 unless M4 is set.
  wrap flex "M4=\''${M4:-$s/usr/bin/m4} exec $s/usr/bin/flex \"\$@\""
  # systemtap-sdt's dtrace is a python script; it calls the compiler above for -G.
  wrap dtrace "exec ${python3}/bin/python3 $s/usr/bin/dtrace \"\$@\""
  wrap iconv "GCONV_PATH=$s/usr/lib64/gconv exec $s/usr/bin/iconv \"\$@\""
  for t in as ld ld.bfd ar nm ranlib strip objcopy objdump readelf size strings \
           addr2line c++filt gcov gcc-ar gcc-nm gcc-ranlib m4; do
    ln -s $s/usr/bin/$t $out/bin/$t
  done

  # Paths for CUBRID processes (ADR 0001 D9). The locale and gconv paths are only for
  # programs on the snapshot's glibc 2.28; programs on another glibc must not read them.
  cat > $out/nix-support/snapshot-env <<EOF
  CUBRID_CI_SNAPSHOT=$s
  TZDIR=$s/usr/share/zoneinfo
  CUBRID_CI_LOCPATH=$s/usr/lib/locale
  CUBRID_CI_GCONV_PATH=$s/usr/lib64/gconv
  EOF
''
