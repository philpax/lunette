<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/lockup-dark.svg">
    <img src="docs/assets/lockup-light.svg" alt="lunette" width="400">
  </picture>
</h1>

lunette is a scriptable XR workspace for Linux that can spawn Wayland applications, mirror your monitors, and more. It can run as an overlay or as its own independent application. It has native support for both PCVR and the Steam Frame. Everything user-facing is a Luau plugin. It's _your_ workspace.

The long-term goal is a completely standalone XR working environment that can be reshaped with code on the fly, from inside the headset. Remake your world. Choose your environment. Make it work for you.

It's still extremely early, and it doesn't live up to the dream yet, but the foundations are in place.

## What it is

lunette combines three things and mixes them into one great flavour:

- [LÖVR](https://lovr.org/)'s engine: XR support, rendering, spatial audio, physics, and the Lua runtime - anything you can do in a LÖVR project, you can do in lunette
- [WayVR](https://github.com/wayvr-org/wayvr)'s Wayland compositor and monitor capture, extracted and wired up to LÖVR
- [awesome](https://awesomewm.org/)'s philosophy: your configuration _is_ the environment, and your environment can be changed at runtime

The Rust core is as thin and as robust as possible. Everything else - including the entirety of the environment - is a hot-reloadable Luau plugin.

The plugin system is based on Cordis, from [A Programming Paradigm for Spatiotemporal Composability](https://arxiv.org/abs/2608.25512), as popularised by [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness). Everything a plugin does can be reversed, plugins can depend on each other, and they are designed to compose. The goal is a hypermodular ecosystem in which anything can be modified or swapped on the fly.

Configurations and plugins are written in typed Luau. `lunette check` type-checks them against generated definitions for LÖVR and lunette's own API. The same definitions enable editors to provide autocomplete and type errors as you write.

## Runtimes

lunette runs on Linux as an overlay through one of two backends:

- OpenXR, on a runtime that supports `XR_EXTX_overlay`, such as Monado
- OpenVR, as a native SteamVR overlay[^1]

[^1]: It doesn't seem like SteamVR will implement `XR_EXTX_overlay` any time soon, so an OpenVR backend was hacked into our LÖVR fork specifically for this. Kind of insane to do, to be honest.

## Building

lunette needs a Rust toolchain (through rustup), CMake, a C and C++ compiler, clang for bindgen, pkg-config, glslang, shaderc, and the development packages for Vulkan, Wayland, X11, xkbcommon, PipeWire, D-Bus, ALSA, OpenSSL, curl, and the OpenXR loader. [flake.nix](flake.nix) is the authoritative list. Clone recursively, as LÖVR's dependencies are nested submodules:

```sh
git clone --recursive https://github.com/philpax/lunette
cd lunette
make run       # build and start the development configuration
make install   # install to /usr/local, or set PREFIX
```

On Nix or NixOS, `nix develop` provides all of the above.

[Build and development](docs/development/build-and-development.md) covers the details. [Standard plugins](docs/development/standard-plugins.md) links plugin documentation and describes desktop composition. The [design specification](docs/development/overview.md) records mechanisms and contracts; [guides](docs/README.md) cover configurations and plugins.

## Credits

lunette owes a great deal to WayVR, who blazed the trail for Wayland compositing and monitor capture in XR. lunette's compositor is strongly derived from their work. [CREDITS.md](CREDITS.md) is a full accounting of the work we've reused.

## Licence

lunette is licensed under [GPL-3.0-only](LICENSE). Its LÖVR fork is MIT, matching upstream.

## See also

[Stardust XR](https://stardustxr.org/) solves many of the same problems, except clients are separate processes rather than plugins in one monolithic process. I've been - and still am - a long-time fan of their approach, but the approach taken by lunette has compelled me for years, and I had to find out how it'd work in practice.
