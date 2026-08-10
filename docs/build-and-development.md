# Build and development

## Repo layout

```
lunette/
  flake.nix, flake.lock           the dev shell
  Makefile                        the install rule
  Cargo.toml                      workspace
  crates/
    lunette/                      the binaries: lunette and lunctl, Lua injection, frame orchestration
    lunette-compositor/           smithay; vendored fork of WayVR's backend/wayvr
    lunette-lovr/                 cmake build + FFI surface for LÖVR
    lunette-capture/              wrappers over wlx-capture and HidProvider
  lua/                            the mullion standard library
  etc/xdg/lunette/                the default configuration
  vendor/lovr/                    submodule → LÖVR with lunette's patch branch (recursive)
  docs/                           this
  inspiration/                    reference checkouts, gitignored
```

`lunette-compositor` must not depend on `lunette-lovr`. This is what keeps logic-headless testing reachable.

`lunctl` is a second binary target in `crates/lunette` rather than a crate of its own. It needs the control socket's wire format, which lives in `crates/lunette/src/control`, and a separate crate would either depend on `lunette` anyway or carry a second copy of the codec — a protocol with two implementations that have to agree is a defect waiting for the first version bump.

## Building

LÖVR links dynamically. `crates/lunette-lovr` builds it with `LOVR_BUILD_SHARED=ON` and `LOVR_BUILD_WITH_SYMBOLS=ON`, producing `liblovr.so` alongside the shared libraries it needs at runtime: the Luau VM/Compiler/Ast libraries (under `LOVR_USE_LUAU`), `libglfw.so`, `libmsdfgen.so`, `libphonon.so`, and joltc's wrapper around JoltPhysics. Those are built shared however LÖVR itself is linked, which is why a static LÖVR target would not make `lunette` a single binary ([LÖVR integration](lovr-integration.md#rejected-a-static-library-target)).

Two rpath arrangements make them resolve at runtime. `liblovr.so` is built with `CMAKE_SHARED_LINKER_FLAGS` adding `$ORIGIN/bin`, so it resolves its own siblings from the tree LÖVR's `move_files` target stages; an executable cannot supply that, because a `DT_RUNPATH` is not consulted when resolving a dependency's dependencies. The binary's own entries come from `crates/lunette-lovr/build.rs`, which publishes the library directories through `cargo::metadata` under a `links = "lovr"` declaration. `crates/lunette/build.rs` reads them back and emits the rpath link arguments itself, because Cargo applies a build script's link arguments to its own package's targets only.

`build.rs` drives cmake via the `cmake` crate, so `cargo build` works for contributors not on NixOS. Nix supplies system libraries (Vulkan loader, Wayland, PipeWire, D-Bus, xkbcommon, the OpenXR loader) rather than performing the build.

LÖVR's vendored dependencies are used as upstream intends: glslang, Luau, glfw, and the rest, from `deps/`. They form a known-good set that upstream CI tests, and substituting Nix versions would add a debugging surface with no offsetting benefit. The cost is a large first clone and a slow first build.

JoltPhysics is the exception. `deps/joltc` reaches it through cmake's `FetchContent`, which wants the network at configure time. The devshell prefetches the revision `deps/joltc` declares and points `FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS` at the result, so the cmake step needs no network. This is what the nixpkgs `lovr` derivation does, and the source is still the tree upstream selected. The revision moves when the `joltc` submodule is bumped.

## Nix

A flake with a dev shell. It supplies the toolchain, the system libraries, and the prefetched JoltPhysics tree; it does not build lunette itself. A package output comes later, and no nixpkgs upstreaming until it works. Until then the install path is the `Makefile`.

Because LÖVR's `deps/` are nested submodules, that package output will need `fetchSubmodules = true` and a fixed-output hash that changes on every LÖVR bump. It is also what blocks the output today: a flake source does not carry submodules unless it is fetched with `submodules=1`, so a derivation building from `./.` finds `vendor/lovr` empty. This is the recurring friction of the arrangement, and it is the price of tracking upstream on a branch.

## Where things live at runtime

This follows awesome, which installs Lua to `$PREFIX/share/awesome/lib` and its default config to `$SYSCONFDIR/xdg/awesome/rc.lua`.

| Thing | Path |
|---|---|
| Standard library | `$PREFIX/share/lunette/lua/` |
| Default config | `$SYSCONFDIR/xdg/lunette/main.lua` |
| User config | `~/.config/lunette/main.lua` |
| Control socket | `$XDG_RUNTIME_DIR/lunette/lunette-0.sock`, mode 0600 in a 0700 directory |
| Binaries | `$PREFIX/bin/lunette` and `$PREFIX/bin/lunctl` |
| Saved state | LÖVR's save directory |

The standard library is kept on disk rather than embedded in the binary, so it stays legible to anyone who needs to read it without cloning the source. There are two candidates and no third: `$LUNETTE_STDLIB_PATH` when it is set, and `$PREFIX/share/lunette/lua` otherwise. A relative override is taken as it stands, so `LUNETTE_STDLIB_PATH=lua cargo run` works from the source tree. [Decisions](decisions.md#recorded-decisions) records why there is no `./lua` fallback and how the mount is installed.

`make install` puts all of it where the table above says, with `PREFIX`, `SYSCONFDIR`, and `DESTDIR` all honoured. `PREFIX` and `SYSCONFDIR` reach the binary as `LUNETTE_PREFIX` and `LUNETTE_SYSCONFDIR`, which `crates/lunette/src/main.rs` compiles in through `option_env!` as the defaults it resolves against, so a build and the install that follows it are told the prefix once rather than twice. The LÖVR shared libraries are installed to `$PREFIX/lib/lunette`, which the executable reaches through an `$ORIGIN/../lib/lunette` rpath entry.

Embedding via `rust-embed` exists as an optional build feature, off by default, for single-file AppImage-style distribution later. WayVR ships one, so this may be adopted.

## The development loop

Most work happens in the desktop simulator. LÖVR's built-in simulator runs with no XR runtime, in a normal window on the desktop, with WASD and mouse control. Panels, compositor, clients, and input are all real; only the headset is faked. It must work from day one and stay working.

The simulator drives input sinks from mouse and keyboard, which costs nothing extra: [Input](input.md) already defines sinks as taking pixel coordinates from an arbitrary source.

Nesting works naturally. lunette in simulator mode is just another Wayland client of the host desktop, running its own nested compositor inside itself. This is useful for demonstrations and for development without a headset.

`WAYLAND_DISPLAY=wayland-20 <app>` from a host terminal launches an application into a running lunette, adopted as an external process ([Compositor](compositor.md#adoption)). lunette binds the first free name from `wayland-20` upwards and logs which it took, and exports that name into its own environment, so a client it starts inherits it.

Two environment settings exist for milestone 0 and answer the two open questions about the import barrier. `LUNETTE_IMPORT_QUEUE_FAMILY` takes `foreign` or `ignored`, and `LUNETTE_IMPORT_LAYOUT` takes `general` or `undefined`; `crates/lunette/src/texture/mod.rs` is the source of truth for both, and an unrecognised value falls back to the default with a warning rather than stopping the session.

Full XR is ground truth, and soft reload ([The Lua API](lua-api.md#reload)) is what makes iterating on it practical, since the editor is not readable with the headset on.

## Testing

Tier A, logic headless, is a design constraint rather than an aspiration. The compositor crate, capture, input routing, and process management are tested as ordinary Rust, with a small `wayland-client` test client speaking the real protocol. Buffer import is stubbed behind a trait, which is the seam the whole tier rests on. This costs nothing beyond the layering discipline already required, and becomes impossible only if the codebase is accidentally coupled to the graphics module.

The client and the compositor talk over a `UnixStream::pair()` rather than a bound socket: one end goes to `DisplayHandle::insert_client`, the other to `Connection::from_socket`. Nothing is bound, no path is written, and `XDG_RUNTIME_DIR` is never read, so two test binaries running at once cannot collide over a display number. `Connection::connect_to_env` is never used — it calls `env::remove_var` internally, and mutating the environment of a multithreaded test binary is unsound.

Tier B, GPU headless, is a nice-to-have. LÖVR runs with no window and no XR, panels render offscreen, and pixels are read back and asserted. `etc/boot.lua` opens a window only when `conf.window` is set, and `lovr.graphics.newReadback` exists, so this tier is available rather than theoretical. It is useful for confirming layout placement and for catching texture-import regressions.

End-to-end testing runs via `lunctl`, and it is Rust rather than a shell script. `crates/lunette/tests/lunctl.rs` and `crates/lunette/tests/safe_mode.rs` start the shipped binary against a fixture configuration, wait for the control socket, evaluate chunks through the shipped `lunctl` to assert state, and stop the session with a chunk. A shell script would drive the same two binaries over the same socket with worse failure reporting and a second harness to keep in step, so there is one harness and it runs with `cargo test`.

The half that is not covered is a client: a session with `modules.graphics = false` never lends a device to the compositor thread, so the thread does not start and nothing can connect to the Wayland socket it would serve. Spawning a client and asserting it appears in `lunette.windows()` therefore needs the GPU-headless tier above, and until that exists it is a human gate rather than a test. `crates/lunette-compositor/tests/` covers the client half against the compositor in-process, which is the same protocol traffic without the frame loop under it.

The standing checks are listed in [CONTRIBUTING.md](../CONTRIBUTING.md) and run via `make check`. The sixth is the Luau type checker: `scripts/check-luau.sh` typechecks the standard library and the shipped configuration in strict mode, catching a local referenced before its declaration and an accidental global before a session sees them.
