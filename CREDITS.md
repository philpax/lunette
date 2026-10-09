# Credits

lunette is built on other people's work. This file records whose, under what licence, and how each project is used. It is the one place these facts are recorded.

lunette is GPL-3.0-only. That follows from WayVR: lunette uses WayVR's code, WayVR is GPL-3.0-only, and no other outcome is available.

## WayVR

<https://github.com/wayvr-org/wayvr>, GPL-3.0-only, by galister and oo8dev. Previously WlxOverlay-S.

lunette's Wayland compositor is a port of WayVR's `backend/wayvr`, carried in `crates/lunette-compositor`. Host monitor capture and input injection come from WayVR's `wlx-capture` and its `HidProvider` design. Provenance for the ported files, including the upstream commit each was taken at, is recorded in [crates/lunette-compositor/PROVENANCE.md](crates/lunette-compositor/PROVENANCE.md).

That contribution is not incidental. galister and WayVR's contributors solved capture across every Linux compositor, worked out which OpenXR extensions function on which runtime, and found the Monado input-blocking mechanism. lunette depends on all three.

WayVR's `wayvr-ipc` crate is MIT rather than GPL-3.0-only. lunette does not use it: its control surface is `lunctl` over its own socket.

## wlx-capture

<https://github.com/galister/wlx-capture>, GPL-3.0-only, by galister.

Host desktop capture: PipeWire through the xdg-desktop-portal ScreenCast interface, the wlroots screencopy and dmabuf protocols, and X11 shared memory. lunette takes it as a git-pinned dependency rather than a vendored copy, and fixes to it go upstream. Live development happens inside the WayVR monorepo, so the pin points there rather than at the standalone repository.

## LÖVR

<https://github.com/bjornbytes/lovr>, MIT, by Bjorn Swenson and LÖVR contributors.

lunette dynamically links a fork of LÖVR, carried as the `vendor/lovr` submodule, and uses it for rendering, the selected headset backend and session, spatialised audio, and the Lua runtime.

Patches under `vendor/lovr` are MIT, matching upstream, not GPL-3.0-only. Relicensing them would make them unmergeable by the project they are written for. The default patch rule is narrow and additive, with each patch shaped as an upstream pull request. The internal OpenVR backend is a deliberate exception in scope; it preserves LÖVR session ownership and existing OpenXR behavior and defaults. The set and its exceptions are recorded in [docs/dev/lovr-integration.md](docs/dev/lovr-integration.md#the-patch-set).

## Space Mono

Space Mono is copyright 2016 The Space Mono Project Authors (<https://github.com/googlefonts/spacemono>). The bundled font is licensed under the SIL Open Font License, Version 1.1. The licence is preserved in `lua/lunette-plugins/theme/fonts/OFL.txt`.

`lua/lunette-plugins/theme/fonts/SpaceMono-Regular.ttf` and its licence are unmodified copies from the official `google/fonts` repository at revision `8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5`. The pinned upstream files are [SpaceMono-Regular.ttf](https://raw.githubusercontent.com/google/fonts/8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/ofl/spacemono/SpaceMono-Regular.ttf) and [OFL.txt](https://raw.githubusercontent.com/google/fonts/8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/ofl/spacemono/OFL.txt).

| File | Git blob | SHA256 |
|---|---|---|
| `SpaceMono-Regular.ttf` | `1cfa3653dc8ddb7aa9f4ef1c9c581e9516137e6e` | `95837e182baeeada83368f7748db28357f0a1b75c6b84ff7065b5edf933c8e18` |
| `OFL.txt` | `a72b0a7845bec3214559673ffeba60c816a21841` | `8e4ee42b2553e1e01504e61cb0d46d148cd8c9e5eacaa3622a7df2d4f2955b9f` |

## OpenVR SDK

Valve's OpenVR SDK 2.15.6 is pinned at `0924064316de3effbcd1acf1e309182a2deb1c05` in `vendor/lovr/deps/openvr`. The optional Linux Vulkan backend compiles its loader from source as a static library and uses it for overlay presentation, tracking, input, and events.

The SDK uses Valve's three-clause BSD licence. Its copyright, redistribution conditions, and disclaimer are in `vendor/lovr/deps/openvr/LICENSE`. The installation manifest copies those terms to `$PREFIX/share/lunette/licenses/OpenVR.txt`. Binary distributions that enable the optional loader must reproduce those terms. SteamVR is a separate runtime and is not redistributed.

## awesome

<https://github.com/awesomeWM/awesome>, GPL-2.0.

Ideas only, and no code. lunette's configuration model — a Lua file that is the window manager rather than a description of one, with a control socket that evaluates Lua rather than speaking a typed protocol — is awesome's. GPL-2.0 code cannot enter a GPL-3.0 project, which is why the debt is one of design and not of source.

## xkeyboard-config

<https://gitlab.freedesktop.org/xkeyboard-config/xkeyboard-config>, MIT/X11-style, by the xkeyboard-config contributors.

`crates/lunette-capture/tests/fixtures/evdev-us.xkb` is the `us` layout compiled from xkeyboard-config 2.48's `evdev` rules. A test checks lunette's key codes against it. It is checked in so the test does not depend on the release a distribution ships.
