# extract-one.nix
{ nixpkgsPath ? /home/nixos/nixpkgs
, attr
}:

let
  pkgs = import nixpkgsPath {
    config.allowUnfree = true;
    config.allowBroken = true;
  };

  original = pkgs.${attr};

  # Safe filename computed in Nix
  safeName = builtins.replaceStrings ["/"] ["_"] attr;

  extractor = original.overrideAttrs (old: {
    dontBuild = false;
    doCheck   = false;
    doInstall = false;

    buildPhase = ''
      runHook preBuild

      echo "=== Cargo.lock extractor for ${attr} ==="
      mkdir -p $out



      if [ -f Cargo.lock ]; then
        printf '\033[32m%s\033[0m\n' "Found Cargo.lock in $PWD"
        cargo build --unit-graph -Z unstable-options > $out/unit-graph
        cp -v Cargo.toml $out/Cargo.toml
        cp -v Cargo.lock $out/Cargo.lock
      elif [ -f "$cargoRoot/Cargo.lock" ]; then
        printf '\033[32m%s\033[0m\n' "Found Cargo.lock in cargoRoot"
        cargo build --unit-graph -Z unstable-options > $out/unit-graph
        cp -v "$cargoRoot/Cargo.toml" $out/Cargo.toml
        cp -v "$cargoRoot/Cargo.lock" $out/Cargo.lock
      else
        printf '\033[31m%s\033[0m\n' "ERROR: Cargo.lock not found" >&2
        find . -name 'Cargo.lock' || true
        exit 1
      fi

      echo "Lock file extracted – exiting early"
      exit 0

      runHook postBuild
    '';
  });

in
  extractor
