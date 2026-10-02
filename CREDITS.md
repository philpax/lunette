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

lunette dynamically links a fork of LÖVR, carried as the `vendor/lovr` submodule, and uses it for rendering, the OpenXR session, spatialised audio, and the Lua runtime.

Patches under `vendor/lovr` are MIT, matching upstream, not GPL-3.0-only. Relicensing them would make them unmergeable by the project they are written for. Each patch is narrow, additive, and shaped as an upstream pull request; the set is listed in [docs/dev/lovr-integration.md](docs/dev/lovr-integration.md#the-patch-set).

## awesome

<https://github.com/awesomeWM/awesome>, GPL-2.0.

Ideas only, and no code. lunette's configuration model — a Lua file that is the window manager rather than a description of one, with a control socket that evaluates Lua rather than speaking a typed protocol — is awesome's. GPL-2.0 code cannot enter a GPL-3.0 project, which is why the debt is one of design and not of source.

## xkeyboard-config

<https://gitlab.freedesktop.org/xkeyboard-config/xkeyboard-config>, MIT/X11-style, by the xkeyboard-config contributors.

`crates/lunette-capture/tests/fixtures/evdev-us.xkb` is the `us` layout compiled from xkeyboard-config 2.48's `evdev` rules. A test checks lunette's key codes against it. It is checked in so the test does not depend on the release a distribution ships.
