{
  description = "lunette, an XR window manager and Wayland compositor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      # x86_64-linux only: bindgen names the x86_64 varargs type differently from
      # aarch64, and the generated Rust FFI currently depends on that name.

      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Prefetch JoltPhysics because joltc's FetchContent step otherwise needs
          # network access during configuration. Keep the revision aligned with joltc's
          # declared GIT_TAG.

          joltPhysicsSrc = pkgs.fetchFromGitHub {
            owner = "jrouwe";
            repo = "JoltPhysics";
            rev = "23dadd0e603f1b321142d4c74df07fce85064989";
            hash = "sha256-OQ3kqpd0NBKA0e/YRNCKaSR0wKIto1mcZ+X93CuJ+Dc=";
          };

          # LOVR dlopens these rather than linking them, so rpath does not reach
          # them and LD_LIBRARY_PATH has to.
          runtimeLibs = with pkgs; [
            vulkan-loader
            libGL
            libx11
            libxcb
            alsa-lib
            libpulseaudio
            curl
            openxr-loader
            wayland
          ];
        in
        {
          # Match the gcc14 environment used by the nixpkgs LÖVR derivation.
          default = (pkgs.mkShell.override { stdenv = pkgs.gcc14Stdenv; }) {
            name = "lunette";

            nativeBuildInputs = with pkgs; [
              cmake
              pkg-config
              python3Minimal

              # Bindgen needs the clang environment.
              rustPlatform.bindgenHook

              # Use rustup because the project requires nightly rustfmt alongside
              # the stable compiler.
              rustup

              # Formats the Luau tree, as `make check` requires.
              stylua
            ];

            buildInputs = with pkgs; [
              # LOVR.
              libx11
              libxrandr
              libxinerama
              libxcursor
              libxi
              libxcb
              libxext
              libxkbcommon
              vulkan-headers
              vulkan-loader
              libGL
              curl

              # WayVR's compositor and capture stack.
              alsa-lib
              dbus
              openssl
              openxr-loader
              pipewire

              # The compositor crate, from Phase 2 onward.
              wayland
              wayland-protocols
            ];

            LUNETTE_JOLTPHYSICS_SRC = joltPhysicsSrc;

            # Use the repository's Lua standard library and configuration while developing.
            # Anchor both paths at the repository root so the shell works from any
            # directory; an explicit `--config-path` still takes precedence.

            shellHook = ''
              lunetteRoot="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
              export LUNETTE_STDLIB_PATH="$lunetteRoot/lua"
              export LUNETTE_CONFIG_PATH="$lunetteRoot/etc/xdg/lunette"
            '';

            SHADERC_LIB_DIR = "${nixpkgs.lib.getLib pkgs.shaderc}/lib";

            LD_LIBRARY_PATH = nixpkgs.lib.makeLibraryPath runtimeLibs;
          };
        }
      );
    };
}
