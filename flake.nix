{
  description = "Reproduce the CUBRID CI build and test environment with nix (ADR 0001)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    # The engine source by default (ADR 0001 D6). Real builds override it with a worktree
    # exported like a source distribution: `--override-input cubrid-src path:<dir>`
    # (scripts/export-source.sh), which also carries the version the CI would stamp.
    cubrid-src = {
      url = "git+https://github.com/CUBRID/cubrid.git?ref=develop&shallow=1&submodules=1";
      flake = false;
    };
    # CTP, pinned (ADR 0001 D8): the CI image takes testtools' develop at every run.
    cubrid-testtools = {
      url = "git+https://github.com/CUBRID/cubrid-testtools.git?ref=develop&shallow=1";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, cubrid-src, cubrid-testtools }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      fetchRpms = import ./nix/rpms.nix { inherit (pkgs) lib fetchurl; };
      snapshot = pkgs.callPackage ./nix/snapshot.nix { inherit fetchRpms; };
      toolchain = pkgs.callPackage ./nix/toolchain.nix { inherit snapshot; };
      # callPackage adds override functions to the set; keep the derivations only.
      tools = pkgs.lib.filterAttrs (_: pkgs.lib.isDerivation) (pkgs.callPackage ./nix/tools.nix { });
      sealedFor = src: pkgs.callPackage ./nix/sealed.nix { } src;
      cubridFor = pkgs.callPackage ./nix/cubrid.nix { inherit toolchain tools sealedFor; };

      # The seed script for a worktree on disk (the dev shell's incremental builds): only
      # the three files that declare the sealed inputs are read from it.
      sealedSeedFor = ws:
        let
          root = /. + ws;
          keep = [
            "3rdparty/CMakeLists.txt"
            "pl_engine/cmake/install_jdk.cmake"
            "pl_engine/gradle/wrapper/gradle-wrapper.properties"
          ];
          rel = p: pkgs.lib.removePrefix (toString root + "/") (toString p);
          src = builtins.path {
            path = root;
            name = "cubrid-sealed-declarations";
            filter = p: type:
              let r = rel p; in
              builtins.elem r keep
              || (type == "directory" && builtins.any (k: pkgs.lib.hasPrefix (r + "/") k) keep);
          };
        in
        (sealedFor src).seed;

      # fsync without a volatile overlay (ADR 0001 D8): built against the snapshot's
      # glibc 2.28 so that it loads into CUBRID's processes and nix programs alike.
      eatmydata = pkgs.stdenvNoCC.mkDerivation {
        pname = "libeatmydata-ci";
        inherit (pkgs.libeatmydata) version src;
        nativeBuildInputs = [ toolchain pkgs.autoreconfHook ];
        preConfigure = "export CC=gcc";
      };

      # Locales for CTP's own tools (nixpkgs' glibc): the shard's LANG and LC_ALL.
      ctpLocales = pkgs.glibcLocales.override {
        allLocales = false;
        locales = [ "en_US.UTF-8/UTF-8" "en_US/ISO-8859-1" "ko_KR.UTF-8/UTF-8" "ko_KR.EUC-KR/EUC-KR" ];
      };

      # gdb reads CUBRID's threads through the libthread_db of the snapshot's glibc 2.28.
      gdb = pkgs.writeShellScriptBin "gdb" ''
        exec ${pkgs.gdb}/bin/gdb -iex 'set libthread-db-search-path ${snapshot}/usr/lib64:$pdir' "$@"
      '';
    in
    {
      lib.${system} = {
        inherit sealedFor sealedSeedFor;
        ctpHome = "${cubrid-testtools}/CTP";
      };

      # Incremental builds and the recipes (ADR 0001 D3, D5, D10). No nixpkgs compiler
      # wrapper: gcc is the CI toolchain's.
      devShells.${system}.default = pkgs.mkShellNoCC {
        name = "cubrid-nix";
        packages = [ toolchain gdb pkgs.linuxPackages.perf ]
          ++ builtins.attrValues tools
          ++ (with pkgs; [ python3 which file just curl unzip ])
          # what CTP and the shard runner call (ADR 0001 D8: nixpkgs' versions)
          ++ (with pkgs; [ procps iproute2 util-linux lsof bc nettools rsync zip gnutar gzip ]);
        shellHook = ''
          export JAVA_HOME=${tools.temurin8}
          export M4=${snapshot}/usr/bin/m4
          export CC="ccache gcc" CXX="ccache g++" CCACHE_COMPILERCHECK=content
          export CCACHE_DIR=''${CCACHE_DIR:-$HOME/.cache/ccache}
          # a Gradle home of its own: the seed puts the sealed repository in its init.d
          export GRADLE_USER_HOME=''${CUBRID_NIX_GRADLE_HOME:-$HOME/.cache/cubrid-nix/gradle-home}
          export TZDIR=${snapshot}/usr/share/zoneinfo
          export LOCALE_ARCHIVE=${ctpLocales}/lib/locale/locale-archive
          # for ctp/ctp_run.sh
          export CUBRID_NIX_CTP=${cubrid-testtools}/CTP
          export CUBRID_NIX_CTP_REV=${cubrid-testtools.shortRev or "unknown"}
          export CUBRID_NIX_NIXPKGS_REV=${nixpkgs.shortRev or "unknown"}
          export CUBRID_NIX_EATMYDATA=${eatmydata}/lib/libeatmydata.so
          mkdir -p "$CCACHE_DIR" "$GRADLE_USER_HOME"
        '';
      };

      packages.${system} =
        pkgs.lib.mapAttrs' (n: v: pkgs.lib.nameValuePair "tool-${n}" v) tools
        // {
          ci-snapshot = snapshot;
          ci-toolchain = toolchain;
          ci-tools = pkgs.symlinkJoin {
            name = "cubrid-ci-tools";
            paths = builtins.attrValues tools;
          };
          inherit eatmydata;
          cubrid-optdebug = cubridFor { src = cubrid-src; mode = "optdebug"; };
          cubrid-release = cubridFor { src = cubrid-src; mode = "release"; };
          default = toolchain;
        };
    };
}
