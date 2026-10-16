# Credits

lunette is GPL-3.0-only because it incorporates WayVR's GPL-3.0-only code. Fork patches and bundled assets retain their upstream licences.

## WayVR

<https://github.com/wayvr-org/wayvr>, GPL-3.0-only, by galister and oo8dev. Previously WlxOverlay-S.

The Wayland compositor is ported from WayVR's `backend/wayvr`. Host capture and input integration also build on WayVR's work. [PROVENANCE.md](crates/lunette-compositor/PROVENANCE.md) records the compositor's source revision and relocated fragments.

## wlx-capture

<https://github.com/galister/wlx-capture>, GPL-3.0-only, by galister.

Host monitor capture uses `wlx-capture` as a git-pinned dependency. Its maintained source and lunette's pin are in the WayVR monorepo, not the standalone repository.

## LÖVR

<https://github.com/bjornbytes/lovr>, MIT, by Bjorn Swenson and LÖVR contributors.

lunette dynamically links its LÖVR fork for XR, rendering, audio, and Lua. Patches under `vendor/lovr` remain MIT so they can be contributed upstream. [LÖVR integration](docs/development/native/lovr-integration.md) records the integration constraints.

## msdfgen

msdfgen is copyright 2016-2023 Viktor Chlumsky and licensed under the MIT licence, carried in `vendor/lovr/deps/msdfgen` with its licence in `LICENSE.txt`. LÖVR builds it as `libmsdfgen.so`, and lunette links the same library directly to generate the UI toolkit's distance field glyphs. Installation copies it beside `liblovr.so`.

## Space Mono

Space Mono is copyright 2016 The Space Mono Project Authors (<https://github.com/googlefonts/spacemono>) and licensed under the SIL Open Font License, Version 1.1. The bundled font and licence are unmodified copies from `google/fonts` revision `8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5`: [SpaceMono-Regular.ttf](https://raw.githubusercontent.com/google/fonts/8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/ofl/spacemono/SpaceMono-Regular.ttf) and [OFL.txt](https://raw.githubusercontent.com/google/fonts/8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/ofl/spacemono/OFL.txt).

Copies live under `lua/lunette-plugins/theme/arcade/fonts/`. Distributions preserve `OFL.txt` with the font.

## IBM Plex Sans

IBM Plex Sans is copyright 2017 IBM Corp., with Reserved Font Name "Plex", and licensed under the SIL Open Font License, Version 1.1. The UI toolkit's standard kinds bundle the Regular, Medium, and SemiBold weights unmodified, as Google Fonts serves them, in `lua/lunette-plugins/ui/standard/fonts/`, with the licence from [IBM/plex](https://github.com/IBM/plex/blob/master/LICENSE.txt) as `OFL-IBMPlex.txt`.

## Iosevka

Iosevka is copyright 2015-2026 Renzhi Li (Belleve Invis) and licensed under the SIL Open Font License, Version 1.1, with no Reserved Font Name. The UI toolkit's standard kinds bundle the Regular weight from the `@fontsource/iosevka` 5.2.5 package, converted from WOFF2 to TrueType and subset to Latin, Greek, Cyrillic, punctuation, arrows, mathematical operators, box drawing, and geometric shapes, in `lua/lunette-plugins/ui/standard/fonts/`, with the licence from [be5invis/Iosevka](https://github.com/be5invis/Iosevka/blob/main/LICENSE.md) as `OFL-Iosevka.md`.

## OpenVR SDK

Valve's OpenVR SDK is carried in `vendor/lovr/deps/openvr` under Valve's three-clause BSD licence. The optional Linux Vulkan backend compiles its loader from source. Binary distributions that include the loader must reproduce its copyright, redistribution conditions, and disclaimer from `vendor/lovr/deps/openvr/LICENSE`; installation copies them to `$PREFIX/share/lunette/licenses/OpenVR.txt`. SteamVR is a separate runtime and is not redistributed.

## awesome

<https://github.com/awesomeWM/awesome>, GPL-2.0.

lunette's executable Lua configuration and Lua-evaluating control socket follow awesome's design. No awesome code is incorporated.

## xkeyboard-config

<https://gitlab.freedesktop.org/xkeyboard-config/xkeyboard-config>, MIT/X11-style, by the xkeyboard-config contributors.

`crates/lunette-capture/tests/fixtures/evdev-us.xkb` contains the `us` layout compiled from xkeyboard-config 2.48's `evdev` rules. The fixture is checked in to avoid depending on the distribution's version.
