# Build and development

## Repo layout

```
lunette/
  flake.nix, flake.lock           dev shell and package output
  Cargo.toml                      workspace
  crates/
    lunette/                      the binary: main(), Lua injection, frame orchestration
    lunette-compositor/           smithay; vendored fork of WayVR's backend/wayvr
    lunette-lovr/                 cmake build + FFI surface for the LÖVR fork
    lunette-capture/              wrappers over wlx-capture and HidProvider
  lua/                            the mullion standard library
  vendor/lovr/                    submodule → the LÖVR fork (recursive)
  examples/                       default main.lua and friends
  docs/                           this
  inspiration/                    reference checkouts, gitignored
```

`lunette-compositor` must not depend on `lunette-lovr`. This is what keeps logic-headless testing reachable.

## Building

LÖVR links statically. `LOVR_BUILD_STATIC` is added to the fork ([LÖVR integration](lovr-integration.md#3-static-library-target)), so `lunette` is one binary: no `rpath` handling, no `liblovr.so` to keep in lockstep, no ABI surface across submodule bumps.

`build.rs` drives cmake via the `cmake` crate, so `cargo build` works for contributors not on NixOS. Nix supplies system libraries (Vulkan loader, Wayland, PipeWire, D-Bus, xkbcommon, the OpenXR loader) rather than performing the build.

LÖVR's vendored dependencies are used as upstream intends: glslang, Jolt, LuaJIT, glfw, and the rest, from `deps/`. They form a known-good set that upstream CI tests, and substituting Nix versions would add a debugging surface with no offsetting benefit. The cost is a large first clone and a slow first build.

## Nix

A flake with a dev shell and a package output. No nixpkgs upstreaming until it works.

Because LÖVR's `deps/` are nested submodules, the flake needs `fetchSubmodules = true` and a fixed-output hash that changes on every LÖVR bump. This is the recurring friction of the arrangement, and it is the price of tracking upstream on a branch.

## Where things live at runtime

This follows awesome, which installs Lua to `$PREFIX/share/awesome/lib` and its default config to `$SYSCONFDIR/xdg/awesome/rc.lua`.

| Thing | Path |
|---|---|
| Standard library | `$PREFIX/share/lunette/lua/` |
| Default config | `$SYSCONFDIR/xdg/lunette/main.lua` |
| User config | `~/.config/lunette/main.lua` |
| Control socket | `$XDG_RUNTIME_DIR/lunette-0.sock` |
| Saved state | LÖVR's save directory |

The standard library is kept on disk rather than embedded in the binary, so it stays legible to anyone who needs to read it without cloning the source. Search order: `$LUNETTE_STDLIB_PATH` (dev override), then the compiled-in prefix, then `./lua` when running from a build tree.

Embedding via `rust-embed` exists as an optional build feature, off by default, for single-file AppImage-style distribution later. WayVR ships one, so this may be adopted.

## The development loop

Most work happens in the desktop simulator. LÖVR's built-in simulator runs with no XR runtime, in a normal window on the desktop, with WASD and mouse control. Panels, compositor, clients, and input are all real; only the headset is faked. It must work from day one and stay working.

The simulator drives input sinks from mouse and keyboard, which costs nothing extra: [Input](input.md) already defines sinks as taking pixel coordinates from an arbitrary source.

Nesting works naturally. lunette in simulator mode is just another Wayland client of the host desktop, running its own nested compositor inside itself. This is useful for demonstrations and for development without a headset.

`WAYLAND_DISPLAY=lunette-0 <app>` from a host terminal launches an application into a running lunette, adopted as an external process ([Compositor](compositor.md#adoption)).

Full XR is ground truth, and soft reload ([The Lua API](lua-api.md#reload)) is what makes iterating on it practical, since the editor is not readable with the headset on.

## Testing

Tier A, logic headless, is a design constraint rather than an aspiration. The compositor crate, capture, input routing, and process management are tested as ordinary Rust, with a small `smithay-client-toolkit` test client connecting to a real socket. Buffer import is stubbed. This costs nothing beyond the layering discipline already required, and becomes impossible only if the codebase is accidentally coupled to the graphics module.

Tier B, GPU headless, is a nice-to-have. LÖVR runs with no window and no XR, panels render offscreen, and pixels are read back and asserted. `boot.lua:171` only opens a window if `conf.window` is set, and `lovr.graphics.newReadback` exists, so this tier is available rather than theoretical. It is useful for confirming layout placement and for catching texture-import regressions.

End-to-end testing runs via `lunctl`: a shell script that spawns a client, evaluates Lua to assert state, and tears down. This is nearly free, given that the control socket exists regardless.
