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
          lavapipeIcd = "${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.${if system == "x86_64-linux" then "x86_64" else "aarch64"}.json";

          # deps/joltc reaches JoltPhysics through FetchContent, which wants the
          # network at configure time. Prefetching it and pointing
          # FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS at the result is how the nixpkgs
          # lovr derivation builds offline, and lunette does the same.
          #
          # The revision is the commit tag v5.5.0 names, which is what
          # vendor/lovr/deps/joltc/CMakeLists.txt:173 declares as its GIT_TAG.
          # It moves when the joltc submodule is bumped.
          joltPhysicsSrc = pkgs.fetchFromGitHub {
            owner = "jrouwe";
            repo = "JoltPhysics";
            rev = "23dadd0e603f1b321142d4c74df07fce85064989";
            hash = "sha256-OQ3kqpd0NBKA0e/YRNCKaSR0wKIto1mcZ+X93CuJ+Dc=";
          };

          # LOVR dlopens these rather than linking them, so rpath does not reach
          # them and LD_LIBRARY_PATH has to. libuuid is for the XR runtime
          # rather than LOVR: SteamVR's vrclient.so, which both the OpenXR and
          # OpenVR backends load, links it and fails to load without it.
          runtimeLibs = with pkgs; [
            libuuid
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

          # gcc14Stdenv matches the nixpkgs lovr derivation, which selects it for
          # better C++ support in LOVR's vendored dependencies.
          developmentShell = (pkgs.mkShell.override { stdenv = pkgs.gcc14Stdenv; }) {
            name = "lunette";

            nativeBuildInputs = with pkgs; [
              cmake
              pkg-config
              python3Minimal
              patchelf
              glslang

              # Sets LIBCLANG_PATH and the include flags bindgen needs to parse
              # LOVR's headers.
              rustPlatform.bindgenHook

              # The toolchain comes from rustup rather than nixpkgs' rustc,
              # because CONTRIBUTING.md requires nightly rustfmt alongside the
              # stable compiler and `cargo +nightly` only works through rustup's
              # proxies.
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

            SHADERC_LIB_DIR = "${nixpkgs.lib.getLib pkgs.shaderc}/lib";

            LD_LIBRARY_PATH = nixpkgs.lib.makeLibraryPath runtimeLibs;
          };
        in
        {
          default = developmentShell;
          graphics = developmentShell.overrideAttrs (_: {
            name = "lunette-graphics";
            # Select lavapipe without changing the default shell's hardware driver.
            VK_DRIVER_FILES = lavapipeIcd;
            VK_ICD_FILENAMES = lavapipeIcd;
          });
        }
      );
    };
}
