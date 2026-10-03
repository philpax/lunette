# Build and development

## Repo layout

```
lunette/
  flake.nix, flake.lock           the dev shell
  Makefile                        the install rule
  Cargo.toml                      workspace
  crates/
    lunette/                      binaries, Lua injection, frame orchestration, and plugin host
    lunette-compositor/           smithay; vendored fork of WayVR's backend/wayvr
    lunette-lovr/                 cmake build + FFI surface for LÖVR
    lunette-luau/                 the Luau type language and closed-set macro
    lunette-capture/              wrappers over wlx-capture and HidProvider
    lunette-generate-definitions/ generates native declarations, aliases, and install manifest
  lua/lunette/                    generated declarations for the native API
  lua/lunette-plugin/             typed plugin authoring facade and erased adapter
  lua/lunette-contracts/          neutral plugin service contracts
  lua/lunette-plugins/            every built-in plugin, provider or consumer
  lua/lunette-desktop/            the shipped desktop's entry list
  lua/spec/                       development-only Lua specifications
  etc/lunette/                    the generated Luau definitions
  etc/xdg/lunette/                the default configuration
  examples/                       example configurations, each with a generated .luaurc
  vendor/lovr/                    submodule → LÖVR with lunette's patch branch (recursive)
  vendor/lovr-docs/               submodule → the API metadata and its Luau generator, on lunette's branch
  vendor/mlua/                    submodule → mlua with lunette's Luau ABI patches
  docs/dev/                       this
  docs/guide/                     user-facing guides; not normative
  inspiration/                    reference checkouts, gitignored
```

`lunette-compositor` must not depend on `lunette-lovr`. This is what keeps logic-headless testing reachable. It does depend on `lunette-luau`, which carries no Lua binding of its own: mlua is a feature there, off by default and turned on only by `lunette`, so naming a Luau type costs the headless tier nothing.

`lunctl` is a second binary target in `crates/lunette` rather than a crate of its own. It needs the control socket's wire format, which lives in `crates/lunette/src/control`, and a separate crate would either depend on `lunette` anyway or carry a second copy of the codec — a protocol with two implementations that have to agree is a defect waiting for the first version bump.

## Building

LÖVR links dynamically. `crates/lunette-lovr` builds it with `LOVR_BUILD_SHARED=ON` and `LOVR_BUILD_WITH_SYMBOLS=ON`, producing `liblovr.so` alongside the shared libraries it needs at runtime: `libglfw.so`, `libmsdfgen.so`, `libphonon.so`, and joltc's wrapper around JoltPhysics. Luau is not among them: `LOVR_USE_LUAU` links `Luau.VM`, `Luau.Compiler`, and `Luau.Ast` into `liblovr.so` itself, and `LUAU_EXTERN_C` exports the Lua C API from there, which is where mlua resolves its symbols. Those are built shared however LÖVR itself is linked, which is why a static LÖVR target would not make `lunette` a single binary ([LÖVR integration](lovr-integration.md#rejected-a-static-library-target)).

Two rpath arrangements make them resolve at runtime. `liblovr.so` is built with `CMAKE_SHARED_LINKER_FLAGS` adding `$ORIGIN/bin`, so it resolves its own siblings from the tree LÖVR's `move_files` target stages; an executable cannot supply that, because a `DT_RUNPATH` is not consulted when resolving a dependency's dependencies. The binary's own entries come from `crates/lunette-lovr/build.rs`, which publishes the library directories through `cargo::metadata` under a `links = "lovr"` declaration. `crates/lunette/build.rs` reads them back and emits the rpath link arguments itself, because Cargo applies a build script's link arguments to its own package's targets only.

`build.rs` drives cmake via the `cmake` crate, so `cargo build` works for contributors not on NixOS. Nix supplies system libraries (Vulkan loader, Wayland, PipeWire, D-Bus, xkbcommon, the OpenXR loader) rather than performing the build.

LÖVR's vendored dependencies are used as upstream intends: glslang, Luau, glfw, and the rest, from `deps/`. They form a known-good set that upstream CI tests, and substituting Nix versions would add a debugging surface with no offsetting benefit. The cost is a large first clone and a slow first build.

JoltPhysics is the exception. `deps/joltc` reaches it through cmake's `FetchContent`, which wants the network at configure time. The devshell prefetches the revision `deps/joltc` declares and points `FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS` at the result, so the cmake step needs no network. This is what the nixpkgs `lovr` derivation does, and the source is still the tree upstream selected. The revision moves when the `joltc` submodule is bumped.

## Nix

A flake with a dev shell. It supplies the toolchain, the system libraries, and the prefetched JoltPhysics tree; it does not build lunette itself. A package output comes later, and no nixpkgs upstreaming until it works. Until then the install path is the `Makefile`.

Because LÖVR's `deps/` are nested submodules, that package output will need `fetchSubmodules = true` and a fixed-output hash that changes on every LÖVR bump. It is also what blocks the output today: a flake source does not carry submodules unless it is fetched with `submodules=1`, so a derivation building from `./.` finds `vendor/lovr` empty. This is the recurring friction of the arrangement, and it is the price of tracking upstream on a branch.

## Module roots

The source and install roots are described by `crates/lunette/src/aliases.rs`. It defines the aliases, source directories, runtime resolution, and development-only roots. The same descriptors generate `.luaurc` aliases and resolve the roots mounted by the session.

| Alias | Source directory | Runtime resolution | Installation |
|---|---|---|---|
| `@lunette` | `lua/lunette/` | Native `package.preload` entry; the directory contains generated declarations for the checker | Required declarations |
| `@lunette-plugin` | `lua/lunette-plugin/` | Mounted file root | Required |
| `@lunette-contracts` | `lua/lunette-contracts/` | Mounted file root | Required |
| `@lunette-plugins` | `lua/lunette-plugins/` | Mounted file root | Required |
| `@lunette-desktop` | `lua/lunette-desktop/` | Mounted file root | Required |
| `@spec` | `lua/spec/` | Mounted development file root | Not installed |

The `@lunette` API is registered at runtime and is not loaded from `lua/lunette/`. Its checked-in declaration is generated from the Rust registration surface. The plugin facade, provider, and desktop roots are ordinary Lua modules mounted under reserved aliases. The desktop root is required because the default configuration runs it; safe mode is compiled into the binary and needs none of the installed roots. Every installed root is required, and `crates/lunette/tests/installed_roots.rs` checks that no installed root and not the default configuration requires `@spec`, which an installation lacks. A configuration cannot shadow these mounts with files at the configuration root.

`make check-definitions` checks the generated Luau definitions, native API declarations, `.luaurc` files, and alias metadata. `make check-luau` checks the shipped roots, the ordinary spec harness modules, the default configuration, and the configurations under `examples/`, each of which has a generated `.luaurc` naming the source tree's roots. It runs the Luau checker as a separate process; startup does not run that checker.

## Where things live at runtime

| Thing | Path |
|---|---|
| Lua roots | `$PREFIX/share/lunette/lua/` |
| Default config | `$SYSCONFDIR/xdg/lunette/main.luau` |
| User config | `~/.config/lunette/main.luau` |
| Control socket | `$XDG_RUNTIME_DIR/lunette/lunette-0.sock`, mode 0600 in a 0700 directory |
| Binaries | `$PREFIX/bin/lunette` and `$PREFIX/bin/lunctl` |
| Saved state | LÖVR's save directory |

The Lua roots are kept on disk rather than embedded in the binary. The source tree remains readable without cloning the repository. There are two candidates for the root directory: `$LUNETTE_STDLIB_PATH` when it is set, and `$PREFIX/share/lunette/lua` otherwise. Pointing the override at a working tree is the development loop for every Lua root, the facade, contracts, providers, and desktop alike, so it wins over an installed copy. A relative override is taken as written, so `LUNETTE_STDLIB_PATH=lua cargo run` works from the source tree. [The standard library](stdlib.md#module-roots) records the root responsibilities.

`make install` installs the Lua artifacts listed by the Rust-owned manifest in `crates/lunette/src/aliases.rs`. `PREFIX`, `SYSCONFDIR`, and `DESTDIR` are honored. `PREFIX` and `SYSCONFDIR` reach the binary as `LUNETTE_PREFIX` and `LUNETTE_SYSCONFDIR`, which `crates/lunette/src/main.rs` compiles in through `option_env!`. The LÖVR shared libraries are installed to `$PREFIX/lib/lunette`, which the executable reaches through an `$ORIGIN/../lib/lunette` rpath entry. The `aliases.rs` module-root descriptors also generate checker aliases. `crates/lunette/src/cli.rs` separately lists the default configuration's files, `main.luau` and `conf.luau`, which `make install` installs and `lunette --dump-config` writes from copies embedded in the binary. The desktop's consumers are the installed `@lunette-desktop` root, so a copied configuration patches them rather than carrying copies. The command writes a `.luaurc` naming the Lua root a session would mount, `$LUNETTE_STDLIB_PATH` or `$PREFIX/share/lunette/lua`, by an absolute path, and refuses when a root it would name is not there. From a source tree, `LUNETTE_STDLIB_PATH=lua cargo run -- --dump-config DIR` writes a configuration whose `.luaurc` names the tree's roots.

`lunette check` takes files and directories; a directory is checked file by file. Given none, it checks the configuration directory a session would load, resolved the same way: `--config-path`, then `$LUNETTE_CONFIG_PATH`, `$XDG_CONFIG_HOME/lunette`, `$HOME/.config/lunette`, and `$SYSCONFDIR/xdg/lunette`.

Embedding via `rust-embed` exists as an optional build feature, off by default. It supports possible single-file distribution, but no such package output is defined.

## The development loop

`cargo run` starts the working copy against itself. The workspace's `default-members` is `crates/lunette` and that crate's `default-run` is `lunette`, so neither the package nor the binary has to be named from the repository root; `cargo run --bin lunctl` reaches the control client. A bare `cargo build` or `cargo test` covers that crate alone for the same reason, which is why the standing checks name `--workspace`. The devshell exports `LUNETTE_STDLIB_PATH` and `LUNETTE_CONFIG_PATH`, pointing at `lua/` and `etc/xdg/lunette` in the repository, so no flag is needed and the working directory does not matter: both are anchored at the repository root rather than at `$PWD`. `--config-path` outranks the variable. The Rust alias descriptors and generated install manifest remain the source of truth for module roots and installation.

`.envrc` carries `use flake`, so `direnv allow` puts that environment in the running shell. Using direnv rather than `nix develop` matters for what a session spawns. `nix develop` starts its own bash and sets `SHELL` to it, lunette hands its environment to every client it starts, and a terminal opened from such a session runs a shell from the store with none of the user's setup. direnv exports into the shell that is already running and leaves `SHELL` alone.

A test that spawns the binary against a fixture configuration removes `LUNETTE_CONFIG_PATH` from the environment it passes, for the reason it removes `HOME`: a fixture that is mislaid would otherwise load the developer's configuration and pass.

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

The standing checks are listed in [CONTRIBUTING.md](../../CONTRIBUTING.md) and run via `make check`. `lunette check` is one of them, which typechecks the standard library, the shipped configuration, and the examples in strict mode, catching a local referenced before its declaration and an accidental global before a session sees them. The LÖVR metadata defines `LovrConfiguration` with the `lovr.conf` callback fields. `crates/lunette-generate-definitions` generates the checked-in definition from that metadata.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

Compositor tests connect over a socketpair, not a bound socket. `Connection::from_socket` and `DisplayHandle::insert_client` both take a `UnixStream` directly, so a test gives one end of a `UnixStream::pair()` to each side and the filesystem is never involved. Only the listener's own tests — bind, listen, accept, and socket-path selection — bind a real socket, in a per-test temporary directory, because that is the code under test. The real socket in [Build and development](build-and-development.md#testing) means a real Wayland connection, not a real path on disk.

The exit status is tested by spawning the binary, which is the one place a test runs a real subprocess. `boot::run` returns an `ExitCode`, which is opaque and carries no accessor, and the code that produces it cannot be reached without a live LÖVR Lua thread, so the status is observable only from outside the process. `crates/lunette/tests/exit_status.rs` runs the binary against a fixture configuration directory that opens no window and disables the audio, graphics, and headset modules, so no display, XR runtime, or sound device is needed. `lovr.filesystem.setIdentity` creates a save directory on every run and fails the boot when it cannot, so each run points `XDG_DATA_HOME` at its own temporary directory and each fixture carries a distinct identity. That keeps the write inside the temporary directory, keeps two parallel runs from racing to create one shared leaf, and makes the run independent of `HOME` and of the running uid having a passwd entry. The exception exists because reading the status from the wrong Lua stack slot once made every exit report success while the suite stayed green.

`lunette --dump-config` writes the default configuration embedded in the binary, not the one installed under `$SYSCONFDIR/xdg/lunette`. That directory is fixed when the binary is built, so a binary that was never installed, such as one run from a source tree, had nothing to copy and failed, and an installed binary could copy a configuration another version installed. The embedded files are the ones written against the module roots this binary mounts. The `.luaurc` beside them names the Lua root by the resolution a session uses rather than by a path beside the executable: resolving one relative to the executable was considered and not taken, because it would add a third candidate a session does not use, and a configuration whose `.luaurc` names roots its session does not mount checks clean and fails to load.

## Known gaps

Named, not solved.

There is no flake package output, so `nix build` produces nothing and the install path is the `Makefile`. The blocker is the one [Nix](#nix) already names: LÖVR's `deps/` are nested submodules, and a flake source does not carry submodules unless it is fetched with `submodules=1`, so a derivation building from `./.` would find `vendor/lovr` empty. The `Makefile` installs the binary, the LÖVR shared libraries, the Lua artifacts named by the module-root manifest, and the default configuration at the documented paths. The executable resolves its own libraries through the `$ORIGIN/../lib/lunette` rpath entry. The installed configuration-copy workflow has not been validated as an installed-session test.

The end-to-end tests are Rust and not the shell script [Testing](#testing) originally described. They drive the same two binaries over the same socket; a shell script would add a second harness to keep in step and report failures worse. The part of that description that is not yet met is the client: a headless fixture switches the graphics module off, so no device is lent to the compositor thread, the thread does not start, and nothing can connect to the Wayland socket. That half needs the GPU-headless tier and is recorded as a gate in [milestone 0 findings](2026-08-06-milestone-0-findings.md#outstanding) until it exists.
