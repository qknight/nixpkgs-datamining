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

      mkSandboxScript = pkgs: name:
  let
    cosmosBashRc = pkgs.writeText "cosmos-bashrc" ''
      # Interactive niceties
      shopt -s checkwinsize
      shopt -s histappend

      # Bash completion (program + path)
      if [ -f ${pkgs.bash-completion}/etc/profile.d/bash_completion.sh ]; then
        source ${pkgs.bash-completion}/etc/profile.d/bash_completion.sh
      elif [ -f ${pkgs.bash-completion}/share/bash-completion/bash_completion ]; then
        source ${pkgs.bash-completion}/share/bash-completion/bash_completion
      fi

      # Git prompt support (branch only)
      if [ -f ${pkgs.git}/share/git/contrib/completion/git-prompt.sh ]; then
        source ${pkgs.git}/share/git/contrib/completion/git-prompt.sh
        # Ensure we only show the branch name (no dirty/stash/upstream glyphs)
        unset GIT_PS1_SHOWDIRTYSTATE GIT_PS1_SHOWSTASHSTATE GIT_PS1_SHOWUNTRACKEDFILES GIT_PS1_SHOWUPSTREAM
      fi

      # Colors
      c_reset='\[\e[0m\]'
      c_icon='\[\e[1;34m\]'     # bold blue
      c_userhost='\[\e[1;36m\]' # bold cyan
      c_path='\[\e[0;33m\]'     # yellow
      c_branch='\[\e[0;35m\]'   # magenta

      # Prompt builder
      __cosmos_prompt() {
        local host="$(hostname -s 2>/dev/null || hostname)"
        local git=
        if type -t __git_ps1 >/dev/null 2>&1; then
          git="$(__git_ps1 '%s')"
          [ -n "$git" ] && git="($git)"
        fi

        # Render path as ~/<project>... while HOME=/workspace
        local path_disp
        if [[ -n "''${COSMOS_PROJECT_NAME:-}" && "''${PWD}" == /workspace* ]]; then
          local rel="''${PWD#/workspace}"
          path_disp="~/"''${COSMOS_PROJECT_NAME}''${rel}
        else
          path_disp="''${PWD}"
        fi

        # Use $USER (env) instead of \u to avoid NSS lookup ("I have no name!")
        PS1="''${c_icon}🔒 ''${c_userhost}$USER@''${host} ''${c_path}''${path_disp} ''${c_branch}''${git}''${c_reset}> "
      }
      PROMPT_COMMAND="__cosmos_prompt"
    '';
  in
  pkgs.writeShellScriptBin name ''
    set -euo pipefail

    BWRAP="${lib.getExe pkgs.bubblewrap}"
    BASH_BIN="${lib.getExe pkgs.bashInteractive}"

    PROJECT_DIR="''${PROJECT_DIR:-$PWD}"
    PROJECT_NAME="$(basename "$PROJECT_DIR")"
    HOST_USER="$(id -un 2>/dev/null || echo dev)"
    HOST_NAME="$(hostname -s 2>/dev/null || echo cosmos-wsl)"

    COSMOS_PATH='${lib.makeBinPath [
      pkgs.coreutils
      pkgs.git
      pkgs.opencode
      pkgs.bashInteractive
      pkgs.bubblewrap
      pkgs.nix
      pkgs.inetutils
      pkgs.util-linux
    ]}'

    COSMOS_LIBS='${lib.makeLibraryPath (runtimeLibs pkgs)}'

    extra=()

    if [ -d /tmp/.X11-unix ]; then
      extra+=(--bind /tmp/.X11-unix /tmp/.X11-unix)
    fi

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
    echo "[sandbox] HOME -> /workspace (no separate persistent home/build)" >&2
    echo "[sandbox] host /home is NOT bound" >&2
    echo "[sandbox] WSLg NOT exposed (no /mnt/wslg)" >&2
    echo "[sandbox] XDG_RUNTIME_DIR NOT exposed (ssh/gpg agents hidden)" >&2
    echo "[sandbox] OpenCode" >&2

    exec "$BWRAP" \
      --unshare-pid \
      --unshare-ipc \
      --unshare-uts \
      --unshare-user \
      --hostname "$HOST_NAME" \
      --die-with-parent \
      --tmpfs / \
      --proc /proc \
      --dev /dev \
      --tmpfs /tmp \
      --tmpfs /run \
      --ro-bind /nix /nix \
      --ro-bind-try /sys /sys \
      --dir /workspace \
      --bind "$PROJECT_DIR" /workspace \
      "''${extra[@]}" \
      --chdir /workspace \
      --clearenv \
      --setenv HOME /workspace \
      --setenv USER "$HOST_USER" \
      --setenv LOGNAME "$HOST_USER" \
      --setenv SHELL "$BASH_BIN" \
      --setenv PATH "$COSMOS_PATH" \
      --setenv LD_LIBRARY_PATH "$COSMOS_LIBS" \
      --setenv DISPLAY "''${DISPLAY:-}" \
      --setenv WAYLAND_DISPLAY "''${WAYLAND_DISPLAY:-}" \
      --setenv SSH_AUTH_SOCK "" \
      --setenv GPG_AGENT_INFO "" \
      --setenv TERM "''${TERM:-xterm-256color}" \
      --setenv LANG "''${LANG:-C.UTF-8}" \
      --setenv LC_ALL "''${LANG:-C.UTF-8}" \
      --setenv LOCALE_ARCHIVE ${pkgs.glibcLocales}/lib/locale/locale-archive \
      --setenv FONTCONFIG_FILE ${pkgs.fontconfig.out}/etc/fonts/fonts.conf \
      --setenv FONTCONFIG_PATH ${pkgs.fontconfig.out}/etc/fonts \
      --setenv XDG_DATA_DIRS ${pkgs.fontconfig.out}/share:${pkgs.dejavu_fonts}/share:${pkgs.noto-fonts}/share:${pkgs.noto-fonts-color-emoji}/share:/usr/local/share:/usr/share \
      --setenv NIX_SSL_CERT_FILE /etc/ssl/certs/ca-bundle.crt \
      --setenv SSL_CERT_FILE /etc/ssl/certs/ca-bundle.crt \
      --setenv OPENAI_API_KEY "''${OPENAI_API_KEY:-}" \
      --setenv NIX_CONFIG "experimental-features = nix-command flakes" \
      --setenv COSMOS_PROJECT_NAME "$PROJECT_NAME" \
      -- \
      "$BASH_BIN" -lc '
        umask 077
        mkdir -p "$HOME"

        echo
        echo "Cosmos sandbox"
        echo "  project : /workspace  (current dir, RW)"
        echo "  home    : /workspace  (same as project dir)"
        echo "  agent   : OpenCode"
        echo "  API     : OpenAI API key passed through"
        echo "  WSLg    : not exposed"
        echo "  XDG_RT  : not exposed (ssh/gpg agents hidden)"
        echo "  exit    : leave sandbox"
        echo
          exec bash --rcfile '${cosmosBashRc}' -i
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
                pkgs.nix
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
                    nix
                  ];
                })
              ];
            };
        };
}
