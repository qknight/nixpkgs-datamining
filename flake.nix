{
  description = "Cosmos - Pflege des privaten Netzwerks (WSL2 ohne KVM)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixos-wsl.url = "github:nix-community/NixOS-WSL";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, nixos-wsl, rust-overlay }:

    let
      inherit (nixpkgs) lib;

      overlays = [
        (import rust-overlay)
      ];

      runtimeLibs = pkgs: with pkgs; [
        libGL
        vulkan-loader
        wayland
        libxkbcommon
        fontconfig
        freetype
        libx11
        libxcursor
        libxrandr
        libxi
      ];

      # Shared bwrap sandbox.
      #
      # Important:
      # - host / is NOT visible
      # - host /home is NOT visible
      # - only the project directory is RW-mounted
      # - OpenCode gets a private persistent home
      # - build artifacts get a separate persistent directory
      # - /nix is read-only
      # - OPENAI_API_KEY is explicitly passed through
      mkSandboxScript = pkgs: name:
        pkgs.writeShellScriptBin name ''
          set -euo pipefail

          BWRAP="${lib.getExe pkgs.bubblewrap}"
          BASH_BIN="${lib.getExe pkgs.bashInteractive}"

          PROJECT_DIR="''${PROJECT_DIR:-$PWD}"
          VM_HOME="''${VM_HOME:-$PROJECT_DIR/.wsl/home}"
          BUILD_DIR="''${BUILD_DIR:-$PROJECT_DIR/.wsl/build}"

          mkdir -p "$VM_HOME" "$BUILD_DIR"

          COSMOS_PATH='${lib.makeBinPath [
            pkgs.coreutils
            pkgs.git
            pkgs.opencode
            pkgs.bashInteractive
            pkgs.bubblewrap
          ]}'

          COSMOS_LIBS='${lib.makeLibraryPath (runtimeLibs pkgs)}'

          extra=()

          if [ -d /mnt/wslg ]; then
            extra+=(--ro-bind /mnt/wslg /mnt/wslg)
          fi

          if [ -d /tmp/.X11-unix ]; then
            extra+=(--bind /tmp/.X11-unix /tmp/.X11-unix)
          fi

          if [ -n "''${XDG_RUNTIME_DIR:-}" ] &&
             [ -d "''${XDG_RUNTIME_DIR}" ]; then
            extra+=(--bind "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR")
          fi

          # NixOS resolv.conf is usually a symlink into /etc/static or /run.
          for p in \
            /etc/resolv.conf \
            /etc/hosts \
            /etc/nsswitch.conf \
            /etc/ssl \
            /etc/static \
            /etc/pki
          do
            if [ -e "$p" ]; then
              extra+=(--ro-bind "$p" "$p")
            fi
          done

          echo "[sandbox] project(host)=$PROJECT_DIR -> /workspace" >&2
          echo "[sandbox] home(host)=$VM_HOME -> /home/dev" >&2
          echo "[sandbox] build(host)=$BUILD_DIR -> /build" >&2
          echo "[sandbox] host /home is NOT bound" >&2
          echo "[sandbox] OpenCode" >&2

          exec "$BWRAP" \
            --unshare-pid \
            --unshare-ipc \
            --unshare-uts \
            --unshare-user \
            --hostname cosmos-wsl \
            --die-with-parent \
            --tmpfs / \
            --proc /proc \
            --dev /dev \
            --tmpfs /tmp \
            --tmpfs /run \
            --ro-bind /nix /nix \
            --ro-bind-try /sys /sys \
            --dir /home \
            --dir /home/dev \
            --dir /workspace \
            --dir /build \
            --bind "$VM_HOME" /home/dev \
            --bind "$PROJECT_DIR" /workspace \
            --bind "$BUILD_DIR" /build \
            "''${extra[@]}" \
            --chdir /workspace \
            --clearenv \
            --setenv HOME /home/dev \
            --setenv USER dev \
            --setenv LOGNAME dev \
            --setenv SHELL "$BASH_BIN" \
            --setenv PATH "$COSMOS_PATH" \
            --setenv LD_LIBRARY_PATH "$COSMOS_LIBS" \
            --setenv DISPLAY "''${DISPLAY:-}" \
            --setenv WAYLAND_DISPLAY "''${WAYLAND_DISPLAY:-}" \
            --setenv XDG_RUNTIME_DIR "''${XDG_RUNTIME_DIR:-}" \
            --setenv TERM "''${TERM:-xterm-256color}" \
            --setenv LANG "''${LANG:-C.UTF-8}" \
            --setenv NIX_SSL_CERT_FILE /etc/ssl/certs/ca-bundle.crt \
            --setenv SSL_CERT_FILE /etc/ssl/certs/ca-bundle.crt \
            --setenv OPENAI_API_KEY "''${OPENAI_API_KEY:-}" \
            -- \
            "$BASH_BIN" -lc '
              mkdir -p "$HOME"

              echo
              echo "Cosmos sandbox"
              echo "  project : /workspace  (current dir, RW)"
              echo "  home    : /home/dev   (.wsl/home, not host \$HOME)"
              echo "  build   : /build      (.wsl/build)"
              echo "  agent   : OpenCode"
              echo "  API     : OpenAI API key passed through"
              echo "  exit    : leave sandbox"
              echo

              exec bash
            '
        '';

    in
      lib.recursiveUpdate

        (flake-utils.lib.eachDefaultSystem (system:
          let
            pkgs = import nixpkgs {
              inherit system overlays;
            };

            libs = runtimeLibs pkgs;

            sandboxScript =
              mkSandboxScript pkgs "cosmos-sandbox";

            developSandbox =
              mkSandboxScript pkgs "enter-sandbox";

          in
          {
            packages.sandbox = sandboxScript;
            packages.default = sandboxScript;

            devShells.default = pkgs.mkShell {
              buildInputs = libs ++ [
                pkgs.bubblewrap
                pkgs.opencode
                pkgs.git
                pkgs.bashInteractive
              ];

              shellHook = ''
                if [ -z "''${IN_DEV_BWRAP:-}" ]; then
                  export IN_DEV_BWRAP=1
                  exec ${developSandbox}/bin/enter-sandbox
                fi
              '';
            };
          }))

        {
          nixosConfigurations.cosmos-wsl =
            nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";

              modules = [
                nixos-wsl.nixosModules.wsl

                ({ pkgs, lib, ... }: {
                  system.stateVersion = lib.trivial.release;

                  wsl.enable = true;
                  wsl.defaultUser = "dev";

                  services.xserver.enable = false;

                  nixpkgs = {
                    inherit overlays;
                  };

                  users.users.dev = {
                    isNormalUser = true;
                    uid = 1000;
                    extraGroups = [ "wheel" ];
                  };

                  security.sudo.wheelNeedsPassword = false;

                  environment.systemPackages = with pkgs; [
                    opencode
                    bubblewrap
                    git
                  ];
                })
              ];
            };
        };
}
