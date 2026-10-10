# Build and development

## Repository layout

```
lunette/
  flake.nix, flake.lock           the development shell
  Makefile                        build, run, install, and the standing checks
  Cargo.toml                      workspace
  crates/
    lunette/                      the lunette and lunctl binaries, Lua injection, frame orchestration, and plugin host
    lunette-compositor/           smithay; vendored fork of WayVR's backend/wayvr
    lunette-lovr/                 cmake build and FFI surface for LÖVR
    lunette-luau/                 the Luau type language and closed-set macro
    lunette-capture/              wrappers over wlx-capture and HidProvider, and the host clipboard client
    lunette-generate-definitions/ generates the Luau definitions, native declarations, .luaurc files, and install manifest
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
  vendor/lovr/                    submodule: LÖVR with lunette's patch branch (recursive)
  vendor/lovr-docs/               submodule: the API metadata and its Luau generator
  vendor/mlua/                    submodule: mlua with lunette's Luau ABI patches
  docs/dev/                       the design specification
  docs/guide/                     user-facing guides
```

`lunette-compositor` must not depend on `lunette-lovr`, so logic-headless testing stays reachable. It depends on `lunette-luau`, whose mlua feature is off by default and enabled only by `lunette`.

`lunctl` is a second binary target in `crates/lunette`, because it shares the control socket's wire format in `crates/lunette/src/control`. A separate crate would carry a second copy of the codec or depend on `lunette` anyway.

## Building

LÖVR links dynamically. `crates/lunette-lovr/build.rs` drives cmake through the `cmake` crate with `LOVR_BUILD_SHARED`, `LOVR_BUILD_WITH_SYMBOLS`, `LOVR_USE_LUAU`, `LOVR_EXPORT_LUA_SYMBOLS`, and `LOVR_LUAU_ANALYSIS` on, and with `LOVR_ENABLE_OPENVR` on for Linux. The result is `liblovr.so` and the shared libraries it needs: `libglfw.so`, `libmsdfgen.so`, `libphonon.so`, and joltc's wrapper around JoltPhysics. Luau is linked into `liblovr.so`, which exports the Lua C API that mlua resolves. The other libraries are built shared however LÖVR is linked, so a static LÖVR target would not produce a single binary ([LÖVR integration](lovr-integration.md#rejected-a-static-library-target)).

Two rpath arrangements resolve those libraries. `liblovr.so` carries `$ORIGIN/bin`, the directory LÖVR's `move_files` target stages its siblings into; an executable's `DT_RUNPATH` does not apply to a dependency's dependencies. `crates/lunette-lovr` publishes its library directories through `cargo::metadata` under `links = "lovr"`, and `crates/lunette/build.rs` reads them back and emits the binary's rpath arguments, because Cargo applies a build script's link arguments only to its own package.

The OpenVR SDK loader links statically into `liblovr.so`. It needs no SteamVR installation at build time, and loading LÖVR or running the checker does not start SteamVR. `crates/lunette-lovr/build.rs` is the source of truth for the OpenVR enablement and its build-input watches, which cover the SDK sources and the action bundle.

LÖVR's vendored dependencies in `deps/` are used as upstream builds them. They are the set upstream CI tests. JoltPhysics is the exception: `deps/joltc` fetches it through cmake's `FetchContent`. The development shell prefetches the revision `deps/joltc` declares and sets `FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS`, so configuring needs no network. Outside the shell the variable is optional, and `build.rs` warns and lets `FetchContent` fetch the same revision.

`BINDGEN_EXTRA_CLANG_ARGS` supplies the development shell's clang search paths. `build.rs` disables bindgen's include-path detection when it is set.

## Nix

The flake provides a development shell with the toolchain, the system libraries (Vulkan loader, Wayland, PipeWire, D-Bus, xkbcommon, and the OpenXR loader), and the prefetched JoltPhysics tree. It has no package output. A flake source carries submodules only when fetched with `submodules=1`, so a derivation building from `./.` finds `vendor/lovr` empty. The `Makefile` is the installation path.

`.envrc` carries `use flake`. direnv exports the environment into the running shell and leaves `SHELL` alone. `nix develop` sets `SHELL` to its own bash, and lunette passes its environment to every client it spawns, so a terminal opened from such a session would start a store shell without the user's setup.

## Module roots

`crates/lunette/src/aliases.rs` describes every module root: its alias, its runtime resolution, whether it is installed, and the explicit install artifacts. The generator derives the `.luaurc` files and the install manifest from it, and the session mounts roots from it.

| Alias | Source directory | Runtime resolution | Installation |
|---|---|---|---|
| `@lunette` | `lua/lunette/` | Native `package.preload` entry; the directory holds generated declarations for the checker | Declarations |
| `@lunette-plugin` | `lua/lunette-plugin/` | Mounted file root | Installed |
| `@lunette-contracts` | `lua/lunette-contracts/` | Mounted file root | Installed |
| `@lunette-plugins` | `lua/lunette-plugins/` | Mounted file root | Installed |
| `@lunette-desktop` | `lua/lunette-desktop/` | Mounted file root | Installed |
| `@testing` | `lua/testing/` | Mounted file root in development only | Not installed |

A session requires every installed root; `@testing` is optional. Safe mode is compiled into the binary and needs no root. A configuration cannot shadow a root with files at its own root. A module outside a `tests` directory, and the default configuration, must not require `@testing`, because an installation lacks it. [The standard library](stdlib.md#module-roots) records each root's responsibility and the relative require rules.

`make check-definitions` verifies the generated definitions, native declarations, and `.luaurc` files. `make check-luau` runs `lunette check` over the shipped roots outside their `tests` directories, the default configuration, the examples, and `dev/`, against `etc/lunette/definitions.luau`. The checker is a separate process; a session never runs it.

## Where things live at runtime

| Thing | Path |
|---|---|
| Lua roots | `$PREFIX/share/lunette/lua/` |
| Luau definitions | `$PREFIX/share/lunette/definitions.luau` |
| LÖVR and its libraries | `$PREFIX/lib/lunette/` |
| OpenVR action bundle | `$PREFIX/lib/lunette/lovr-openvr/` |
| Default configuration | `$SYSCONFDIR/xdg/lunette/main.luau` and `conf.luau` |
| User configuration | `~/.config/lunette/main.luau` |
| Control socket | `$XDG_RUNTIME_DIR/lunette/lunette-0.sock`, mode 0600 in a 0700 directory |
| Binaries | `$PREFIX/bin/lunette` and `$PREFIX/bin/lunctl` |
| Saved state | LÖVR's save directory |

The Lua root directory is `$LUNETTE_STDLIB_PATH` when set, and `$PREFIX/share/lunette/lua` otherwise. A relative override resolves from the working directory. The configuration directory is `--config-path`, then `$LUNETTE_CONFIG_PATH`, `$XDG_CONFIG_HOME/lunette`, `$HOME/.config/lunette`, and `$SYSCONFDIR/xdg/lunette`. `lunette check` with no paths checks that directory; given paths, it checks each file and each directory's files.

`make install` honours `PREFIX`, `SYSCONFDIR`, and `DESTDIR`. `PREFIX` and `SYSCONFDIR` reach the binary as `LUNETTE_PREFIX` and `LUNETTE_SYSCONFDIR` through `option_env!`. The `Makefile` targets are the source of truth for installation:

- `install-binary` builds, finds the linked `liblovr.so` through the executable's rpath, installs it with its staged libraries and any `lovr-openvr/` bundle beside it, and sets the installed binaries' rpath to `$ORIGIN:$ORIGIN/../lib/lunette`. It requires `patchelf`, selected by `PATCHELF`.
- `install-lua` installs the manifest that `lunette-generate-definitions --manifest` prints. A root directory installs its `.luau` files outside `tests` directories. Explicit artifacts install at their listed destinations whatever their extension: the definitions, the installed `.luaurc`, the Arcade theme font and its licence ([Credits](../../CREDITS.md#space-mono)), and the OpenVR SDK licence as `licenses/OpenVR.txt`.
- `install-config` installs the default `main.luau` and `conf.luau`.

Installation is not transactional; a late failure can leave a partial tree.

`lunette --dump-config DIR` writes the default configuration from copies embedded in the binary (`crates/lunette/src/cli.rs`) and a `.luaurc` naming the Lua root a session would mount by an absolute path. It refuses when that root does not exist. From a source tree, `LUNETTE_STDLIB_PATH=lua cargo run -- --dump-config DIR` names the tree's roots.

The OpenVR action manifest and controller bindings live in `lovr-openvr/` beside the real `liblovr.so` file, in both the build and installed layouts. Resolution uses neither a symlink's directory, a checkout path, nor a SteamVR path. The bundle and its ancestry must have trusted ownership, no untrusted write permission, and no symlinks, so a fixture under `/tmp` does not qualify. CMake stages the bundle after linking the library; deleting a staged asset alone does not trigger restaging, and installation rejects an incomplete bundle.

## The development loop

`make run` starts the working copy with `LUNETTE_STDLIB_PATH` set to the repository's `lua/` and `LUNETTE_CONFIG_PATH` set to `dev/`. `make run ARGS="--config-path etc/xdg/lunette"` selects the shipped configuration; the flag outranks the variable. Plain `cargo run` uses the installed defaults unless those variables are set. The workspace's `default-members` is `crates/lunette` and its `default-run` is `lunette`, so a bare `cargo build` or `cargo test` covers that crate alone, and the standing checks pass `--workspace`.

The shipped desktop starts no application. The `dev/` configuration inserts `dev/plugins/demo-terminal`, which launches a terminal when no window is open. Its plugins load by relative `require`, add no alias, and are not installed. `dev/examples` links to `../examples`. `dev/conf.luau` uses the separate `lunette-dev` save identity.

LÖVR's desktop simulator is the everyday environment. It runs without an XR runtime, in a desktop window, with WASD and mouse control. The compositor, clients, panels, and input are real; only the headset is simulated. In the simulator, lunette is a Wayland client of the host desktop with its own nested compositor.

lunette binds the first free socket from `wayland-20` upwards and logs the name. `WAYLAND_DISPLAY=wayland-20 <app>` from a host terminal connects an application as an adopted process ([Compositor](compositor.md#adoption)).

`LUNETTE_IMPORT_QUEUE_FAMILY` (`foreign` or `ignored`) and `LUNETTE_IMPORT_LAYOUT` (`general` or `undefined`) select the imported-image barrier's queue family and layout for diagnosis. `crates/lunette/src/texture/barrier.rs` defines them; an unrecognised value logs a warning and uses the default.

Soft reload ([The Lua API](lua-api.md#reload)) is the iteration loop in a headset.

## Testing

[CONTRIBUTING.md](../../CONTRIBUTING.md) lists the standing checks that `make check` runs, and states the narrow exceptions for compositor listener tests, the exit-status test, and the installation tests.

Logic-headless testing is a design constraint. The compositor, capture, input routing, and process management are tested as ordinary Rust. Buffer import sits behind a trait. Compositor tests connect a `wayland-client` test client over a `UnixStream::pair()`: one end goes to `DisplayHandle::insert_client`, the other to `Connection::from_socket`, and no socket is bound.

GPU-headless testing is available but unused. LÖVR opens a window only when `conf.window` is set, and `lovr.graphics.newReadback` reads pixels back.

A readback is served when the graphics module next submits and polls. lunette's frame loop submits through its own path, so a configuration taking a readback calls `lovr.graphics.submit()` and waits on the readback rather than expecting a flush. A readback of `lovr.headset.getTexture()` taken in `lovr.update` reads the image for a frame whose draw pass has not run, and it is uniformly zero. A capture of what the headset shows is taken after the frame is submitted, against the image that frame used. A window's texture read back this way carries the client's pixels in the right orientation and colours, in `bgra8`.

### Lua tests

`crates/lunette/tests/lua/` is a `libtest-mimic` harness. It walks `lua/` and `dev/` and takes each `.luau` file directly inside a `tests` directory as a test file. Files under `tests/support/` are helpers. Any other file under a `tests` directory fails discovery.

Each test file runs in a fresh Lua state:

- Module roots resolve from the working tree under their session names and chunk names, so relative requires resolve as the checker resolves them. A file under `dev/` runs with `dev/` selected as the configuration directory.
- `@lunette` carries the real plugin runtime, key vocabularies, text boundaries, and scale steps. `testing.native()` installs the fake native API from `lua/testing/native.luau` over it.
- `lovr.math` is LÖVR's own, opened from `liblovr.so`, so poses are real `Mat4` values. Temporary math objects are drained after each case.
- `@testing/host` exposes host operations: taking plugin failure reports, shutting plugin runtimes down, the production source reload, the native error boundary with its log, garbage collection, and selecting a configuration directory for `require 'main'`.

Cases run in file order, and every case runs even after one fails. A case fails when it raises or leaves a plugin failure report that it did not take with `testing.takeReports()`. Sessions opened by `testing.start` or `testing.boot` during a case close after the case, whether it passed or failed; `lua/testing/suite.luau` does the closing. After the last case the runner shuts down any remaining plugin runtimes, and a failure there fails the file. A file also fails when it returns no suite or defines no cases.

The runner's own trials are named `runner::`. They check discovery classification, each failure outcome above, and `runner::installed_roots_load_without_development_roots`. That trial copies the install manifest into a temporary directory, rejects unsafe destinations, rejects an installed module or the shipped configuration that names a development-only root, and requires every installed module from the copy. It does not exercise LÖVR's mounted filesystem, font loading, or graphics.

`lua/testing/vr-ui.luau` drives the real frame, laser, interaction, and surfaces providers through LÖVR callbacks with per-hand controller state, and records native input, draws, and keyboard registrations. `lua/testing/render.luau` records draw calls, LÖVR transforms, and pass state, measures deterministic text boxes, and detects transform and state leaks after a drawing error. Neither rasterizes pixels or shapes text.

### Session tests

`crates/lunette/tests/lunctl.rs` and `crates/lunette/tests/safe_mode.rs` share one running-session harness in `crates/lunette/tests/session`. It starts the binary against a fixture configuration, waits for the control socket, and evaluates chunks through `lunctl`, and the safe-mode tests stop the session with a chunk and assert the status it exits with. `crates/lunette/tests/exit_status.rs` holds the one-shot sessions, which report through the process exit status: the quit status itself, relative requires, ten soft reloads, and a write that must not reach a module root. These fixtures disable graphics, so the compositor thread never starts and no client can connect. `crates/lunette-compositor/tests/` covers client traffic in-process. A spawned test removes `HOME` and `LUNETTE_CONFIG_PATH` from the child's environment, so a mislaid fixture fails rather than loading the developer's configuration.

### Native headset tests

`make check-headset` configures a separate CMake build of `vendor/lovr`, builds `headset_native_tests`, and runs the CTest `headset` label. glslang comes from `deps/glslang`. The tests inject runtime and GPU operations to cover the OpenVR backend's connection failures, cleanup, presentation, tracking, input, and graphics ownership. One isolated case calls the real loader with no runtime present, and staged artifacts exercise asset resolution.

`make check-headset-runtime OPENVR_SCENE_PID=<pid>` is an opt-in hardware check outside `make check`. The PID names a running SteamVR scene application. The target builds `lovr_openvr_coexistence` under `$(CARGO_TARGET_DIR)/openvr-coexistence` and runs it under `timeout --signal=TERM --kill-after=5s 90s`. The driver wraps the real SDK function tables, runs two 120-frame sessions with a 75-second internal deadline, observes overlay creation, destruction, and texture submission, and samples the scene PID. A missing or mismatched PID fails. The driver never launches or kills the game and never changes runtime settings.

The manual OpenVR diagnostic is the configuration in `crates/lunette/tests/fixtures/openvr-diagnostic/lunette`. It requires an OpenVR-enabled build, SteamVR, a headset, and a trusted build path. Building first keeps compilation outside the timeout:

```sh
cargo build -p lunette --bin lunette
timeout --signal=TERM --kill-after=5s 75s ./target/debug/lunette --config-path crates/lunette/tests/fixtures/openvr-diagnostic/lunette
```

A hardware run that points `XDG_CONFIG_HOME` at a fixture directory also moves the OpenXR loader away from `$XDG_CONFIG_HOME/openxr/1/active_runtime.json`. LÖVR then starts with no headset and reports no driver, no session, and a layer limit of zero, which is indistinguishable from a runtime that offers nothing. Such a run names the runtime with `XR_RUNTIME_JSON`, which the loader honours whatever `XDG_CONFIG_HOME` says. The Khronos validation layer is not in the development shell, and a run that needs it adds it.

The fixture selects OpenVR explicitly and rejects desktop fallback. It stops after 600 frames, or reports an error if its frame-driven timer reaches 60 seconds. Escape exits. Exit status 124 means the external timeout fired.

| Frames | Phase |
|---|---|
| 1 to 100 | Normal scene and panels |
| 101 to 200 | Moving panel omitted |
| 201 to 300 | Moving panel restored |
| 301 to 400 | Scene disabled at the next frame boundary; panels remain live |
| 401 to 500 | Scene restored |
| 501 to 600 | Moving panel permanently removed |

The operator checks stereo alignment, alpha, text sharpness, motion, game visibility, and overlay removal after exit. Native red and cyan squares and scene crosses share a world pose and must stay registered under head rotation. TL, TR, BL, BR, and CENTER labels show image orientation. The log reports focus and grip and pointing poses per hand. A completed run is diagnostic evidence, not binding, coexistence, or visual acceptance.

### Installation tests

`make check-install` runs `crates/lunette/tests/fixtures/install.py`. It drives the real `Makefile` rules with a fake Cargo and real ELF fixtures in temporary directories, and checks linked-build discovery, installed library resolution, and action-bundle packaging.

## Decisions

The development launch belongs to `make run`, not to the Nix shell. The shell supplies dependencies without changing which configuration an ordinary invocation loads, and `make run` works with or without Nix. Exporting checkout paths from the shell was rejected because development behaviour then depended on entering Nix and hid the installed defaults.

Lua tests run in an in-process state rather than in a session of the binary. A binary run needs a fixture configuration and data directory, reports every file as one test, and reaches neither the plugin host's failure reports nor a fake native API. The in-process state reports each file separately and uses LÖVR's own math, which a hand-written matrix fake could not match for rotations.

`lunette --dump-config` writes the configuration embedded in the binary rather than the installed one. The installed directory is fixed at build time, absent for an uninstalled binary, and possibly from another version. The `.luaurc` names the root a session would mount. Resolving roots relative to the executable was rejected because it would add a candidate that a session does not use, and a configuration could then check clean and fail to load.

Development-only application launch lives in `dev/`, outside the installed roots. A terminal spawn in the default desktop was rejected because a normal session must not start an application implicitly.

## Known gaps

There is no flake package output, for the reason [Nix](#nix) gives.

The automatic VR input fixture verifies callback delivery and recorded geometry, not presentation.

[Input](input.md#known-gaps) and [Rendering](rendering.md#known-gaps) record the hardware observations made so far. WebXR builds are not validated, because `emcmake` is unavailable. An opt-in hardware check reports a missing prerequisite as a failure, never as a pass.

Spawning a client in a session test needs the GPU-headless tier, which does not exist.

GitHub issues #21 to #30 track the hardware and host-desktop verification, and #3 tracks the layer budget against a runtime that offers no layers. A measurement taken on hardware is recorded in the Decisions or Known gaps section of the document whose subject it concerns, and the issue that asked for it links there.
