# lunette v1 Implementation Plan — Phase 1: Scaffolding

**Goal:** A binary that boots LÖVR and runs a Lua script, built reproducibly from a Nix devshell.

**Architecture:** One Cargo workspace of four crates. `lunette-lovr` drives LÖVR's cmake build from `build.rs`, generates FFI bindings with bindgen because LÖVR exports no CMake interface, and links `liblovr.so` dynamically. `lunette` owns `main()` and replicates what `vendor/lovr/src/main.c` does, against symbols exported by `LOVR_BUILD_WITH_SYMBOLS=ON`. `lunette-compositor` and `lunette-capture` are skeletons in this phase; `lunette-compositor` must never depend on `lunette-lovr`.

**Tech Stack:** Rust 2024, cmake 0.1.58, bindgen, mlua 0.12 with mlua-sys `external`, Nix flake devshell, LÖVR at `v0.19.0-131-gfdf1669f`.

**Scope:** Phase 1 of 8 from `docs/dev/design-plans/2026-08-05-lunette-v1.md`.

**Codebase verified:** 2026-08-05.

---

## Acceptance criteria coverage

This is an infrastructure phase. It builds no functionality, so every task states **Verifies: None**. The design plan records these two criteria as verified operationally by this phase.

### lunette-v1.AC9: Cross-cutting
- **lunette-v1.AC9.1 Success:** A clean recursive clone builds with `nix develop` followed by `cargo build`, with no network access during the cmake step.
- **lunette-v1.AC9.2 Success:** `cargo +nightly fmt --all -- --check` and both clippy invocations from `CONTRIBUTING.md` pass.

---

## Verified starting state

The repository contains 17 tracked files, all Markdown: `CONTRIBUTING.md`, its two symlinks `AGENTS.md` and `CLAUDE.md` (mode `120000`, same blob), and 14 documents under `docs/dev/`. Branch `main`, working tree clean, **no git remote configured**.

None of the following exist and all must be created: `Cargo.toml`, `flake.nix`, `rustfmt.toml`, root `.gitignore`, `.gitmodules`, `crates/`, `lua/`, `vendor/`. The only `.gitignore` present is `inspiration/.gitignore`, containing `*`.

`inspiration/` is a gitignored directory of reference checkouts. It is read-only reference material and is never modified by this phase. `inspiration/lovr` is at exactly `v0.19.0-131-gfdf1669f`, but **every one of its `deps/` submodules is an empty directory** — it was cloned non-recursively and cannot be built. `vendor/lovr` must therefore be initialised recursively; do not assume anything verified about `inspiration/lovr/deps/`.

## Facts established by investigation

These were verified against the LÖVR checkout and upstream sources. They are the reasons the tasks below are shaped as they are.

- `LOVR_BUILD_SHARED` defaults OFF (`CMakeLists.txt:46`). When ON, `CMakeLists.txt:98-99` forces `LOVR_BUILD_EXE` OFF, `:306-308` excludes `src/main.c` from the build, and `:318-320` defines `LOVR_OMIT_MAIN` as the only `PUBLIC` definition. Rust's `main()` therefore does not collide.
- `LOVR_BUILD_WITH_SYMBOLS` defaults OFF (`CMakeLists.txt:48`). When ON, `:322-326` sets `C_VISIBILITY_PRESET` to `default` instead of `hidden`. Without it, `luax_preload` and its siblings are not exported.
- Every compile definition on the `lovr` target is `PRIVATE` except `LOVR_OMIT_MAIN` (`:319`), and every include directory is `PRIVATE` (`:330-336`). LÖVR exports no CMake interface, so `build.rs` mirrors both by hand for the bindgen pass.
- The Vulkan accessors `gpu_vk_get_instance`, `gpu_vk_get_physical_device`, `gpu_vk_get_device`, and `gpu_vk_get_queue` already exist at `inspiration/lovr/src/core/gpu_vk.c:3895,3899,3903,3907`, forward-declared at `src/modules/headset/headset.c:45-48`. No patch is needed to obtain them.
- `luax_preload` is `void luax_preload(lua_State* L);` at `src/api/api.h:120`. Also required: `luax_resume` (`:128`), `luax_loadbufferx` (`:129`), `luax_vlog` (`:131`), `luax_getstack` (`:133`), `luax_setmainthread` (`:140`), `luax_close` (`:142`), `luax_checkvariant` (`:145`), `luax_pushvariant` (`:146`).
- `boot.lua` is embedded by a CMake hex-dump into a generated `etc/boot.lua.h` (`CMakeLists.txt:647-663`), written **into the source tree**, not the build directory. Rust cannot `#include` it, and generating it dirties the submodule. `build.rs` reads `vendor/lovr/etc/boot.lua` directly; the bytes are identical.
- Five libraries are built shared, not four: `libluajit` (`:151`), `msdfgen-core` (`:196`), `phonon` (`:225`), GLFW, and `libJolt` — Jolt sets `JPH_BUILD_SHARED ON CACHE BOOL ""` at `:212` despite `BUILD_SHARED_LIBS OFF` at `:211`.
- JoltPhysics is reached through `add_subdirectory(deps/joltc jolt EXCLUDE_FROM_ALL)` (`:218`). The `FetchContent_Declare(JoltPhysics ...)` lives inside joltc, not in LÖVR. `FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS` is the correct override variable: the nixpkgs `lovr` derivation (`pkgs/by-name/lo/lovr/package.nix:87`) uses exactly that variable to build inside a network-free sandbox. `FETCHCONTENT_FULLY_DISCONNECTED` is not used; CMake documents it as inappropriate for preventing first-run network access.
- `mlua::init_from_ptr`, named in the design, does not exist. The function is `pub unsafe fn get_or_init_from_ptr<'a>(state: *mut lua_State) -> &'a Lua`. It constructs with the internal `owned` flag `false`, so mlua never closes LÖVR's state — the required ownership semantics.
- mlua must not build or find its own LuaJIT, since LÖVR already builds one. This requires the `external` feature of `mlua-sys`, which is **not** re-exported through mlua's feature table, so `mlua-sys` is a direct dependency.

## Two deliberate deviations from `main.c`

Both are departures from a literal replication. They are intentional and are not defects.

**1. `arg` synthesis.** `src/main.c:43-46` sets `arg[0]` to `argv[0]`. Unmodified `etc/boot.lua:90-102` then requires `arg[1]` to name a source: if `arg[1]` is absent or begins with `-`, boot.lua prints usage and quits. Otherwise it shifts every index down by one so the source lands at `arg[0]`, and calls `lovr.filesystem.setSource(source)` itself at `etc/boot.lua:131`.

The design's statement that "`lovr.filesystem.setSource` points at `~/.config/lunette`" describes the outcome, not a call lunette makes. Rust achieves it by placing the resolved config directory at `arg[1]` and the user's own arguments at `arg[2..]`. Getting this wrong produces a usage message and a clean exit rather than a running session, which is why it is called out here.

**2. No `exit()` from inside the step.** `src/main.c:24` calls `exit(status)` directly from `step()`. From Phase 2 onward that would deny the compositor thread, the control thread, and spawned children any orderly teardown. The Rust step function returns a status to `main`, which returns an `ExitCode`. Observable behaviour in this phase is identical; the seam exists for later phases.

---

<!-- START_TASK_1 -->
### Task 1: Repository hygiene

**Verifies:** None (infrastructure).

**Files:**
- Create: `.gitignore`
- Create: `rustfmt.toml`

**Step 1: Create `.gitignore`**

Nothing currently ignores build output at the repository root, so `target/` would be picked up by `git status` from the moment Task 4 lands.

```
/target
/result
/result-*
.direnv/
```

**Step 2: Create `rustfmt.toml`**

`imports_granularity` and `group_imports` are nightly-only. Stable rustfmt warns about each and then silently skips it, so a stable-formatted file is not equivalent to a nightly-formatted one. `edition` is set explicitly because bare `rustfmt` defaults to 2015 even when `Cargo.toml` says otherwise.

```toml
edition = "2024"
style_edition = "2024"
imports_granularity = "Crate"
group_imports = "StdExternalCrate"
```

**Step 3: Verify**

Run: `cargo +nightly fmt --version`
Expected: prints a version containing `-nightly`. If the nightly toolchain is missing, install it with `rustup toolchain install nightly` before continuing — every later task depends on it.

**Step 4: Commit**

```bash
git add .gitignore rustfmt.toml
git commit -m "chore: add gitignore and rustfmt config"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Nix devshell

**Verifies:** None (infrastructure).

**Files:**
- Create: `flake.nix`

**Step 1: Write the flake**

The dependency set is the union of two nixpkgs derivations, not guesswork: `pkgs/by-name/lo/lovr/package.nix` and `pkgs/by-name/wa/wayvr/package.nix`. Read both before writing this file and copy their `buildInputs` and `nativeBuildInputs` lists.

From the `lovr` derivation: `libx11 libxrandr libxinerama libxcursor libxi libxcb libxext libxkbcommon vulkan-headers vulkan-loader libGL curl`, with `cmake pkg-config python3Minimal` as native inputs. That derivation also builds under `gcc14Stdenv` for C++ support and wraps `LD_LIBRARY_PATH` with the libraries LÖVR `dlopen`s at runtime — `vulkan-loader libGL libx11 libxcb alsa-lib libpulseaudio curl` — rather than relying on rpath.

From the `wayvr` derivation: `alsa-lib dbus libx11 libxext libxrandr libxcb libxkbcommon openssl openxr-loader pipewire`, with `rustPlatform.bindgenHook` as a native input and `SHADERC_LIB_DIR` exported.

Add `wayland` and `wayland-protocols` for the compositor crate in Phase 2.

The devshell must also export `LUNETTE_JOLTPHYSICS_SRC`, pointing at a `fetchFromGitHub` of JoltPhysics. The revision is the one `vendor/lovr/deps/joltc/CMakeLists.txt` declares in its `FetchContent_Declare(JoltPhysics ...)` block. Read that file after Task 3 completes and pin the revision it names, with its hash. Until then the export is a placeholder; Task 5's verification is what proves it correct.

This phase ships a devshell only. There is no package output — `docs/dev/build-and-development.md:33` currently promises one, and Task 9 narrows that claim.

**Step 2: Verify operationally**

Run: `nix develop --command cmake --version`
Expected: prints a cmake version, confirming the shell evaluates and the native inputs resolve.

Run: `nix develop --command sh -c 'echo $LUNETTE_JOLTPHYSICS_SRC'`
Expected: prints a `/nix/store` path.

**Step 3: Commit**

```bash
git add flake.nix flake.lock
git commit -m "build: add nix devshell"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Vendor LÖVR as a submodule

**Verifies:** None (infrastructure).

**Files:**
- Create: `.gitmodules`
- Create: `vendor/lovr` (submodule)

**Step 1: Add the submodule**

The submodule tracks upstream `bjornbytes/lovr`, with lunette's patches on a local `lunette` branch. `docs/dev/lovr-integration.md:5` and `CONTRIBUTING.md:52` both currently claim it points at a lunette-owned fork; that fork does not exist, and the repository has no git remote at all. Task 9 corrects both documents. Repointing the submodule at a lunette-owned fork is a pre-push task, recorded in the design at line 354, and is not part of this phase.

```bash
git submodule add https://github.com/bjornbytes/lovr.git vendor/lovr
git -C vendor/lovr checkout fdf1669f
git -C vendor/lovr switch -c lunette
git submodule update --init --recursive
```

The recursive init is not optional. `inspiration/lovr` demonstrates the failure mode: cloned non-recursively, every `deps/` directory is empty and the tree cannot be built.

**Step 2: Verify operationally**

Run: `git -C vendor/lovr describe --tags`
Expected: `v0.19.0-131-gfdf1669f`

Run: `test -f vendor/lovr/deps/joltc/CMakeLists.txt && echo present`
Expected: `present`. This is the check that distinguishes a recursive init from a shallow one.

Run: `git -C vendor/lovr branch --show-current`
Expected: `lunette`

**Step 3: Record the JoltPhysics revision**

Run: `grep -A5 'FetchContent_Declare(JoltPhysics' vendor/lovr/deps/joltc/CMakeLists.txt`

Take the `GIT_TAG` it names and update `LUNETTE_JOLTPHYSICS_SRC` in `flake.nix` to fetch exactly that revision. At LÖVR's pinned joltc revision the fallback is `GIT_TAG v5.5.0`, reached through a four-branch resolution chain that prefers a `JOLT_PHYSICS_ROOT` cache variable — but read the file rather than trusting that, since the pin moves when the submodule is bumped.

**Step 4: Commit**

```bash
git add .gitmodules vendor/lovr flake.nix
git commit -m "build: vendor lovr as a submodule"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Cargo workspace and crate skeletons

**Verifies:** None (infrastructure).

**Files:**
- Create: `Cargo.toml`
- Create: `crates/lunette-lovr/Cargo.toml`, `crates/lunette-lovr/src/lib.rs`
- Create: `crates/lunette-compositor/Cargo.toml`, `crates/lunette-compositor/src/lib.rs`
- Create: `crates/lunette-capture/Cargo.toml`, `crates/lunette-capture/src/lib.rs`
- Create: `crates/lunette/Cargo.toml`, `crates/lunette/src/main.rs`

**Step 1: Write the workspace manifest**

All four crates are workspace-internal, so every dependency is pinned exactly. Caret ranges let resolution drift between `cargo update` runs; an exact pin makes a bump a reviewable change.

The versions below were checked against crates.io on 2026-08-05. Note that `ash` carries build metadata in its version, and an exact pin must include it — `"=0.38.0"` does not match `0.38.0+1.3.281`.

```toml
[workspace]
members = [
    "crates/lunette",
    "crates/lunette-capture",
    "crates/lunette-compositor",
    "crates/lunette-lovr",
]
resolver = "3"

[workspace.package]
edition = "2024"
license = "GPL-3.0-only"

[workspace.dependencies]
arc-swap = "=1.9.2"
ash = "=0.38.0+1.3.281"
bindgen = "=0.72.1"
cmake = "=0.1.58"
mlua = "=0.12.0"
mlua-sys = "=0.11.0"
parking_lot = "=0.12.5"
smallvec = "=1.15.2"
smithay = "=0.7.0"
smol_str = "=0.3.6"
tracing = "=0.1.44"
tracing-subscriber = "=0.3.23"
```

Every version above except `bindgen` was checked against crates.io on 2026-08-05. **Resolve `bindgen` before writing the file** — run `cargo search bindgen` or check crates.io, and pin the exact current version. An unresolved value in a table whose whole purpose is exact pinning is worse than no pin at all, because it looks decided.

Only the dependencies a crate actually uses in this phase are declared in that crate's manifest. `lunette-compositor` and `lunette-capture` declare none yet.

**Step 2: Write the crate skeletons**

Each `lib.rs` carries module-level documentation stating the crate's boundary and responsibilities. `lunette-compositor`'s says explicitly that it must not depend on `lunette-lovr`, and why: logic-headless testing depends on that separation, and it prevents the graphics module becoming a dependency of window management.

`crates/lunette/src/main.rs` is a placeholder `fn main() {}` in this task; Task 7 writes the real one.

**Step 3: Verify operationally**

Run: `cargo metadata --format-version 1 > /dev/null`
Expected: exits 0.

Run: `cargo tree -p lunette-compositor`
Expected: the output does not contain `lunette-lovr`. This is the structural invariant the whole testing strategy rests on; check it here and whenever the compositor gains a dependency.

**Step 4: Commit**

```bash
git add Cargo.toml Cargo.lock crates/
git commit -m "build: add cargo workspace and crate skeletons"
```
<!-- END_TASK_4 -->

<!-- START_SUBCOMPONENT_A (tasks 5-6) -->
<!-- START_TASK_5 -->
### Task 5: Drive the LÖVR cmake build from `build.rs`

**Verifies:** None (infrastructure).

**Files:**
- Create: `crates/lunette-lovr/build.rs`
- Create: `crates/lunette-lovr/wrapper.h`
- Modify: `crates/lunette-lovr/Cargo.toml` (add `cmake` and `bindgen` under `[build-dependencies]`)

**Step 1: Write `wrapper.h`**

A single header including what bindgen must see:

```c
#include "api/api.h"
#include "core/os.h"
#include "util.h"
```

`api.h` brings in the `luax_*` functions and, transitively, the `Variant` type that the restart cookie needs.

**Step 2: Write `build.rs`**

Three jobs, in order.

*Configure and build LÖVR.* Use `cmake::Config` against `../../vendor/lovr` with three defines: `LOVR_BUILD_SHARED=ON`, `LOVR_BUILD_WITH_SYMBOLS=ON`, and `FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS` set from the `LUNETTE_JOLTPHYSICS_SRC` environment variable. Fail with a clear error naming the variable if it is unset, since the devshell is what provides it and building outside the devshell is the likely cause.

A build script reading the environment is the sanctioned exception to the rule in `CONTRIBUTING.md:110` that a library never reads environment variables — build scripts are given `OUT_DIR`, `TARGET`, and the rest by Cargo, and have no other channel. State that in a comment so the exception reads as deliberate.

*Locate `liblovr.so`.* LÖVR's CMake stages its outputs into a `bin/` tree, and the nixpkgs derivation sets `dontUseCmakeInstall = true`, so the `cmake` crate's install-prefix layout cannot be assumed. Search the cmake output directory recursively for `liblovr.so`. If the number of matches is not exactly one, fail with an error naming the directory searched and listing what was found. Guessing a path here produces a link error far from its cause.

*Emit link directives and the boot script.* Copy `vendor/lovr/etc/boot.lua` into `OUT_DIR`. Then emit:

- `cargo::rustc-link-search=native=<dir containing liblovr.so>`
- `cargo::rustc-link-lib=dylib=lovr`
- `cargo::rustc-link-lib=dylib=luajit-5.1` — LuaJIT is a separate shared library, and the Lua C API symbols mlua declares must have a link-time provider
- `cargo::rustc-link-arg=-Wl,-rpath,<absolute path to that dir>` for development
- `cargo::rustc-link-arg=-Wl,-rpath,$ORIGIN` for the packaged case

Use `rustc-link-arg` rather than `rustc-link-arg-bins`, so test binaries under `target/debug/deps/` also resolve the library. Cargo passes the string to `rustc -C link-arg` with no shell involved, so the literal `$ORIGIN` reaches the dynamic linker intact.

Emit `cargo::rerun-if-changed` for `wrapper.h` and for `vendor/lovr/etc/boot.lua`.

*Generate bindings.* Run bindgen over `wrapper.h`. Because every LÖVR include and define is `PRIVATE`, mirror them by hand from `CMakeLists.txt:330-336`:

- `-I vendor/lovr/src`
- `-I vendor/lovr/src/modules`
- `-I vendor/lovr/etc`
- `-I vendor/lovr/deps/luajit/src`

and the defines that apply in the default configuration: `LOVR_VK`, `LOVR_USE_GLSLANG`, `LOVR_USE_GLFW`, `LOVR_USE_PHONON`. Do not define any `LOVR_DISABLE_*`.

Allowlist the `luax_*` functions, `os_init`, `os_destroy`, `lovrSetLogCallback`, and the `Variant` type, so the generated surface stays small and reviewable.

**Step 3: Verify operationally**

Run: `nix develop --command cargo build -p lunette-lovr`
Expected: builds without errors. The first run compiles LÖVR and takes several minutes.

Run: `find target -name 'liblovr.so' | head -1 | xargs nm -D | grep -c luax_preload`
Expected: `1`. A `0` means `LOVR_BUILD_WITH_SYMBOLS` did not take effect and visibility is still hidden.

Run the build with networking disabled if the environment allows it, to confirm AC9.1's no-network-during-cmake requirement.

**Step 4: Commit**

```bash
git add crates/lunette-lovr/
git commit -m "build: drive the lovr cmake build from build.rs"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: The `lunette-lovr` FFI surface

**Verifies:** None (infrastructure).

**Files:**
- Modify: `crates/lunette-lovr/src/lib.rs`

**Step 1: Expose the generated bindings**

Put the bindgen output behind a `raw` module, so every unsafe C symbol is reached through a name that says what it is. Apply `#![allow(non_camel_case_types, non_snake_case)]` scoped to that module only, with a comment noting these are generated C names.

**Step 2: Expose `boot.lua`**

```rust
pub const BOOT_LUA: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/boot.lua"));
```

This must live in `lunette-lovr`, not in the binary crate. `OUT_DIR` resolves to the `OUT_DIR` of the crate being compiled, and only `lunette-lovr` has a build script that puts the file there.

**Step 3: Add safe wrappers**

Thin wrappers over `os_init`, `os_destroy`, and `lovrSetLogCallback`. Keep them minimal — the boot sequence itself lives in the binary, and this crate's job is the FFI surface, not orchestration.

No `unwrap()` or `expect()`. Where a wrapper can fail, return a manually-implemented error type per `CONTRIBUTING.md`: implement `Display` and `Error` by hand rather than using `thiserror`, and lead the `Display` with a `lovr:` context prefix.

**Step 4: Verify operationally**

Run: `nix develop --command cargo clippy -p lunette-lovr --all-targets --all-features -- -D warnings -W clippy::unwrap_used -W clippy::expect_used`
Expected: no warnings.

**Step 5: Commit**

```bash
git add crates/lunette-lovr/src/lib.rs
git commit -m "feat: expose the lovr ffi surface"
```
<!-- END_TASK_6 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_TASK_7 -->
### Task 7: Boot LÖVR from Rust

**Verifies:** None (infrastructure).

**Files:**
- Modify: `crates/lunette/src/main.rs`
- Create: `crates/lunette/src/boot.rs`
- Modify: `crates/lunette/Cargo.toml` (add `lunette-lovr`, `mlua`, `mlua-sys`, `tracing`, `tracing-subscriber`)

**Step 1: Configure mlua linking**

```toml
mlua = { workspace = true, features = ["luajit"] }
mlua-sys = { workspace = true, features = ["external"] }
```

`mlua-sys` is a direct dependency purely to reach its `external` feature, which mlua's own feature table does not re-export. With `external` set, mlua-sys emits no link directives at all and never calls `probe_lua()`, leaving `lunette-lovr`'s build script as the sole source of link flags. Without it, mlua either vendors its own LuaJIT or probes for a system one, and collides with LÖVR's. Add a comment recording that reasoning, per the rule about commenting non-obvious feature-flag choices.

**Step 2: Write the boot sequence**

`boot.rs` replicates `vendor/lovr/src/main.c`. Structure it as two loops with the step body extracted into a named function, rather than one nested block — `CONTRIBUTING.md` calls for the top-level control flow to read like an outline.

Once, before the outer loop: `os_init()`.

The outer loop is the restart loop. Each iteration:

1. `luaL_newstate()`
2. `luax_setmainthread(L)`
3. `luaL_openlibs(L)`
4. `luax_preload(L)`
5. Build the `arg` table. `arg[0]` is the executable path from `argv[0]`; `arg[1]` is the resolved config directory; `arg[2..]` are the user's own arguments. The restart cookie is stored as field `"restart"` via `luax_pushvariant`. Set it with `lua_setglobal(L, "arg")`.
6. Push `luax_getstack` as the message handler
7. `luax_loadbufferx(L, BOOT_LUA, len, "@boot.lua", NULL)`
8. `lua_pcall(L, 0, 1, -2)`; on failure, log the error through `tracing` at error level and return a failure `ExitCode`
9. `lua_tothread(L, -1)` — boot.lua returns a coroutine
10. `lovrSetLogCallback(luax_vlog, T)`
11. Run the inner step loop

Model the step's outcome as an explicit enum rather than a bool, since the caller must distinguish three cases:

```rust
enum Step {
    Continue,
    Restart,
    Exit(i32),
}
```

`luax_resume(T, 0)` returning `LUA_YIELD` gives `Continue`. Otherwise, a string `"restart"` at stack index 1 gives `Restart`; anything else gives `Exit` carrying `lua_tointeger(T, -1)`.

On `Continue`, `os_sleep(0.0)` and loop. On `Restart`, read the cookie with `luax_checkvariant(T, 2, &cookie)`, zero it if its type is `TYPE_OBJECT`, clear the log callback, `luax_close(L)`, and continue the outer loop. On `Exit`, clear the log callback, `luax_close(T)`, `os_destroy()`, and return the status.

`src/main.c:24` calls `exit(status)` at that last point. Do not. Return the status so `main` can return an `ExitCode`, leaving a place for the compositor and control threads to be torn down in later phases.

**Step 3: Resolve the config directory**

In order: `$XDG_CONFIG_HOME/lunette`, then `$HOME/.config/lunette`, then `$SYSCONFDIR/xdg/lunette`.

This is the one place environment variables may be read. `CONTRIBUTING.md:110` permits it at the application entry point and forbids it in libraries, so the resolution function lives in the binary crate and the result is passed to anything that needs it.

Mounting the `mullion` standard library from `$PREFIX/share/lunette/lua` is Phase 6's work and is not done here.

**Step 4: Install logging**

`tracing-subscriber` initialises here, in `main`, writing to stderr. This is the only place a subscriber may be installed.

**Step 5: Verify operationally**

Run: `nix develop --command cargo clippy -p lunette --all-targets --all-features -- -D warnings -W clippy::unwrap_used -W clippy::expect_used`
Expected: no warnings.

Run the binary with no config directory present.
Expected: boot.lua's own error path reports that no `main.lua` was found. It must not print boot.lua's `usage: lovr <source>` message — that message means `arg[1]` was not set correctly and is the specific failure Step 2 exists to avoid.

**Step 6: Commit**

```bash
git add crates/lunette/
git commit -m "feat: boot lovr from rust"
```
<!-- END_TASK_7 -->

<!-- START_TASK_8 -->
### Task 8: Default configuration

**Verifies:** None (infrastructure).

**Files:**
- Create: `etc/xdg/lunette/main.lua`
- Create: `etc/xdg/lunette/conf.lua`

**Step 1: Write `conf.lua`**

Set `t.window` so the desktop simulator opens a window. `etc/boot.lua:176` only opens one if `conf.window` is set, so omitting this gives a running process with no visible output — which looks like a failure and is not one.

Overlay configuration (`t.headset.overlay`) belongs to Phase 2 and is not set here.

**Step 2: Write `main.lua`**

A `lovr.draw` that draws text. Follow the Lua conventions: LuaJIT 5.1 syntax, camelCase, comments ending in a period, sentence case in any headings.

**Step 3: Verify operationally**

Run the binary with the config directory pointing at `etc/xdg/lunette`.
Expected: a LÖVR window opens showing the text. This is the design's stated gate for the phase.

**Step 4: Commit**

```bash
git add etc/
git commit -m "feat: add a default main.lua"
```
<!-- END_TASK_8 -->

<!-- START_TASK_9 -->
### Task 9: Correct the build and patch-set documentation

**Verifies:** None (infrastructure).

**Files:**
- Modify: `docs/dev/lovr-integration.md`
- Modify: `docs/dev/build-and-development.md`
- Modify: `CONTRIBUTING.md`

`docs/dev/` is normative. Three of the five patches it documents are obsolete under this design, and both it and `CONTRIBUTING.md` describe a static link that this phase replaces with a dynamic one. Leaving that in place means the specification contradicts the code from the first commit.

**Step 1: Rewrite the patch set in `docs/dev/lovr-integration.md`**

Delete three patches and renumber the remainder.

- **Patch 1, Vulkan handle export (`:16-20`)** — delete. The accessors already exist at `inspiration/lovr/src/core/gpu_vk.c:3895,3899,3903,3907`, forward-declared at `src/modules/headset/headset.c:45-48`, and are exported by `LOVR_BUILD_WITH_SYMBOLS=ON`. No patch is required. Replace it with a note under "Capabilities available without a patch" recording that the accessors exist and how they are reached.
- **Patch 3, Static library target (`:28-30`)** — delete. The design abandons it at line 358: a static build would still require `libluajit.so`, `libglfw.so`, `libmsdfgen.so`, `libphonon.so`, and `libJolt.so`, because LÖVR sets `BUILD_SHARED_LIBS ON` for each, so the single-binary property is not obtained by adding a static target alone. Record that reasoning where the patch was, so the option is not reconsidered without it.
- **Patch 4, Embedding entry point (`:32-34`)** — delete. Replaced by replicating `main.c` in Rust against exported symbols. Record that `LOVR_BUILD_SHARED=ON` already excludes `src/main.c` and defines `LOVR_OMIT_MAIN`, which is what makes the replication possible without a patch.

The surviving set is three patches, matching the design at lines 243, 244, and 269: Vulkan device extensions for external memory; `gpu_import_acquire`/`gpu_import_release`; and configurable `MAX_LAYERS`. Patch 2 as currently written describes foreign image import and stays, renumbered.

**Step 2: Fix the remaining factual errors in `docs/dev/lovr-integration.md`**

- `:5` — "pointing at the lunette fork" becomes a submodule tracking upstream `bjornbytes/lovr` with patches on a local `lunette` branch, noting the repoint to a lunette-owned fork as a pre-push task.
- `:7` — the `deps/` list is incomplete. `.gitmodules` also declares `deps/lua`, `deps/luau`, `plugins/lua-enet`, and `plugins/lovr-http`.
- `:9` — "lunette forks LÖVR rather than carrying a patch series" contradicts the design's requirement at line 354 that patches stay MIT and upstreamable. Reword to describe the branch as carrying an upstreamable patch series.
- `:55` — `boot.lua:171` is stale; the line is `etc/boot.lua:176` at this revision.

**Step 3: Correct `docs/dev/build-and-development.md`**

- `:25` — the paragraph asserting that LÖVR links statically and that this removes rpath handling, a `.so` in lockstep, and a cross-submodule ABI surface is now false in every clause. Rewrite it for dynamic linking, naming the five shared libraries, and record the rpath strategy Task 5 implements.
- `:29` — "LÖVR's vendored dependencies are used as upstream intends" no longer holds: JoltPhysics is prefetched out of band and injected through `FETCHCONTENT_SOURCE_DIR_JOLTPHYSICS`. Say so, and say why (offline builds).
- `:33` — narrow "a flake with a dev shell and a package output" to a devshell; there is no package output in this phase.
- `:69` — the same stale `boot.lua:171` reference.
- `:5-19` — the layout tree lists `examples/`, which neither `CONTRIBUTING.md:22-30` nor the design includes. Remove it; the default configuration ships to `etc/xdg/lunette` and, at install time, to `$SYSCONFDIR/xdg/lunette`.

**Step 4: Correct `CONTRIBUTING.md`**

`CLAUDE.md` and `AGENTS.md` are symlinks to this file. Edit `CONTRIBUTING.md` only; do not replace the symlinks.

- `:5` — "The host is a Rust binary that statically links LÖVR" becomes dynamically links.
- `:13` — "There is no code yet" is no longer true once this phase lands.
- `:15` — the caveat that the Rust commands "describe the intended checks rather than commands that currently run" must go. AC9.2 requires them to pass, and Task 11 runs them.
- `:52` — "a submodule pointing at the lunette fork" matches the `lovr-integration.md:5` correction.
- `:22-30` — reconcile the layout block with `build-and-development.md` so the two agree.

**Step 5: Verify**

Run: `rg -n 'statically links|LOVR_BUILD_STATIC|boot\.lua:171' docs/dev/ CONTRIBUTING.md`
Expected: no matches.

Run: `rg -n 'There is no code yet|intended checks' CONTRIBUTING.md`
Expected: no matches.

**Step 6: Commit**

```bash
git add docs/dev/lovr-integration.md docs/dev/build-and-development.md CONTRIBUTING.md
git commit -m "docs: correct the build and patch-set documentation"
```
<!-- END_TASK_9 -->

<!-- START_TASK_10 -->
### Task 10: Record the compositor testing carve-out

**Verifies:** None (infrastructure).

**Files:**
- Modify: `CONTRIBUTING.md` (the testing conventions block at `:295-300`)
- Modify: `docs/dev/decisions.md` (the "Recorded decisions" section)

This resolves a genuine contradiction, decided by the maintainer on 2026-08-05. `CONTRIBUTING.md:299` states that tests must be deterministic with "no real subprocesses, no real filesystem, no wall-clock sleeps, no network". But `docs/dev/build-and-development.md:67` and the design's Phase 2 gate at line 256 both specify logic-headless tests using a `smithay-client-toolkit` client "against a real socket" — and a Wayland listening socket is both a filesystem object and a socket. Phase 2 cannot be written until this is settled, and `docs/dev/decisions.md` currently records nothing about testing at all.

Investigation for Phase 2 established that the conflict is almost entirely avoidable. `wayland_client::Connection::from_socket(UnixStream)` and `DisplayHandle::insert_client(UnixStream, ...)` both accept a stream directly, so a test can create a `UnixStream::pair()` and give one end to each side. That path binds nothing, touches no filesystem, and reads no environment variable. It is the default for every compositor test.

Two things still need saying, which is why this task exists rather than being dropped.

**Step 1: Amend the rule**

`CONTRIBUTING.md:299` currently reads:

> Tests must be deterministic: no real subprocesses, no real filesystem, no wall-clock sleeps, no network. Route each of those through the seam traits above and substitute the fake. Gate a fake behind `#[cfg(any(test, feature = "test-fakes"))]` when integration tests need it too.

Add a narrow exception after it, in the same register. State that compositor tests connect a client over an in-process `UnixStream::pair()` rather than a bound socket, so the rule holds unchanged for almost all of them. State that the small number of tests covering the listener itself — bind, listen, accept, and socket-path selection — may bind a real socket in a per-test temporary directory, because that code path is the thing under test and cannot be exercised any other way. Note that the exception covers the listener only: it does not license real subprocesses, real network access, or wall-clock sleeps, and the rule at `:140` still governs how a test waits for a client to map a surface.

Also record that `Connection::connect_to_env()` must never be used in tests. It calls `env::remove_var("WAYLAND_SOCKET")` internally, which mutates the process environment and is unsound in a multithreaded test binary. `Connection::from_socket` is the only form tests use.

**Step 2: Record the decision**

Add a paragraph to `docs/dev/decisions.md` under "Recorded decisions". Match the surrounding style: one paragraph, a declarative first sentence naming the decision, then its reasoning. Record that compositor tests connect over a socketpair by default, and that only the listener's own tests bind a real socket. That section exists so settled questions are not reopened by accident, which is exactly the risk here — `docs/dev/build-and-development.md:67` says "a real socket", and without this entry someone will read that as licence to bind one everywhere.

**Step 3: Verify**

Run: `rg -n 'socketpair|UnixStream::pair' CONTRIBUTING.md docs/dev/decisions.md`
Expected: matches in both files.

**Step 4: Commit**

```bash
git add CONTRIBUTING.md docs/dev/decisions.md
git commit -m "docs: record the compositor testing carve-out"
```
<!-- END_TASK_10 -->

<!-- START_TASK_11 -->
### Task 11: Full check suite

**Verifies:** None (infrastructure). This task is what makes `lunette-v1.AC9.2` observable.

**Files:** None created or modified, beyond any formatting the first command applies.

**Step 1: Run every check from `CONTRIBUTING.md:171-175`, verbatim**

```bash
cargo +nightly fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings -W clippy::unwrap_used -W clippy::expect_used
cargo clippy --all-targets --no-default-features -- -D warnings -W clippy::unwrap_used -W clippy::expect_used
cargo test --workspace
cargo test --workspace --no-default-features
```

Run all five inside `nix develop`.

`cargo test --workspace` passes with zero tests collected. That is the correct result for an infrastructure phase, not a gap — the design records this phase as building no functionality, and the first tests arrive in Phase 2.

If the fmt check fails, run `cargo +nightly fmt --all` and inspect the diff before committing it. The nightly-only options mean a stable-formatted file will differ, so confirm the toolchain is nightly rather than assuming the diff is spurious.

**Step 2: Verify AC9.1 from a clean clone**

```bash
git clone --recursive <repo> /tmp/lunette-clean-clone
cd /tmp/lunette-clean-clone
nix develop --command cargo build
```

Expected: succeeds. Run it with networking disabled if the environment permits, since AC9.1 requires no network access during the cmake step. Remove the clone afterwards.

**Step 3: Commit**

Only if the fmt check produced changes:

```bash
git add -u
git commit -m "style: apply nightly rustfmt"
```
<!-- END_TASK_11 -->

---

## Done when

- `nix develop` followed by `cargo build` succeeds from a clean recursive clone, with no network access during the cmake step.
- The binary opens a LÖVR window and runs a `main.lua` that draws text.
- All five check commands from `CONTRIBUTING.md:171-175` pass.
- `docs/dev/` no longer describes a static link or the three obsolete patches, and the testing carve-out is recorded in `docs/dev/decisions.md`.

## Deliberately not in this phase

- `xwayland-satellite` and `CREDITS.md` — Phase 2, per the design's component lists at lines 248 and its AC9.3 coverage.
- Mounting the `mullion` standard library — Phase 6.
- `t.headset.overlay` and any XR session configuration — Phase 2.
- Repointing `vendor/lovr` at a lunette-owned fork — a pre-push task recorded in the design at line 354. The repository has no git remote yet, so there is nothing to point at.

  This is genuinely outside every phase, which means it currently has no owner. Task 9 records it in `docs/dev/lovr-integration.md` as an explicit pre-push step rather than leaving it implicit, so it is not discovered at the moment of the first push.
