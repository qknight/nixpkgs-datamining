# Probe rustPlatform.buildRustPackage across nixpkgs revisions. A changed
# derivation path indicates a likely broad Rust package rebuild trigger.
#
# nix-instantiate --eval --strict rustPlatform.buildRustPackage-probe.nix
let
  pkgs = import /home/nixos/nixpkgs { system = "x86_64-linux"; };
in
(pkgs.rustPlatform.buildRustPackage {
  pname = "rust-platform-probe";
  version = "1";
  src = builtins.toFile "probe-source" "";
  cargoVendorDir = builtins.toFile "probe-vendor" "";
  doCheck = false;
  dontUnpack = true;
  dontBuild = true;
  dontInstall = true;
}).drvPath
