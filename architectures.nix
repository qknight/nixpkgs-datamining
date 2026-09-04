let
  nixpkgsPath = /home/nixos/nixpkgs;

  systems = [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ];

  pkgsFor = system:
    import nixpkgsPath {
      inherit system;
    };

  lib = (pkgsFor "x86_64-linux").lib;

  # One nixpkgs attribute path per line.
  packageList =
    builtins.filter
      (name: name != "")
      (lib.splitString "\n" (builtins.readFile ./rust-packages.txt));

  # Resolve an attribute path such as:
  #
  #   hello
  #   pythonPackages.foo
  #   rustPlatform.foo
  #
  getAttrPath = pkgs: path:
    builtins.foldl'
      (value: attr: value.${attr})
      pkgs
      (lib.splitString "." path);

  # Evaluate a package and return its meta.platforms.
  #
  # If evaluation fails or meta.platforms is missing, return [].
  getPlatforms = pkgs: name:
    let
      result = builtins.tryEval (getAttrPath pkgs name);
    in
      if result.success
      then result.value.meta.platforms or []
      else [];

  # Count packages supporting each architecture.
  stats =
    builtins.map
      (system:
        let
          pkgs = pkgsFor system;

          supported =
            builtins.map
              (name:
                builtins.elem system (getPlatforms pkgs name))
              packageList;

          count =
            builtins.length
              (builtins.filter (x: x) supported);
        in
        {
          inherit system count;
        })
      systems;

  # Determine which packages support all four architectures.
  allFour =
    builtins.filter
      (name:
        let
          pkgs = pkgsFor "x86_64-linux";
          platforms = getPlatforms pkgs name;
        in
          builtins.all
            (system: builtins.elem system platforms)
            systems)
      packageList;

in
{
  total = builtins.length packageList;

  inherit stats;

  allFour = builtins.length allFour;

  # Useful for detecting packages that failed evaluation.
  evaluationFailures =
    builtins.length (
      builtins.filter
        (name:
          let
            result =
              builtins.tryEval
                (getAttrPath (pkgsFor "x86_64-linux") name);
          in
            !result.success)
        packageList
    );
}