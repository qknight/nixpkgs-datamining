# filter-rust.nix
{ pkgs ? import <nixpkgs> { config.allowUnfree = true; config.allowBroken = true; } }:

let
  lib = pkgs.lib;

  isBuildRustPackage = drv:
    let
      try = builtins.tryEval (
        lib.isDerivation drv
        && (
             (drv ? cargoHash   && drv.cargoHash   != null)
          || (drv ? cargoSha256 && drv.cargoSha256 != null)
          || (drv ? cargoDeps   && drv.cargoDeps   != null)
          || (drv ? cargoLock   && drv.cargoLock   != null)
          || (drv ? cargoVendorDir && drv.cargoVendorDir != null)
        )
      );
    in try.success && try.value;

in
  # Safely map over the attribute set – skip anything that throws
  lib.mapAttrs (name: value:
    let try = builtins.tryEval value;
    in if try.success && isBuildRustPackage try.value
       then try.value
       else null
  ) pkgs
