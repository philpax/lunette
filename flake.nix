{
  description = "lunette, an XR window manager and Wayland compositor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # deps/joltc reaches JoltPhysics through FetchContent, which wants the
          # network at configure time. Prefetching it and pointing
          # FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS at the result is how the nixpkgs
          # lovr derivation builds offline, and lunette does the same.
          #
          # Placeholder revision: it is the one nixpkgs pins, not the one
          # vendor/lovr/deps/joltc declares. vendor/lovr does not exist yet; the
          # revision is corrected against its FetchContent_Declare block once the
          # submodule lands.
          joltPhysicsSrc = pkgs.fetchFromGitHub {
            owner = "jrouwe";
            repo = "JoltPhysics";
            rev = "c10d9b2a8ee134fb5e72de1a0f26f8c9cc8f6382";
            hash = "sha256-owI9uM/hjicuUWXYeZOhfYby5ygWm3JOO/qifRGiOdM=";
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
          # gcc14Stdenv matches the nixpkgs lovr derivation, which selects it for
          # better C++ support in LOVR's vendored dependencies.
          default = (pkgs.mkShell.override { stdenv = pkgs.gcc14Stdenv; }) {
            name = "lunette";

            nativeBuildInputs = with pkgs; [
              cmake
              pkg-config
              python3Minimal

              # Sets LIBCLANG_PATH and the include flags bindgen needs to parse
              # LOVR's headers.
              rustPlatform.bindgenHook

              # The toolchain comes from rustup rather than nixpkgs' rustc,
              # because CONTRIBUTING.md requires nightly rustfmt alongside the
              # stable compiler and `cargo +nightly` only works through rustup's
              # proxies.
              rustup
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

            SHADERC_LIB_DIR = "${nixpkgs.lib.getLib pkgs.shaderc}/lib";

            LD_LIBRARY_PATH = nixpkgs.lib.makeLibraryPath runtimeLibs;
          };
        }
      );
    };
}
