# Build and development

## Building

A recursive checkout is required for LÖVR and its nested dependencies. The development shell supplies Rust, nightly rustfmt, a C/C++ toolchain, CMake, bindgen/libclang, StyLua, Python, patchelf, and native Vulkan, Wayland, PipeWire, D-Bus, XKB, and OpenXR libraries. [The Makefile](../../Makefile) owns build, installation, and check commands.

```sh
git submodule update --init --recursive
nix develop
cargo clippy --workspace --all-targets --all-features -- -D warnings
```

Iterate in debug; use release for packaging or measurements. Bare Cargo commands select the main crate, not every workspace member.

LÖVR builds as `liblovr.so` with Luau and checker support. mlua resolves the Lua API from that library rather than linking another interpreter. The binary and library need separate rpaths for transitive shared dependencies. Static LÖVR would still need shared third-party libraries and would not eliminate packaging work. `crates/lunette-lovr/build.rs` owns CMake options, build-input watches, and bindgen setup.

## Nix

The flake provides a development shell, not a package output. It prefetches JoltPhysics and supplies `FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS`; outside the shell CMake may fetch it. Flake sources need `submodules=1` to include vendored trees. direnv preserves the caller's `SHELL`; `nix develop` changes it, and spawned terminals inherit that value.

## Module roots

[Alias descriptors](../../crates/lunette/src/aliases.rs) own runtime roots, generated `.luaurc` files, and install artifacts. `@lunette` is native preload; other installed roots are mounted files. `@testing` and `dev/` are development-only and must not appear in installed modules. Session startup does not run the checker.

Relative requires follow Luau's file-relative rules. A directory's `init.luau` names the directory module: `./` starts beside that directory, while `@self` starts inside it. The session wrapper resolves names into `package.loaded`, so source reload clears the same cache. Replacing it with Luau's separate require cache would break that agreement.

The [plugin categories](../../lua/lunette-plugins/README.md) organise ownership inside the existing shipped-plugin root. They add no aliases or activation entries. Public imports target leaf entries, their configuration schemas, or declared extensions and libraries. The same boundary applies to relative imports. Entry ids in settings and patches remain unchanged when source paths move. Configurations that import moved modules use the migration mapping in the plugin guide; obsolete paths have no compatibility modules.

Declaration changes belong in native registration or LÖVR metadata/generation. Regenerate and check rather than edit outputs:

```sh
cargo run -p lunette-generate-definitions
make check-definitions check-luau-annotations check-luau
```

`lunette --dump-config DIR` writes the embedded configuration and a `.luaurc` naming the selected Lua roots by absolute path. Copying the repository `.luaurc` by hand gives aliases that resolve relative to the wrong directory.

## Where things live at runtime

Installation uses `PREFIX`, `SYSCONFDIR`, and `DESTDIR`. Lua roots live under `$PREFIX/share/lunette/lua`, libraries under `$PREFIX/lib/lunette`, and the default configuration under `$SYSCONFDIR/xdg/lunette`. Installation is not transactional; failure can leave a partial tree.

The configuration search starts with `--config-path`, then `LUNETTE_CONFIG_PATH`, XDG user configuration, and the system default. `LUNETTE_STDLIB_PATH` overrides the Lua root. [The local control socket](native/lua-api.md#lunctl) lives under `XDG_RUNTIME_DIR`; saved desktop state uses LÖVR's save directory.

The OpenVR action bundle must be beside the real `liblovr.so` in `lovr-openvr/`. Its ancestry and contents require trusted ownership, no untrusted write permission, and no symlinks. A path under `/tmp` does not qualify. Deleting a staged asset alone does not trigger CMake restaging; installation rejects incomplete bundles.

## The development loop

```sh
make run
make run ARGS="--config-path etc/xdg/lunette"
```

`make run` selects the source Lua roots and `dev/` configuration; the second command selects the shipped configuration. Plain `cargo run` uses installed defaults. The shipped desktop launches no application; development launch behavior stays in `dev/`.

The desktop simulator runs real compositor, client, and input paths without an XR runtime. lunette logs its first free socket from `wayland-20`; `WAYLAND_DISPLAY=<logged-name> <app>` connects an adopted client. [Source reload](native/lua-api.md#reload) is the headset iteration path; hard restart replaces graphics.

Logs use stderr. `lunctl` inspects the running state between frames. Imported-image diagnosis can set `LUNETTE_IMPORT_QUEUE_FAMILY` to `foreign` or `ignored` and `LUNETTE_IMPORT_LAYOUT` to `general` or `undefined`. These override barriers for experiments, not portability guarantees; [validation](native/rendering-validation.md#imported-image-ownership-barriers) records limits.

## Testing

`make check` is the full standing check. Focused commands support iteration:

| Command | Purpose and prerequisites |
|---|---|
| `make check-format` | Nightly rustfmt and StyLua |
| `make check-rust` | Clippy and workspace tests across both feature sets |
| `make check-definitions check-luau-annotations check-luau` | Generated artifacts, annotation syntax, and strict source checks |
| `make check-headset` | Hardware-free native runtime/GPU seams; CMake and vendored glslang |
| `make check-graphics` | Real LÖVR rendering; Vulkan loader and explicit Mesa lavapipe ICD |
| `make check-install` | Actual installation rules; Python, C compiler, and patchelf |

Logic tests preserve the separation from LÖVR graphics. Compositor clients use an in-process socket pair rather than binding a host socket. Missing prerequisites fail their selected check rather than silently skipping. Hardware-free checks do not establish live capture, controller bindings, or presentation.

### Lua tests

The Lua integration target runs files directly under module-local `tests/` directories in fresh states. Shared local helpers belong in `tests/support/`; cross-module scaffolding lives in `lua/testing`. The harness uses the real plugin runtime and LÖVR math with a fake native API. Unconsumed plugin failures and teardown failures fail a suite. Test discovery and harness implementation live in `crates/lunette/tests/lua/`.

```sh
cargo test -p lunette --test lua
```

### Plugin dependency checks

The dependency target checks resolved production imports, including examples and development plugins, against public module boundaries. It reads the strict checker's dependency graph, using the vendored Luau parser and Navigator. The Lua and graphics suites exercise test imports; the installed-root trial loads every installed module without development roots.

```sh
cargo test -p lunette --test plugin_dependencies
cargo test -p lunette --test luau_check
```

Workspace tests run the dependency target through `make check-test` and CI. It does not replace strict Luau typechecking. Dynamic loader use, test resolution contexts, import cycles, and Markdown validation are outside its scope; it is not a sandbox.

### Offscreen graphics tests

The graphics target uses production LÖVR graphics without a window, headset, audio, filesystem, or compositor. Fixtures live under `crates/lunette/tests/graphics/fixtures/`. LÖVR modules are process-global, so the harness runs serially. Teardown must close Lua and release reachable GPU userdata before destroying native graphics.

The caller selects lavapipe explicitly; absent or hardware ICDs fail. The Nix software-driver shell sets the selection:

```sh
nix develop .#graphics -c env -u DISPLAY -u WAYLAND_DISPLAY make check-graphics
nix develop .#graphics -c env -u DISPLAY -u WAYLAND_DISPLAY make check
```

On Debian or Ubuntu, `mesa-vulkan-drivers` supplies lavapipe. `VK_DRIVER_FILES` names its ICD JSON; older loaders accept `VK_ICD_FILENAMES`.

Readbacks need submission and polling. A headset image read in update precedes that frame's draw and can be empty. Capture submitted output rather than treating an early read as presentation evidence.

The UI fixtures write PNG snapshots of the host's rendering and of every widget gallery page, in both theme modes, to `target/tmp/ui-snapshots/`. The snapshots are for review; the fixtures assert only that each page draws without a reported error and that sampled pixels have the expected colours.

### Native headset tests

`make check-headset` injects runtime and GPU operations. It validates native failure handling and ownership without SteamVR or hardware. It cannot establish bindings or visual correctness.

`make check-headset-runtime OPENVR_SCENE_PID=<pid>` is opt-in and requires SteamVR, a headset, and an already-running scene application. It checks overlay coexistence without launching or killing that application or changing runtime settings.

The manual diagnostic selects OpenVR explicitly and rejects simulator fallback:

```sh
cargo build -p lunette --bin lunette
timeout --signal=TERM --kill-after=5s 75s ./target/debug/lunette --config-path crates/lunette/tests/fixtures/openvr-diagnostic/lunette
```

Use a trusted build path. The fixture owns its phases; the operator checks stereo registration, orientation, alpha, text, motion, game visibility, and cleanup. A completed diagnostic does not close controller, coexistence, or visual acceptance. For OpenXR fixtures that change `XDG_CONFIG_HOME`, set `XR_RUNTIME_JSON` explicitly or the loader may lose the active-runtime file. Validation layers are an additional prerequisite.

## Known gaps

Live acceptance requirements remain in [audio](native/audio.md#acceptance), [input](native/input.md#known-gaps), [host desktop](native/host-desktop.md#known-gaps), and [rendering validation](native/rendering-validation.md). WebXR builds are unvalidated. Graphics-only fixtures do not run a compositor session with connected clients.
