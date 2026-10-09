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
  lua/testing/                    development-only Lua test scaffolding
  etc/lunette/                    the generated Luau definitions
  etc/xdg/lunette/                the default configuration
  examples/                       example configurations, each with a generated .luaurc
  dev/                            repository-only development configuration and local plugins
  vendor/lovr/                    submodule → LÖVR with lunette's patch branch (recursive)
  vendor/lovr-docs/               submodule → the API metadata and its Luau generator, on lunette's branch
  vendor/mlua/                    submodule → mlua with lunette's Luau ABI patches
  docs/dev/                       the design specification
  docs/guide/                     user-facing guides; not normative
```

`lunette-compositor` must not depend on `lunette-lovr`. This is what keeps logic-headless testing reachable. It does depend on `lunette-luau`, which carries no Lua binding of its own: mlua is a feature there, off by default and turned on only by `lunette`, so naming a Luau type costs the headless tier nothing.

`lunctl` is a second binary target in `crates/lunette` rather than a crate of its own. It needs the control socket's wire format, which lives in `crates/lunette/src/control`, and a separate crate would either depend on `lunette` anyway or carry a second copy of the codec — a protocol with two implementations that have to agree is a defect waiting for the first version bump.

## Building

LÖVR links dynamically. `crates/lunette-lovr` builds it with `LOVR_BUILD_SHARED=ON` and `LOVR_BUILD_WITH_SYMBOLS=ON`, producing `liblovr.so` alongside the shared libraries it needs at runtime: `libglfw.so`, `libmsdfgen.so`, `libphonon.so`, and joltc's wrapper around JoltPhysics. Luau is not among them: `LOVR_USE_LUAU` links `Luau.VM`, `Luau.Compiler`, and `Luau.Ast` into `liblovr.so` itself, and `LUAU_EXTERN_C` exports the Lua C API from there, which is where mlua resolves its symbols. Those are built shared however LÖVR itself is linked, which is why a static LÖVR target would not make `lunette` a single binary ([LÖVR integration](lovr-integration.md#rejected-a-static-library-target)).

The OpenVR build contract enables `LOVR_ENABLE_OPENVR` in lunette on supported Linux Vulkan builds. The option stays off upstream. Valve's pinned SDK loader links statically into `liblovr.so`; it adds no installed SDK shared library and requires no SteamVR installation path at build time. Loading LÖVR or running the checker must not start SteamVR. `crates/lunette-lovr/build.rs` is the source of truth for Linux enablement and build-input watches. It watches the SDK sources and headers and the action bundle.

Two rpath arrangements make them resolve at runtime. `liblovr.so` is built with `CMAKE_SHARED_LINKER_FLAGS` adding `$ORIGIN/bin`, so it resolves its own siblings from the tree LÖVR's `move_files` target stages; an executable cannot supply that, because a `DT_RUNPATH` is not consulted when resolving a dependency's dependencies. The binary's own entries come from `crates/lunette-lovr/build.rs`, which publishes the library directories through `cargo::metadata` under a `links = "lovr"` declaration. `crates/lunette/build.rs` reads them back and emits the rpath link arguments itself, because Cargo applies a build script's link arguments to its own package's targets only.

`build.rs` drives cmake via the `cmake` crate, so `cargo build` works for contributors not on NixOS. Nix supplies system libraries (Vulkan loader, Wayland, PipeWire, D-Bus, xkbcommon, the OpenXR loader) rather than performing the build.

LÖVR's vendored dependencies are used as upstream intends: glslang, Luau, glfw, and the rest, from `deps/`. They form a known-good set that upstream CI tests, and substituting Nix versions would add a debugging surface with no offsetting benefit. The cost is a large first clone and a slow first build.

JoltPhysics is the exception. `deps/joltc` reaches it through cmake's `FetchContent`, which wants the network at configure time. The devshell prefetches the revision `deps/joltc` declares and points `FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS` at the result, so the cmake step needs no network; this is what the nixpkgs `lovr` derivation does, and the source is still the tree upstream selected. Outside the devshell the variable is optional: `build.rs` warns and lets `FetchContent` fetch the same revision itself. The revision moves when the `joltc` submodule is bumped.

`BINDGEN_EXTRA_CLANG_ARGS` supplies the devshell's clang search paths. `build.rs` disables bindgen's probe when they are set and enables it for plain host builds.

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
| `@testing` | `lua/testing/` | Mounted development file root | Not installed |

The `@lunette` API is registered at runtime and is not loaded from `lua/lunette/`. Its checked-in declaration is generated from the Rust registration surface. The plugin facade, provider, and desktop roots are ordinary Lua modules mounted under reserved aliases. The desktop root is required because the default configuration runs it; safe mode is compiled into the binary and needs none of the installed roots. Every installed root is required, and the Lua runner's installed-roots case checks that no installed root and not the default configuration requires `@testing`, which an installation lacks. A root's `tests` directories are not installed either; they are the only files below an installed root that may require `@testing`. A configuration cannot shadow these mounts with files at the configuration root.

`make check-definitions` checks the generated Luau definitions, native API declarations, `.luaurc` files, and alias metadata. `make check-luau` checks the shipped roots outside their `tests` directories, the default configuration, the configurations under `examples/`, and the repository-only `dev/` configuration and plugins, each with a generated `.luaurc` naming the source tree's roots. It runs the Luau checker as a separate process; startup does not run that checker.

## Where things live at runtime

| Thing | Path |
|---|---|
| Lua roots | `$PREFIX/share/lunette/lua/` |
| Default config | `$SYSCONFDIR/xdg/lunette/main.luau` |
| User config | `~/.config/lunette/main.luau` |
| Control socket | `$XDG_RUNTIME_DIR/lunette/lunette-0.sock`, mode 0600 in a 0700 directory |
| Binaries | `$PREFIX/bin/lunette` and `$PREFIX/bin/lunctl` |
| Saved state | LÖVR's save directory |
| OpenVR action bundle | `$PREFIX/lib/lunette/lovr-openvr/`, beside the canonical owning `liblovr.so` |

The Lua roots are kept on disk rather than embedded in the binary. The source tree remains readable without cloning the repository. There are two candidates for the root directory: `$LUNETTE_STDLIB_PATH` when it is set, and `$PREFIX/share/lunette/lua` otherwise. Pointing the override at a working tree is the development loop for every Lua root, the facade, contracts, providers, and desktop alike, so it wins over an installed copy. A relative override is taken as written, so `LUNETTE_STDLIB_PATH=lua cargo run` works from the source tree. [The standard library](stdlib.md#module-roots) records the root responsibilities.

`make install` installs the Lua artifacts listed by the Rust-owned manifest in `crates/lunette/src/aliases.rs`. `PREFIX`, `SYSCONFDIR`, and `DESTDIR` are honored. `PREFIX` and `SYSCONFDIR` reach the binary as `LUNETTE_PREFIX` and `LUNETTE_SYSCONFDIR`, which `crates/lunette/src/main.rs` compiles in through `option_env!`. The LÖVR shared libraries are installed to `$PREFIX/lib/lunette`, which the executable reaches through an `$ORIGIN/../lib/lunette` rpath entry. The `aliases.rs` module-root descriptors also generate checker aliases. `crates/lunette/src/cli.rs` separately lists the default configuration's files, `main.luau` and `conf.luau`, which `make install` installs and `lunette --dump-config` writes from copies embedded in the binary. The desktop's consumers are the installed `@lunette-desktop` root, so a copied configuration patches them rather than carrying copies. The command writes a `.luaurc` naming the Lua root a session would mount, `$LUNETTE_STDLIB_PATH` or `$PREFIX/share/lunette/lua`, by an absolute path, and refuses when a root it would name is not there. From a source tree, `LUNETTE_STDLIB_PATH=lua cargo run -- --dump-config DIR` writes a configuration whose `.luaurc` names the tree's roots.

Manifest directory entries install only `.luau` files outside `tests` directories. Explicit file entries in `INSTALL_ARTIFACTS` install files of any extension at destinations relative to `$PREFIX/share/lunette`. The theme font and its licence are explicit entries: `lua/lunette-plugins/theme/arcade/fonts/SpaceMono-Regular.ttf` and `lua/lunette-plugins/theme/arcade/fonts/OFL.txt`. Both files retain their source paths below the installed data directory. [Credits](../../CREDITS.md#space-mono) records their upstream revision, checksums, copyright, and licence. The manifest also installs the OpenVR SDK's copyright, licence conditions, and disclaimer from `vendor/lovr/deps/openvr/LICENSE` to `licenses/OpenVR.txt` below the same data directory.

The OpenVR action manifest and controller bindings reside in `lovr-openvr/` beside the canonical actual `liblovr.so` target in both build and installed layouts. Resolution does not use a library symlink's directory, a checkout-relative path, or a SteamVR path. Assets and their ancestry require trusted ownership, no untrusted write permissions, and no symlinks. A runtime fixture under `/tmp` does not satisfy this trust contract. CMake stages the bundle with the library's `POST_BUILD` rule and tracks asset source changes through `LINK_DEPENDS`. Deleting only a staged asset does not force restaging while the library remains up to date. A rebuild that relinks the library restores the bundle; installation rejects an incomplete bundle rather than assuming incremental staging repaired it.

`Makefile`'s `install-binary` rule is the source of truth for native binary and library installation. `make install` requires `patchelf` to discover the linked build and set installed executable rpaths; `PATCHELF` selects that tool. It discovers the exact linked LÖVR build through the executable's rpath and reads that build's CMake cache. An enabled build requires the complete action bundle before installation proceeds. It installs `actions.json` and the Vive, Knuckles, Touch, and Steam Frame binding files alongside the matching library. It must not select an arbitrary stale Cargo build directory. A clean installation must resolve the installed bundle without files from the source checkout. Installation is not transactional. A late copy or `patchelf` failure can leave a partially installed tree; preflight checks do not guarantee rollback.

`lunette check` takes files and directories; a directory is checked file by file. Given none, it checks the configuration directory a session would load, resolved the same way: `--config-path`, then `$LUNETTE_CONFIG_PATH`, `$XDG_CONFIG_HOME/lunette`, `$HOME/.config/lunette`, and `$SYSCONFDIR/xdg/lunette`.

Embedding via `rust-embed` exists as an optional build feature, off by default. It supports possible single-file distribution, but no such package output is defined.

## The development loop

`make run` starts the working copy with the repository-only `dev/` configuration. The target in `Makefile` sets `LUNETTE_STDLIB_PATH` to the absolute `lua/` path and `LUNETTE_CONFIG_PATH` to the absolute `dev/` path under the repository root for that invocation, independently of Nix. `make run ARGS="--config-path /path/to/config"` loads another configuration; the flag outranks the variable. `make run ARGS="--config-path etc/xdg/lunette"` selects the shipped default configuration. Plain `cargo run` uses the installed runtime defaults unless the variables are supplied explicitly. The workspace's `default-members` is `crates/lunette` and that crate's `default-run` is `lunette`, so neither the package nor the binary has to be named from the repository root; `cargo run --bin lunctl` reaches the control client. A bare `cargo build` or `cargo test` covers that crate alone for the same reason, which is why the standing checks name `--workspace`. The Rust alias descriptors and generated install manifest remain the source of truth for module roots and installation.

The shipped desktop starts no applications. The repository-only `dev/` configuration inserts `dev/plugins/demo-terminal`, which tries its configured terminal programs when no window is open and retains its attempt guard across source reload. From the repository root, `make run` selects it. `LUNETTE_STDLIB_PATH=lua cargo run -- --config-path dev` also selects the source modules. The development config loads its plugins by relative `require`; it adds no runtime alias, and neither the config nor its plugins are installed. `dev/examples` is a symlink to `../examples`; the keyboard examples remain available to development tests and configurations without replacing the built-in keyboard in the default development composition. The wrist menu's Keyboard action shows the shared keyboard. `dev/conf.luau` retains the shipped overlay and source precedence settings and uses the separate `lunette-dev` save identity.

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

The Lua tests run in-process. `crates/lunette/tests/lua/` is one test binary with its own harness, built on `libtest-mimic`: it walks `lua/` and `dev/`, takes every `.luau` file directly inside a `tests` directory as a test file, and runs each as a test of its own in a fresh Lua state. The state resolves the module roots from the working tree under the names a session mounts them by, with chunk names a session would give, so a relative require in a test resolves as the checker resolves it. Development test files resolve through `dev/` as configuration-relative modules without a new alias. `@lunette` is a native table carrying the real plugin runtime and key and scale vocabularies, to which `lua/testing/native.luau` adds a fake of the rest; `lovr.math` is opened from `liblovr.so` with `luaopen_lovr_math`, so a pose is a real `Mat4`. `@testing/host` exposes what only the host can do: the plugin failures collected so far, the plugin shutdown, the production reload, the native error boundary with the log it writes, and a configuration chosen by directory for `require 'main'`. The fake's `lunette.reportError` and its `raise` report through that boundary, so an `onError` listener receives what a session would give it. The runner's own cases, named `runner::`, check discovery and that a file returning no suite, a file with no cases, a raising case, and an untaken plugin failure each fail. A session that `testing.start` or `testing.boot` opens during a case is closed after the case, whether it passes or fails, and closing a session twice is harmless.

The existing `runner::ui_modules_load_from_installed_manifest_roots` trial copies the install manifest into a temporary data directory and loads modules from those copied roots. Its copier rejects unsafe relative destinations, copies explicit files without an extension filter, and keeps recursive module copies limited to `.luau` files outside `tests` directories. The trial checks that the copied theme font and licence are nonempty and byte-identical to the repository files. It does not exercise LÖVR's mounted filesystem, native font loading, or graphics.

`lua/testing/vr-ui.luau` drives the real frame, laser, interaction, and surfaces providers through LÖVR callbacks. Its controller state is independent per hand and includes pose, buttons, axes, and tracking loss; a hand without controller state is untracked. Geometry-based clicks requery panel descriptions after each preparatory update. The fixture records native input, draw calls, and live keyboard registrations.

`lua/testing/render.luau` records draw arguments, persistent LÖVR transforms, and pass state. It measures deterministic text boxes and checks geometry against a declared logical rectangle. Restoration assertions detect transform, state, and stack leaks after drawing errors. Theme and UI recorder checks verify requested font selection, geometry, and pass restoration; they do not rasterize pixels, shape text, or establish actual font fitting, headset readability, GPU presentation, or controller ergonomics. `manual_xr_widget_and_manager_acceptance` remains open for in-headset manager and widget acceptance. `theme-font-fit` remains open for real mounted-font rendering, and `theme-broker-lifecycle` remains open for reentrant lease and shutdown observations.

End-to-end testing runs via `lunctl`, and it is Rust rather than a shell script. `crates/lunette/tests/lunctl.rs` and `crates/lunette/tests/safe_mode.rs` start the shipped binary against a fixture configuration, wait for the control socket, evaluate chunks through the shipped `lunctl` to assert state, and stop the session with a chunk. A shell script would drive the same two binaries over the same socket with worse failure reporting and a second harness to keep in step, so there is one harness and it runs with `cargo test`.

The half that is not covered is a client: a session with `modules.graphics = false` never lends a device to the compositor thread, so the thread does not start and nothing can connect to the Wayland socket it would serve. Spawning a client and asserting it appears in `lunette.windows()` therefore needs the GPU-headless tier above, and until that exists it is a human gate rather than a test. `crates/lunette-compositor/tests/` covers the client half against the compositor in-process, which is the same protocol traffic without the frame loop under it.

`make check-headset` configures a dedicated native CMake build, builds `headset_native_tests`, and runs the CTest `headset` label. It compiles LÖVR's shaders with glslang built from `deps/glslang`, so the check needs no system shader compiler. The tests cover the optional OpenVR backend without SteamVR or graphics hardware. Injected runtime and GPU operations exercise connection failures, cleanup, presentation traces, tracking, input, and actual managed graphics ownership, including retained textures, views, passes, and layers. An isolated process checks the real loader's missing-runtime failure. Staged native artifacts exercise asset resolution. The harness checks discovery and deliberately failing child exit statuses. These tests do not establish hardware binding acceptance or visual correctness.

`make check-headset-runtime OPENVR_SCENE_PID=<positive-existing-game-pid>` is an explicit opt-in runtime check, not a standing `make check` dependency. The PID must identify an already-running SteamVR scene application. The command requires SteamVR, a connected headset, Vulkan, and trusted artifact and asset paths. Missing prerequisites fail with a nonzero status; they do not silently skip. The harness must not launch or kill the game or change global runtime settings.

The target builds a production shared LÖVR backend and its `lovr_openvr_coexistence` driver under `target/openvr-coexistence` by default. `CARGO_TARGET_DIR` changes that root. `Makefile` owns the build and invocation. The driver runs two 120-frame sessions with a 75-second internal deadline. The target bounds execution with `timeout --signal=TERM --kill-after=5s 90s`; compilation runs before that external timeout.

The driver wraps and delegates the real SDK function tables. It observes real overlay creation, destruction, and `SetOverlayTexture` calls, and samples the scene PID against the supplied value. This is a runtime handoff and sampled coexistence oracle, separate from the manual Lua fixture's completed-public-API counters. PID samples do not prove continuous game rendering between observations. Forced termination does not guarantee orderly cleanup; owned overlays must disappear afterward. The production driver links, and the target rejects a missing expected PID with a nonzero status. A connected runtime with a mismatched sampled scene PID also fails; that is not evidence of a missing runtime. The selection and handle-identity observation seams are reviewed. Real-game coexistence acceptance remains unverified. No hardware pass is claimed.

The manual OpenVR diagnostic lives in `crates/lunette/tests/fixtures/openvr-diagnostic/lunette`. It requires an OpenVR-enabled Linux build, SteamVR, a connected headset, and a trusted checkout and build path. Build before starting the external timeout so compilation does not consume the observation budget:

```sh
cargo build -p lunette --bin lunette
timeout --signal=TERM --kill-after=5s 75s ./target/debug/lunette --config-path crates/lunette/tests/fixtures/openvr-diagnostic/lunette
```

The command assumes Cargo's default target directory and debug profile. A custom target directory requires the corresponding binary path. The fixture requests explicit OpenVR and rejects desktop fallback. It stops after 600 frames and reports an error if its frame-driven timer reaches 60 seconds first. The external timeout bounds a stalled native call that the fixture timer cannot observe. It sends TERM after 75 seconds and KILL after another five seconds if necessary. Timeout status 124 indicates forced termination, not successful completion. Forced termination does not guarantee Lua cleanup; manual observation must verify that owned overlays disappear. Escape also exits.

The phases show animated panels, distinct stereo eye labels, world-space geometry, and alpha regions:

| Frames | Phase |
|---|---|
| 1 to 100 | Normal scene and panels |
| 101 to 200 | Moving panel omitted |
| 201 to 300 | Moving panel restored |
| 301 to 400 | Scene disabled at the next frame boundary; panels remain live |
| 401 to 500 | Scene restored |
| 501 to 600 | Moving panel permanently removed |

Manual observation must check stereo alignment, alpha, native text sharpness, motion, continued game visibility, and overlay disappearance after exit. The native red/cyan squares and scene crosses share a known world pose; their centers must stay registered during head rotation and after motion stops. The TL, TR, BL, BR, and CENTER labels distinguish image orientation. Tracking logs separately report focus, grip poses, and pointing poses for each hand. False focus does not itself invalidate poses, while missing action bindings can still leave a pose unavailable. Submission counters record completed public API calls, not verified runtime handoffs. The fixture has no scene-process PID access or oracle; that instrumentation gap prevents automated coexistence acceptance. It asserts no hardware pass. A completed invocation records bounded diagnostic execution, not successful binding acceptance, game coexistence, or visual acceptance. Those checks remain unverified until runtime evidence and manual observations establish them.

`make check-install` runs `crates/lunette/tests/fixtures/install.py` through the standing `make check` target. The hardware-free harness uses real ELF artifacts, a fake Cargo driver, and actual Make installation rules to check linked-build discovery, installed library resolution, and action-bundle packaging. These checks establish no hardware acceptance.

The standing checks are listed in [CONTRIBUTING.md](../../CONTRIBUTING.md) and run via `make check`. `lunette check` is one of them, which typechecks the standard library, the shipped and development configurations, and the examples in strict mode, catching a local referenced before its declaration and an accidental global before a session sees them. The LÖVR metadata defines `LovrConfiguration` with the `lovr.conf` callback fields. `crates/lunette-generate-definitions` generates the checked-in definition from that metadata.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

The development launch belongs to `make run`, not the Nix shell. The shell supplies build and runtime dependencies without changing which configuration an ordinary invocation loads. Exporting checkout paths from the shell made development behavior depend on entering Nix and obscured the installed defaults. The launch target supplies those paths explicitly and works in either environment.

Packaging tests are a narrow exception to the restrictions on real subprocesses and filesystem access. They invoke the actual Make installation rules and load a real ELF dependency chain in an isolated filesystem tree. A fake Cargo driver supplies controlled build artifacts; SteamVR and graphics hardware are not required. Pure fakes cannot establish which linked library Make discovers, whether installed rpaths resolve, or whether the action bundle accompanies that library. The exception covers packaging behavior only, like the listener and exit-status exceptions. It does not permit unrelated subprocesses, runtime launches, or network access. `crates/lunette/tests/fixtures/install.py` implements this exception through `make check-install`.

Compositor tests connect over a socketpair, not a bound socket. `Connection::from_socket` and `DisplayHandle::insert_client` both take a `UnixStream` directly, so a test gives one end of a `UnixStream::pair()` to each side and the filesystem is never involved. Only the listener's own tests — bind, listen, accept, and socket-path selection — bind a real socket, in a per-test temporary directory, because that is the code under test. The real socket in [Build and development](build-and-development.md#testing) means a real Wayland connection, not a real path on disk.

The exit status is tested by spawning the binary, which is a narrow exception to the restriction on real subprocesses. `boot::run` returns an `ExitCode`, which is opaque and carries no accessor, and the code that produces it cannot be reached without a live LÖVR Lua thread, so the status is observable only from outside the process. `crates/lunette/tests/exit_status.rs` runs the binary against a fixture configuration directory that opens no window and disables the audio, graphics, and headset modules, so no display, XR runtime, or sound device is needed. `lovr.filesystem.setIdentity` creates a save directory on every run and fails the boot when it cannot, so each run points `XDG_DATA_HOME` at its own temporary directory and each fixture carries a distinct identity. That keeps the write inside the temporary directory, keeps two parallel runs from racing to create one shared leaf, and makes the run independent of `HOME` and of the running uid having a passwd entry. The exception exists because reading the status from the wrong Lua stack slot once made every exit report success while the suite stayed green.

The Lua tests run in an in-process state, not in a session of the binary. A run through the binary was rejected: it needs a fixture configuration and a temporary data directory, reports every file as one test, and reaches neither the plugin host's failure reports nor a fake of the native API, which left plugin tests to Rust harnesses that each built a state of their own. The in-process state gives every test file the same harness and reports each file separately. It keeps LÖVR's own math rather than a hand-written matrix fake, whose translation-only arithmetic could not see a rotation.

`lunette --dump-config` writes the default configuration embedded in the binary, not the one installed under `$SYSCONFDIR/xdg/lunette`. That directory is fixed when the binary is built, so a binary that was never installed, such as one run from a source tree, had nothing to copy and failed, and an installed binary could copy a configuration another version installed. The embedded files are the ones written against the module roots this binary mounts. The `.luaurc` beside them names the Lua root by the resolution a session uses rather than by a path beside the executable: resolving one relative to the executable was considered and not taken, because it would add a third candidate a session does not use, and a configuration whose `.luaurc` names roots its session does not mount checks clean and fails to load.

Development-only application launch belongs to `dev/`, outside the installed module roots. A terminal spawn in the default desktop was rejected because a normal session must not select or start an application implicitly. A local plugin retains context-owned subscriptions and cleanup without adding a shipped desktop setting or module alias.

## Known gaps

Named, not solved.

The automatic VR input fixture verifies callback delivery and recorded geometry, not hardware presentation. `manual_xr_widget_and_manager_acceptance` remains open. It covers controller-only wrist-menu discovery, both-hand capture/grab/scroll, keyboard readability and placement, search and configuration editing, errors and overflow, panel movement/close/reopen, application focus hand-off, and reload on the target headset/runtime.

The hardware-free packaging harness verifies installation with controlled artifacts; clean-build and clean-install acceptance for the actual project remain separate checks. Configuration metadata and generated definitions describe the shipped `auto` selection. Full SteamVR binding acceptance, overlay coexistence, and headset visual acceptance remain unverified. Recorded controller and scene-registration observations appear in [Input](input.md#known-gaps) and [Rendering](rendering.md#known-gaps); they do not complete those acceptance checks. WebXR build validation is blocked because `emcmake` is unavailable; no passing WebXR build is claimed. An opt-in hardware check must report missing prerequisites as blocked, not as a pass.

There is no flake package output, so `nix build` produces nothing and the install path is the `Makefile`. The blocker is the one [Nix](#nix) already names: LÖVR's `deps/` are nested submodules, and a flake source does not carry submodules unless it is fetched with `submodules=1`, so a derivation building from `./.` would find `vendor/lovr` empty. The `Makefile` installs the binary, the LÖVR shared libraries, the Lua artifacts named by the module-root manifest, and the default configuration at the documented paths. It also installs the OpenVR action bundle when enabled. The executable resolves its own libraries through the `$ORIGIN/../lib/lunette` rpath entry. The installed configuration-copy workflow has not been validated as an installed-session test.

The end-to-end tests are Rust and not the shell script [Testing](#testing) originally described. They drive the same two binaries over the same socket; a shell script would add a second harness to keep in step and report failures worse. The part of that description that is not yet met is the client: a headless fixture switches the graphics module off, so no device is lent to the compositor thread, the thread does not start, and nothing can connect to the Wayland socket. That half needs the GPU-headless tier and is recorded as a gate in [milestone 0 findings](2026-08-06-milestone-0-findings.md#outstanding) until it exists.
