# LÖVR integration

## The fork

LÖVR lives at `vendor/lovr` as a git submodule pointing at `philpax/lovr`, a fork of `bjornbytes/lovr`, with lunette's patches on its `lunette` branch. That branch is rebased onto upstream `dev` rather than merged, so the patch set stays a series that can be read and proposed one commit at a time.

Its `deps/` are themselves submodules (glfw, lua, luajit, luau, openxr, glslang, joltc, msdfgen, phonon, tracy, vulkan-headers), as are `plugins/lua-enet` and `plugins/lovr-http`, so cloning is recursive.

The patches live on a branch rather than as a rebased series against each upstream commit. Every file that needs a change would otherwise require constant rebasing, since LÖVR moves weekly. A branch resolves each conflict once.

One rule holds for every patch: it stays narrow and additive — new accessors, new struct fields, new build options — and introduces no behavioural change to an existing path. A patch fixing an upstream defect is the exception, because the defect is on an existing path; it changes what it fixes and no more, and says which defect and why the fix belongs upstream.

The series is ordered by how long a patch is expected to live, oldest-lived first, so that a patch which lands upstream is dropped from the top without disturbing what sits below it.

**Integration plumbing**, at the base. What LÖVR-as-a-library needs to be embedded the way lunette embeds it: the `deps/luau` pin, `LOVR_EXPORT_LUA_SYMBOLS`, and `LOVR_LUAU_ANALYSIS`. These are not written against a feature anyone has asked for, so they are not proposed upstream, and they are expected to stay. Each is a build option defaulting to off, which is what keeps them narrow: an upstream build that does not set them compiles exactly as it did before.

**Upstream defects**, next. Bugs on a path lunette uses that are nobody's fault but upstream's: the module loader registered into `package.searchers` under `LOVR_USE_LUAU`, where Luau reads `package.loaders`, and `conf.lua` going unread when a project has no `main.lua`. These are reported upstream and disappear when fixed there.

**Upstreamable features**, on top. Work other LÖVR users want: external texture import, the layer limits, the session accessor. Each is shaped as a pull request. If they land, the divergence from upstream shrinks to the base.

Nothing has been proposed upstream yet.

LÖVR's Lua is Luau, from a second submodule: `vendor/lovr/deps/luau` points at `philpax/luau`'s `lunette/luau-bump` branch, lunette's fork of `bjornbytes/luau`'s `lovr` branch against upstream `luau-lang/luau`. The fork is merged from upstream rather than rebased, so the sync is a merge of `master` into the branch. What lunette keeps fork-owned is the LÖVR work upstream Luau does not carry: the quaternion type and `quaternion.*` library, the vector call surface mullion depends on, and the Lua 5.1 C-API shims (`lua_errorL`, the two-argument `lua_pushcfunction`/`lua_pushcclosure`, `luaL_ref`/`luaL_unref`, `luaL_getsubtable`). Upstream Luau now provides a native vector type, which the fork adopts; the fork layers the LÖVR-facing vector methods on top of it. The fork also carries what lunette's bindings need that upstream's `Custom/` component would otherwise provide in full: `lua_getmetatablepointer`, `lua_gcdump`, and a `LUAI_MAXCSTACK` large enough for mlua's registry-index arithmetic. Sync cadence is per LÖVR release; a merge is exercised by running `lunette check` against the tree it typechecks.

## The patch set

The three tiers are described above, and the series is ordered as they are listed here.

### Integration plumbing

#### The `deps/luau` pin

`deps/luau` points at lunette's Luau fork rather than `bjornbytes/luau`, for the reasons given above.

#### `LOVR_EXPORT_LUA_SYMBOLS`

LÖVR built shared carries a Lua, and an embedder may want to link the Lua C API out of it rather than bring a second one — which is what mlua does here. Nothing in LÖVR references those symbols, so `--as-needed` drops the archive members defining them and the exports go with them. The option adds `--undefined=` for each, which forces the member in and lets the default visibility export it, and links `Luau.Require` and `Luau.Config` so `luarequire_pushproxyrequire` exists to export.

#### `LOVR_LUAU_ANALYSIS`

Luau ships a type checker LÖVR does not build. `lunette check` drives it, and it has to be linked into the library rather than into the consumer's binary: two copies of Luau in one process unify their FFlag statics as GNU unique symbols, so a flag registers onto `FValue<bool>::list` twice, its `next` points at itself, and static initialisation spins on the first traversal. Nothing references the archive, so `--undefined=` will not do — it takes one symbol at a time, and the surface is C++ — and the whole archive goes in.

Off by default, and it costs several megabytes in the library.

Four things about driving it are worth stating, because each was found by a check that appeared to pass.

A check can pass while checking nothing, and this is the failure mode of the whole area. `luau-analyze --formatter=plain` exits zero unconditionally, because luacheck's contract is that the output is parsed rather than the status read. `declare pcall: any` and its neighbours overwrite Luau's own correctly-typed builtins. An unresolved require makes the analyzer skip the file entirely, so a plain error elsewhere in it goes unreported. A definitions file that fails to load means nothing is checked at all, and the low diagnostic count reads as success. `lunette check` fails on any diagnostic that is not a lint warning and on any root it never read, which is what closes the third and fourth. A low count is a claim to verify: inject `local _x: number = 's'` and confirm it is caught.

The flags decide which language is checked. `luau-analyze` calls `setLuauFlagsDefault()`, which enables every non-experimental `Luau*` flag, and without it the checker accepts a dialect current Luau has replaced: `declare class` still parses. `analyze.cpp` replicates that loop. If `lunette check` and `luau-analyze` disagree, suspect the flags first.

ariadne indexes a `Source` by character and Luau reports by byte. An offset reads too far by however many multi-byte characters precede it, which in this tree is LÖVR's `ö`.

`.luaurc` carries neither the definitions nor the platform. `platform` is rejected and reported as a diagnostic, and `definitions` is ignored in silence; both are luau-lsp client settings rather than configuration file keys. An editor also needs `"languageMode": "strict"` in `.luaurc`, without which luau-lsp reports nothing for errors `lunette check` reports, which fails in the worse direction.

### Upstream defects

#### The module loader under `LOVR_USE_LUAU`

`luax_registerloader` inserts into `package.searchers` unless `LUA_VERSION_NUM` is 501. Luau defines no `LUA_VERSION_NUM` and its package library reads `package.loaders`, so under `LOVR_USE_LUAU` the loader is registered where nothing looks. The patch adds `LOVR_USE_LUAU` to that condition.

#### `conf.lua` ignored when `main.lua` is absent

`boot.lua` loads `conf.lua` in the `else` of the check for the main file, so a project that mounts and has a `conf.lua` but no `main.lua` boots on LÖVR's defaults: every module started, and a desktop window opened. The two are independent — one configures the runtime, the other is the program — and the coupling reads as an artefact of threading one `ok, failure` pair through a chain of `elseif`s. The patch loads `conf.lua` whenever the source mounts and checks for the main file after, so the error path a missing `main.lua` produces is the one the project configured.

lunette is where this shows up as more than a wrong error screen. Safe mode is the fallback for a configuration that did not load, and a missing `main.lua` is one of the ways that happens; before the patch that one case started the audio, graphics, and headset modules the configuration had switched off and opened a window an XR overlay never wanted.

### Upstreamable features

#### External-memory device extensions

LÖVR requests no external-memory extensions when it creates the Vulkan device, so a dmabuf cannot be imported onto that device at all. The patch enables `VK_KHR_external_memory`, `VK_KHR_external_memory_fd`, `VK_EXT_external_memory_dma_buf`, `VK_EXT_image_drm_format_modifier`, and `VK_EXT_queue_family_foreign` when the physical device advertises them, and leaves them off when it does not. `VK_KHR_image_format_list`, which `VK_EXT_image_drm_format_modifier` depends on, is already enabled upstream as `formatList`.

The five are optional, not required: a driver lacking them still starts, and lunette falls back to the `wl_shm` path. Because they are optional, the patch also reports which were enabled, through five new fields on `gpu_features` and `GraphicsFeatures`. `ash::Device::load` cannot fail — a missing entry point becomes a stub that panics on call — so asking is the only way to know.

LÖVR requests `apiVersion = VK_MAKE_VERSION(1, 1, 0)` in its `VkApplicationInfo` (`src/core/gpu_vk.c`, in `gpu_init`). Vulkan 1.1 is therefore the floor for the import path, and `vkBindImageMemory2` and `vkGetPhysicalDeviceFormatProperties2` are core rather than extension entry points. Neither needs a `KHR` suffix or a separate loader.

#### Foreign image import

`TextureInfo` already carries a `handle` field (`vendor/lovr/src/modules/graphics/graphics.h`), and `gpu_texture_info` likewise, so LÖVR can already wrap an existing `VkImage`. What is missing is everything around it. The image is created by the native layer from imported memory, arrives in a foreign queue family (`VK_QUEUE_FAMILY_FOREIGN_EXT`), and has an undefined layout. LÖVR must not assume it owns the image's lifecycle.

The patch adds `gpu_import_acquire` and `gpu_import_release` to `src/core/gpu_vk.c`, modelled on `gpu_xr_acquire`. They take an explicit old layout and source queue family, and pass `VK_QUEUE_FAMILY_IGNORED` where the existing path assumes family 0.

This patch carries the most unknowns of the set. Milestone 0 exists to resolve them ([Roadmap](roadmap.md)).

#### Raise `MAX_LAYERS`

`MAX_LAYERS` was hard-coded to 10 (`vendor/lovr/src/modules/headset/headset.h:9`). The patch raises it to 64. Ten is low for a window manager that wants a layer per panel.

The constant is not made configurable. A build option would still be a compile-time bound, and true runtime configurability would mean heap-allocating the static array in the headset module and the three stack arrays in the submit path, on a hot path, to replace a number that only has to be a ceiling above the pool's budget. The budget is a policy number, and it lives in Rust.

At 64 the cost is about 6.5KB of frame stack in `lovrHeadsetSubmit`, most of it `stereoLayers`, and half a kilobyte of static state.

The two checks that guard those arrays count differently. `lovrHeadsetSetLayers` (`headset.c:2766`) counts the two composition layers a stereo layer submits; `l_lovrHeadsetSetLayers` (`l_headset.c:806`, `:817`) counts `Layer` objects. The native check binds. The patch records this in a comment and does not reconcile it, because reconciling it would change the behaviour of an existing path.

#### Expose the runtime's composition layer limit

`XrSystemGraphicsProperties::maxLayerCount` is the most composition layers `xrEndFrame` accepts, and LÖVR never read it. The patch adds `lovrHeadsetGetLayerLimit`, and `lovr.headset.getLayerLimit` on the Lua side, reading the value out of the `xrGetSystemProperties` call LÖVR already makes at connect. It reads as zero before there is a system to ask.

This is a safety requirement rather than a convenience. The specification requires `XR_ERROR_LAYER_LIMIT_EXCEEDED` once the count goes over; Monado does not implement that check, and writes past the end of a fixed array instead. Under `XR_EXTX_overlay` the array is shared with the primary application, whose layer count lunette cannot observe, so lunette budgets well below the reported limit rather than up to it. See [Rendering](rendering.md).

Monado reports 128 with a simulated HMD on Linux, which is `XRT_MAX_LAYERS`.

#### Expose which session is running

`lovrHeadsetIsActive` answers whether a session exists, and nothing answers which one. The patch adds `lovrHeadsetGetSessionGeneration`, and `lovr.headset.getSessionGeneration` on the Lua side: a counter incremented in `lovrHeadsetStart` when `xrCreateSession` succeeds, answered as zero while there is no session. The counter lives outside the headset module's state struct, which `lovrHeadsetDestroy` zeroes, so a session after a module restart cannot carry a number an earlier one had.

The boolean cannot answer the question anything holding session-owned objects has to ask. `lovr.headset.stop()` and `lovr.headset.start()` are both bound, and a configuration that calls the pair inside one callback — to reconfigure the session, which is the ordinary reason to call `stop` at all — destroys every swapchain in between while `isActive` reads true on both sides of it. lunette's layer pool reads the generation at every frame boundary for that reason, and treats a changed one as a session loss ([Rendering](rendering.md)).

#### Report whether a main session is visible

An overlay session shares the runtime with whatever holds the primary one, and `XR_EXTX_overlay` reports the primary session's visibility through `XR_TYPE_EVENT_DATA_MAIN_SESSION_VISIBILITY_CHANGED_EXTX`. LÖVR's event loop handled every other event the module reacts to and dropped that one, so an overlay could not tell whether anything was behind it. The patch handles the event, keeps the flag beside `mounted` in the headset module's state, and answers it as `lovrHeadsetIsMainSessionVisible` and `lovr.headset.isMainSessionVisible`.

An overlay that draws a background of its own is what needs it. Drawn while another application is presenting, an opaque background covers that application's frame; drawn when nothing else is, it is the only thing in the headset. WayVR decides its skybox the same way, on `!main_session_visible` and an opaque blend mode (WayVR upstream: `src/backend/openxr/mod.rs`).

The flag starts false and stays false for a session that never requested the extension, so a runtime that never sends the event reads as nothing behind. That is the direction worth being wrong in: an overlay alone in a headset draws its background, and one sharing the headset does not cover another application by accident. The metadata for the Lua binding is a matching patch to the lovr-docs fork, which is what puts it in the generated definitions.

### Rejected: a static library target

LÖVR offers `LOVR_BUILD_EXE` and `LOVR_BUILD_SHARED` but no static target. Adding one would not produce a single binary. glfw, msdfgen, phonon, and joltc are each built shared, through `BUILD_SHARED_LIBS`, `GLFW_LIBRARY_TYPE`, or `JPH_BUILD_SHARED` depending on the dependency, so a statically linked `lunette` would still ship those libraries beside itself and would still need the rpath handling a static link is meant to remove. The single-binary property costs more than one build option, which is why v1 links LÖVR dynamically ([Build and development](build-and-development.md#building)). Revisit when packaging demands it.

### Possibly later

- External semaphore import, so client work can be ordered against LÖVR's reads under `linux-drm-syncobj-v1`. Not needed for v1; see [Rendering](rendering.md#synchronisation).
- `VkSamplerYcbcrConversion`, for sampling multi-planar buffers directly rather than converting.

## Capabilities available without a patch

The following require no change to LÖVR.

- Vulkan handle access. `gpu_vk_get_instance`, `gpu_vk_get_physical_device`, `gpu_vk_get_device`, and `gpu_vk_get_queue` already exist (`vendor/lovr/src/core/gpu_vk.c`) and are forward-declared for the headset module (`vendor/lovr/src/modules/headset/headset.c:45-48`). Building with `LOVR_BUILD_WITH_SYMBOLS=ON` sets the target's C visibility to default, so `liblovr.so` exports them and Rust can call them directly. Only `lovr.graphics.getDevice()` is limited to names and IDs; the C layer is not.
- Embedding without `main()`. `LOVR_BUILD_SHARED=ON` turns `LOVR_BUILD_EXE` off (`vendor/lovr/CMakeLists.txt:98-100`), which excludes `src/main.c` from the build and defines `LOVR_OMIT_MAIN`. lunette replicates in Rust, against the exported symbols, what `main.c` does: create the `lua_State`, open the libraries, call `luax_preload`, set `arg`, run `boot.lua`, and step the closure it returns. LÖVR needs no embedding entry point of its own.
- Overlay sessions. `XR_EXTX_overlay` is requested when `t.headset.overlay` is set (`headset.c:509`), and LÖVR switches the layer to alpha-blended when overlay or passthrough is active (`headset.c:3067`).
- Composition layers. `lovr.headset.newLayer` takes position, orientation, dimensions, `curve`, viewport, and `getTexture`. Quad and cylinder layers are the same mechanism WayVR uses for legible screens.
- `setLayers{ main = false }` leaves the projection layer out of `xrEndFrame`. It saves almost nothing on its own — the colour swapchain is acquired inside `getPass` and `getTexture`, so what saves the work is not calling those ([Rendering](rendering.md#skipping-the-scene)).
- Custom events. `lovr.event.push(name, ...)` dispatches through `lovr.handlers`, which `__index`es `lovr` (`etc/boot.lua:345`), so a pushed `'lunwindowopened'` reaches lunette's own dispatcher, which calls everyone who subscribed through `lunette.onWindowOpened`. Native-to-Lua event delivery needs no new machinery. The poll loop unpacks four arguments, so payloads travel as a single table.
- Filesystem mounting. `lovr.filesystem.setSource`/`mount`/`setRequirePath` allow LÖVR to be pointed at the user's config directory and to mount the standard library.
- Spatialised audio, via bundled Steam Audio. This makes [per-application audio](audio.md) a matter of routing rather than DSP.
- Windowless operation. `etc/boot.lua` opens a window only when `conf.window` is set, and `lovr.graphics.newReadback` gives pixel readback, so GPU-headless testing is available.
- Luau by default (`LOVR_USE_LUAU ON`). LÖVR builds the vendored Luau fork with `LOVR_USE_LUAU`; lunette's Lua is Luau, and `lunette check` over the standard library and configurations is a standing check.

## Boot

lunette keeps LÖVR's `lovr.run` rather than replacing it. Its loop already has the required shape, and staying on it means `lovr.update`/`lovr.draw` behave exactly as LÖVR's documentation describes. Replacing it later is a one-file change, if a need for control it cannot express arises.

The one thing that loop cannot express is skipping scene rendering: it calls `lovr.headset.getPass` before it has looked at whether there is anything to draw. Rather than fork the loop for it, lunette wraps that function and `lovr.headset.getTexture` where `package.preload` registers the headset module, so each answers nothing while the scene is skipped ([Rendering](rendering.md#skipping-the-scene)). The wrapper is a Lua closure over the original, so nothing on the Rust side holds a reference into the state a reload discards.

Per-frame work injects around the existing steps:

1. Frame start: drain the compositor channel, refresh window handles, complete texture imports.
2. `lovr.update` runs user code.
3. Layer blits are issued into LÖVR's command stream for damaged surfaces holding granted layers.
4. `lovr.draw` runs user code.
5. Frame end: `setLayers` is called once from granted claims; requests queued by Lua are sent to the compositor thread.

Config resolution: `~/.config/lunette/main.lua` if it exists, otherwise `$SYSCONFDIR/xdg/lunette/main.lua`. `lunette --dump-config` writes a copy to start from. This mirrors awesome, which falls back to the system `rc.lua` rather than copying one on first run. This avoids stale forks of a config the user never edited, and lets upgrades improve the default for users who have not customised it.

## Restart semantics

`lovr.event.restart` returns to `main.c`'s outer loop, which closes the entire Lua state and builds a fresh one in the same process, passing a `cookie` variant across. LÖVR's module state is anchored in that Lua state, so restart tears down graphics and the XR session too. Monado sees the overlay session leave and return.

Imported textures die and re-import, and that is a protocol rather than a consequence. Closing the Lua state runs `gpu_destroy`, which destroys the `VkDevice` every imported image was created against, and the compositor thread holds a window onto that device. So the device is taken back from the compositor and its acknowledgement waited for before the state closes, and a new one is lent to it afterwards; the compositor then re-imports the buffers its clients still hold. `crates/lunette/src/restart.rs` states the ordering, which is exacting: performing the steps in another order is a use-after-free on the GPU rather than anything that reports itself.

Wayland clients survive, because they are owned by Rust outside the Lua state and because the compositor never speaks Vulkan to one — it imports descriptors, and a descriptor outlives the device it was imported into. A client that has drawn nothing since the restart gets its content back without redrawing. A shared-memory client is the exception: its pixels are copied out and its buffer released at import time, so there is nothing retained to re-import and the surface is restored by the client's next commit.

This is why two reload paths exist ([The Lua API](lua-api.md#reload)): soft reload for the common case, hard restart for when soft reload is not enough.

## Error handling

lunette overrides `lovr.errhand`. LÖVR's default shows an error screen and stops, which suits a game but not a window manager. The standard library installs a handler that logs the error, emits an event, and shows a floating error panel, rate-limiting identical repeats. Users can replace this handler, which is why it lives in Lua.

The native layer owns only the load-time fallback. If `main.lua` fails to load at all, no user handler exists yet, so a built-in safe mode takes over.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

The generated declarations say what LÖVR means, and the generator is where that is fixed. An argument with a documented default is optional; a callback is optional, because nothing sets one by default; a function with an empty variant and a variadic one drops the empty variant, because both accept a call with no arguments and Luau then reports the call as ambiguous. Each of these was first worked around in the calling code, and each workaround changed behaviour: `lovr.quit` returned `true` and vetoed the quit, `lovr.draw` returned `true` and dropped the frame, the laser's cursor was drawn at eight segments where the default is forty-eight, and fifteen sites spelled out an identity matrix. A declaration that is wrong about the runtime is worse than one that is missing, because the code bends to fit it.
