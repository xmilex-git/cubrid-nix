# Fetch a pinned set of Rocky Linux RPMs (nix/rpms/*.json) by content hash.
# Each file is tried in the live tree first and in the vault second, so the set
# keeps resolving after the release moves to the vault (ADR 0001 D4).
{ lib, fetchurl }:

jsonFile:
let
  set = lib.importJSON jsonFile;
  urlsFor = e:
    let
      path = "${e.repo}/x86_64/os/Packages/${lib.toLower (builtins.substring 0 1 e.file)}/${e.file}";
    in
    [
      "https://dl.rockylinux.org/pub/rocky/${set.release}/${path}"
      "https://dl.rockylinux.org/vault/rocky/${set.release}/${path}"
    ];
in
map (e: fetchurl { name = e.file; urls = urlsFor e; inherit (e) hash; }) set.rpms
