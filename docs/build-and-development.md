# Build and development

## Repo layout

```
lunette/
  flake.nix, flake.lock           dev shell and package output
  Cargo.toml                      workspace
  crates/
    lunette/                      the binary: main(), Lua injection, frame orchestration
    lunette-compositor/           smithay; vendored fork of WayVR's backend/wayvr
    lunette-lovr/                 cmake build + FFI surface for our LÖVR fork
    lunette-capture/              wrappers over wlx-capture and HidProvider
  lua/                            the mullion standard library
  vendor/lovr/                    submodule → our LÖVR fork (recursive)
  examples/                       default main.lua and friends
  docs/                           this
  inspiration/                    reference checkouts, gitignored
```

`lunette-compositor` must not depend on `lunette-lovr`. That's what keeps logic-headless testing reachable.

## Building

**LÖVR links statically.** We add `LOVR_BUILD_STATIC` to our fork ([LÖVR integration](lovr-integration.md#3-static-library-target)), so `lunette` is one binary — no `rpath` handling, no `liblovr.so` to keep in lockstep, no ABI surface across submodule bumps.

**`build.rs` drives cmake** via the `cmake` crate, so `cargo build` works for contributors who aren't on NixOS. Nix supplies system libraries (Vulkan loader, Wayland, PipeWire, D-Bus, xkbcommon, the OpenXR loader) rather than performing the build.

**LÖVR's vendored dependencies are used as upstream intends** — glslang, Jolt, LuaJIT, glfw and the rest, from `deps/`. They're a known-good set that upstream CI tests, and substituting Nix versions is a debugging surface we don't need. The cost is a large first clone and a slow first build.

## Nix

A flake with a dev shell and a package output. No nixpkgs upstreaming until it works.

Because LÖVR's `deps/` are nested submodules, the flake needs `fetchSubmodules = true` and a fixed-output hash that changes on every LÖVR bump. That's the recurring friction of this arrangement, and it's the price for tracking upstream on a branch.

## Where things live at runtime

Following awesome, which installs Lua to `$PREFIX/share/awesome/lib` and its default config to `$SYSCONFDIR/xdg/awesome/rc.lua`:

| Thing | Path |
|---|---|
| Standard library | `$PREFIX/share/lunette/lua/` |
| Default config | `$SYSCONFDIR/xdg/lunette/main.lua` |
| User config | `~/.config/lunette/main.lua` |
| Control socket | `$XDG_RUNTIME_DIR/lunette-0.sock` |
| Saved state | LÖVR's save directory |

The standard library is on disk rather than embedded in the binary so it's legible to anyone who needs to read it without cloning the source. Search order: `$LUNETTE_STDLIB_PATH` (dev override) → compiled-in prefix → `./lua` when running from a build tree.

Embedding via `rust-embed` exists as an optional build feature, off by default, for single-file AppImage-style distribution later. WayVR ships one, so we may want to.

## The development loop

**The desktop simulator is where most work happens.** LÖVR's built-in simulator runs with no XR runtime, in a normal window on your desktop, with WASD and mouse. Panels, compositor, clients, and input are all real — only the headset is faked. It must work from day one and stay working.

The simulator drives input sinks from mouse and keyboard, which costs nothing extra: [Input](input.md) already defines sinks as taking pixel coordinates from wherever.

**Nesting works naturally.** lunette in simulator mode is just another Wayland client of your desktop, running its own nested compositor inside itself. Good for demos, and good for not wearing a headset at your desk.

**`WAYLAND_DISPLAY=lunette-0 <app>` from your host terminal** launches something into a running lunette, adopted as an external process ([Compositor](compositor.md#adoption)).

**Full XR** is ground truth, and soft reload ([The Lua API](lua-api.md#reload)) is what makes it bearable — you can't read your editor with the headset on.

## Testing

**Tier A — logic headless. A design constraint, not an aspiration.** The compositor crate, capture, input routing, and process management tested as ordinary Rust, with a small `smithay-client-toolkit` test client connecting to a real socket. Buffer import stubbed. This costs nothing beyond the layering discipline we already want; it only becomes impossible if we accidentally couple everything to the graphics module.

**Tier B — GPU headless. A nice-to-have.** LÖVR up, no window, no XR, panels rendered offscreen, pixels read back and asserted. `boot.lua:171` only opens a window if `conf.window` is set, and `lovr.graphics.newReadback` exists, so this is available rather than theoretical. Useful for "did the layout put the panel where I said" and for catching texture-import regressions.

**End-to-end via `lunctl`.** A shell script that spawns a client, evals Lua to assert state, and tears down. Nearly free, given the control socket exists anyway.
