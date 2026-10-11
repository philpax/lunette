# LÖVR integration

## The fork

`vendor/lovr` is a submodule pointing at `philpax/lovr`, a fork of `bjornbytes/lovr`, with lunette's patches on its `lunette` branch. The branch is rebased onto upstream `dev`, so the patches stay a readable series. LÖVR's `deps/` (glfw, lua, luajit, luau, openxr, openvr, glslang, joltc, msdfgen, phonon, tracy, and vulkan-headers) and `plugins/lua-enet` and `plugins/lovr-http` are nested submodules, so the clone is recursive.

Patches are narrow and additive by default: new accessors, struct fields, and build options, with no behavioural change to an existing path. An upstream defect fix changes the path it fixes and states why the fix belongs upstream. The OpenVR backend is a deliberate, larger exception. It keeps LÖVR as the owner of every headset session, and it must preserve OpenXR behaviour and defaults.

`vendor/lovr/deps/luau` points at `philpax/luau`'s `lunette/luau-bump` branch, a fork of `bjornbytes/luau`'s `lovr` branch. That fork is merged from upstream `luau-lang/luau` `master` rather than rebased. It keeps the LÖVR additions upstream Luau lacks: the quaternion type and library, the vector methods layered on Luau's native vector, and the Lua 5.1 C API shims (`lua_errorL`, two-argument `lua_pushcfunction` and `lua_pushcclosure`, `luaL_ref` and `luaL_unref`, and `luaL_getsubtable`). It also carries what mlua needs: `lua_getmetatablepointer`, `lua_gcdump`, and a `LUAI_MAXCSTACK` large enough for mlua's registry arithmetic. Commit `e6430ad0` fixes optional-callback contextual inference ([below](#optional-callback-contextual-inference-in-luau)). A merge is verified by running `lunette check`.

A submodule commit is pushed to its fork before the parent pointer that names it, or a fresh clone cannot resolve it. The LÖVR and Luau commits named here are on `origin/lunette` and `origin/lunette/luau-bump`.

Nothing has been proposed upstream.

## The patch set

The series on `lunette`, oldest first:

| Commit | Patch | Kind |
|---|---|---|
| `8c8c8a59` | Point `deps/luau` at the lunette Luau fork | Integration |
| `1426fba1` | `LOVR_EXPORT_LUA_SYMBOLS` | Integration |
| `069a0a8e` | `LOVR_LUAU_ANALYSIS` | Integration |
| `1a466028` | Register the module loader where Luau looks for it | Upstream defect |
| `da4e926b` | Enable external-memory and DRM format modifier extensions when available | Upstreamable |
| `6e866d18` | `TextureInfo.foreign` for images that already hold contents | Upstreamable |
| `7b6ccb97` | `gpu_import_acquire` and `gpu_import_release` | Upstreamable |
| `106258af` | Enforce the foreign contract in the Vulkan backend | Upstreamable |
| `3f5f0b48` | Raise `MAX_LAYERS` to 64 | Upstreamable |
| `448abf5e` | Expose the runtime's composition layer limit | Upstreamable |
| `6b9d0afd` | Expose which session is running | Upstreamable |
| `3467a2f9` | Bump `deps/luau` to the updated fork | Integration |
| `b7dd0803` | Load `conf.lua` when the project has no `main.lua` | Upstream defect |
| `fa1ccc7f` | Report whether a main session is visible | Upstreamable |
| `12d6d73d` | Prefer `main.luau` under Luau | Upstreamable |
| `3f22b7d7` | Append modifier snapshots to keyboard events | Upstreamable |
| `c09b4b6c` to `6dbf5b03` | The private headset operations boundary and the OpenVR backend, twelve commits | Exception |
| `887ee1e7` | Make native initialization paths explicit | Upstream defect |
| `19c22780` | Fix material allocation and ownership failure paths | Upstream defect |
| `ce8705a1` | Expose the audio function registration table | Integration |

`git -C vendor/lovr log --oneline upstream/dev..lunette` lists the series.

### Integration plumbing

These exist because lunette embeds LÖVR as a library. The build options default to off. The audio registration table has external linkage in the shared library. These patches are not proposed upstream.

#### `LOVR_EXPORT_LUA_SYMBOLS`

mlua links the Lua C API from `liblovr.so` rather than carrying a second Lua. Nothing in LÖVR references those symbols, so `--as-needed` drops them. The option adds `--undefined=` for each symbol and links `Luau.Require` and `Luau.Config` so `luarequire_pushproxyrequire` exists to export.

#### `LOVR_LUAU_ANALYSIS`

The option links Luau's type checker into `liblovr.so` as a whole archive, for `lunette check`. It must live in the library rather than the binary: two copies of Luau in one process unify their FFlag statics as GNU unique symbols, a flag registers twice, and static initialisation loops. It adds several megabytes.

`crates/lunette-lovr/src/analyze.cpp` drives the checker. It enables every non-experimental `Luau*` flag, as `luau-analyze`'s `setLuauFlagsDefault()` does; without that the checker accepts an obsolete dialect. `lunette check` fails on any diagnostic that is not a lint warning, and on any root it never read, because an unresolved require skips a file and an unloadable definitions file checks nothing. ariadne indexes source by character while Luau reports bytes, so offsets are converted. `.luaurc` carries neither definitions nor platform; those are luau-lsp client settings, and `"languageMode": "strict"` is required for an editor to report what `lunette check` reports.

#### The audio function registration table

`lovrAudio` has external linkage and a declaration in `api.h`. The runtime declaration test registers this table without calling `luaopen_lovr_audio`, which initializes miniaudio even when `t.audio.start` is false. The table is the same immutable, sentinel-terminated function list used by the normal opener. The test compares its registered names without initializing an audio backend. This relies on lunette's `LOVR_BUILD_WITH_SYMBOLS` shared build and changes no session behavior.

### Upstream defects

#### The module loader under `LOVR_USE_LUAU`

`luax_registerloader` inserted into `package.searchers` unless `LUA_VERSION_NUM` is 501. Luau defines no `LUA_VERSION_NUM` and reads `package.loaders`. The patch adds `LOVR_USE_LUAU` to the condition.

#### `conf.lua` ignored when `main.lua` is absent

`boot.lua` loads `conf.lua` before checking for the main file. The configuration resolves from the main file's real directory, or from the source directory when no main file exists. lunette's safe mode depends on this: a configuration missing its main file must not start modules it disabled.

#### Native initialization paths

`lovrModelAnimate` ends through `lovrUnreachable` for an invalid animation property instead of leaving its locals uninitialised. The bitmap font loader keeps its image-path presence and length checks under `LOVR_UNCHECKED`, because the font file is external data. `openxrLayerSetCurve` reads layer dimensions after validating the session rather than through a getter whose early return leaves locals indeterminate.

#### Material allocation and ownership failures

Material allocation releases partial resources on failure. Texture replacement prepares its allocation and uniform data before releasing the old descriptor or texture reference. Font atlas and model material setup propagate failures through their cleanup paths. Lua constructors give temporary textures and partial materials userdata ownership before field conversion can raise, and report rejected setters instead of returning an incomplete material.

#### Optional callback contextual inference in Luau

This fix is in `deps/luau`. Luau stripped nil from an anonymous function's expected function-or-nil type but not from a named function's, so a named `lovr.conf` callback lost the closed configuration type. The fix strips nil on the named path. Making `lovr.conf` mandatory was rejected because it misstates the runtime, and requiring a `LovrConfiguration` annotation at every site was rejected as the general remedy. Focused regressions pass. The full upstream Luau suite does not pass: the updated unit suite has 231 failed cases, compared with 212 on the baseline. The comparison identifies shared fork-specific expectations and CodeGen failures; LÖVR does not link CodeGen.

### Upstreamable features

Each is shaped as an upstream pull request.

#### External-memory device extensions

LÖVR enables `VK_KHR_external_memory`, `VK_KHR_external_memory_fd`, `VK_EXT_external_memory_dma_buf`, `VK_EXT_image_drm_format_modifier`, and `VK_EXT_queue_family_foreign` when the physical device advertises them, and reports which it enabled through new fields on `gpu_features` and `GraphicsFeatures`. They are optional: without them lunette uses the `wl_shm` path. The report is necessary because `ash::Device::load` turns a missing entry point into a stub that panics when called. LÖVR requests Vulkan 1.1, so `vkBindImageMemory2` and `vkGetPhysicalDeviceFormatProperties2` are core.

#### Foreign image import

`TextureInfo.handle` already wraps an existing `VkImage`. `TextureInfo.foreign` marks one that already holds contents, so LÖVR skips the empty upload whose `VK_IMAGE_LAYOUT_UNDEFINED` barrier would allow the driver to discard them; the OpenXR path, which also passes a handle, keeps that transition. `gpu_import_acquire` and `gpu_import_release`, modelled on `gpu_xr_acquire`, take an explicit old layout and source queue family. The Vulkan backend records the flag and rejects a foreign texture without a handle, and an import barrier on a texture that is not foreign.

#### Raise `MAX_LAYERS`

`MAX_LAYERS` rises from 10 to 64. A configurable bound was rejected: a build option is still compile-time, and runtime configuration would heap-allocate arrays on the submit path to replace a ceiling. The cost is about 6.5 KB of stack in `lovrHeadsetSubmit`. `lovrHeadsetSetLayers` counts the composition layers a stereo layer submits, while `l_lovrHeadsetSetLayers` counts `Layer` objects; the native check binds, and the patch documents the difference without changing it.

#### Expose the runtime's composition layer limit

`lovrHeadsetGetLayerLimit` and `lovr.headset.getLayerLimit` report `XrSystemGraphicsProperties::maxLayerCount`, or zero before a system exists. Monado does not return `XR_ERROR_LAYER_LIMIT_EXCEEDED` and writes past a fixed array instead, and under `XR_EXTX_overlay` that array is shared with the primary application, so lunette budgets well below the limit ([Rendering](rendering.md#the-layer-pool)).

#### Expose which session is running

`lovrHeadsetGetSessionGeneration` and `lovr.headset.getSessionGeneration` report a counter incremented on each successful session creation, or zero without a session. It lives outside the headset state that `lovrHeadsetDestroy` zeroes. `lovrHeadsetIsActive` cannot distinguish a session from its replacement after `stop` and `start` in one callback; the layer pool uses the generation for that ([Rendering](rendering.md#a-lost-session-is-observed-by-the-pool-and-by-identity)).

#### Report whether a main session is visible

LÖVR handles `XR_TYPE_EVENT_DATA_MAIN_SESSION_VISIBILITY_CHANGED_EXTX` and reports it through `lovrHeadsetIsMainSessionVisible` and `lovr.headset.isMainSessionVisible`. Upstream `lovr.headset.isVisible()` also returns it as the second result; the dedicated accessor remains for existing callers. An overlay draws its own background only when nothing is behind it, as WayVR decides its skybox. The flag starts false, so a runtime that never sends the event reads as nothing behind. The lovr-docs metadata declares both results and the dedicated accessor.

#### `main.luau` as the entry point under Luau

A Luau build already preferred `conf.luau` and searched `?.luau` first, but `boot.lua` named only `main.lua`. Under Luau, the patch makes a folder or archive use `main.luau` when present and `main.lua` otherwise, accepts a single `.luau` file on the command line, and names `main.luau` in the missing-file error. The choice waits until the source is mounted. A build without Luau is unchanged. A configuration with only `main.lua` therefore still boots.

#### Physical key modifier snapshots

`lovr.keypressed` gains an optional fourth argument, and `lovr.keyreleased` an argument after the scancode: a read-only table of Shift, Control, Alt, Super, CapsLock, and NumLock state from the physical event. The GLFW backend enables `GLFW_LOCK_KEY_MODS`; a backend without a reliable snapshot passes nil. lunette uses it to tell keypad navigation from numeric input, which its virtual seat state cannot answer. Matching lovr-docs metadata generates the declarations.

### The OpenVR backend

#### The private headset operations boundary

The public `lovrHeadset*` and `lovrLayer*` functions forward through a fixed private operations table. `headset_openxr.c` holds the OpenXR and simulator implementation unchanged in behaviour; WebXR keeps its own. Selection is described in [Backend selection](#backend-selection).

A layer records its creating backend and session generation and dispatches through that backend, including destruction after its session ends. Submission validates the whole replacement list before retaining it. A layer from an inactive generation cannot be submitted.

When a session's graphics are retired, its textures, their views, and its passes become CPU tombstones: metadata stays readable and GPU operations fail, including in unchecked builds. Retirement waits for GPU quiescence before invalidating backing, drains deferred destruction before releasing runtime images, and disconnects the runtime before destroying the Vulkan device. `lovrGraphicsQuiesceSessionResources` and `lovrGraphicsDrainSessionResources` bracket a selective retirement and touch no unrelated resource. A device-loss result permits destruction; any other wait error keeps resources for a retry.

External texture handoff runs its callback under the graphics queue lock. The callback may submit on the supplied queue and release references; final destruction is deferred until the lock is released. Graphics entry points reject reentry from the callback.

#### Connection, presentation, and input

`LOVR_ENABLE_OPENVR`, off by default, builds Valve's pinned SDK loader as a static library on Linux Vulkan builds without modifying the SDK. The backend connects only as an overlay application, through the SDK's C function tables.

Panels render into session-registered textures, are packed into one two-dimensional image per overlay, and are submitted through the guarded Vulkan handoff. Overlay destruction precedes backing invalidation, and a failed destruction keeps both for a retry. At most 62 panels exist, leaving two of the 64 local slots for projection eyes; omitted panels and panels awaiting cleanup count.

The main scene renders into a two-layer texture with transparent clear, internal depth, MSAA, and reverse-Z, and each eye is copied to its own two-dimensional output for a projection overlay. A runtime resolution change needs a session restart. The backend submits no scene-compositor frames and so gives no occlusion against a game's depth.

Frame update performs the bounded overlay wait and samples a predicted head snapshot; resource getters do not wait. Accepted display timestamps equal the predicted time relative to the session epoch and never decrease. A regressed or invalid prediction exposes no pose and reports zero time and delta.

Focus means the SteamVR dashboard is closed. `IsInputAvailable` and `ShouldApplicationPause` describe the scene application and always report no input and a pause to an overlay, so they are not consulted. Mount state comes from the SDK's HMD activity, which can reflect motion or proximity. Main-scene visibility is false only on affirmative evidence that the dashboard is hidden and no scene runs.

Haptics are scheduled locally as immediate pulses of at most 20 ms. Stop, replacement, or zero strength cancels future pulses but not one already accepted. Frequency zero maps to 120 Hz, because the action API has no default-frequency sentinel. A runtime quit request produces a quit event without acknowledgement; `lovrHeadsetWillExit`, called only once the host commits to exiting, acknowledges it. It is not exposed to Lua.

The action manifest and bindings live in `lovr-openvr/` beside the real `liblovr.so`, with the trust rules in [Build and development](build-and-development.md#where-things-live-at-runtime). The backend initializes the manifest before polling events. Bindings exist for Vive, Knuckles, Touch, and Steam Frame controllers. Touch grip poses stay unbound until their transform is verified. Steam Frame controllers bind grip and aim to `openxr_grip` and `openxr_aim` and map the left d-pad to the face buttons. A controller type without a binding gets SteamVR's remapping of another type's binding, with its gaps. A failed update clears stale tracking and input.

Native tests ([Build and development](build-and-development.md#native-headset-tests)) inject runtime and GPU operations; they do not establish binding acceptance or visual correctness.

### Rejected: a static library target

LÖVR offers `LOVR_BUILD_EXE` and `LOVR_BUILD_SHARED` but no static target. A static target would not produce a single binary: glfw, msdfgen, phonon, and joltc are built shared regardless, so `lunette` would still ship them and need rpath handling. lunette links LÖVR dynamically ([Build and development](build-and-development.md#building)).

### Possibly later

- External semaphore import, to order client work against LÖVR's reads under `linux-drm-syncobj-v1` ([Rendering](rendering.md#synchronisation)).
- `VkSamplerYcbcrConversion`, to sample multi-planar buffers directly.

## Capabilities available without a patch

- Vulkan handles. `gpu_vk_get_instance`, `gpu_vk_get_physical_device`, `gpu_vk_get_device`, and `gpu_vk_get_queue` exist, and `LOVR_BUILD_WITH_SYMBOLS` exports them from `liblovr.so`.
- Embedding without `main()`. `LOVR_BUILD_SHARED` excludes `src/main.c`. lunette does in Rust what `main.c` does: creates the `lua_State`, opens the libraries, calls `luax_preload`, sets `arg`, runs `boot.lua`, and steps the closure it returns.
- Overlay sessions. `t.headset.overlay` requests `XR_EXTX_overlay`.
- Composition layers through `lovr.headset.newLayer`, with pose, size, `curve`, viewport, and `getTexture`.
- Custom events. `lovr.event.push(name, ...)` dispatches through `lovr.handlers`, which `__index`es `lovr`, so native events reach lunette's dispatcher without new machinery. The poll loop unpacks four arguments, so payloads travel as one table.
- Filesystem mounting through `lovr.filesystem.setSource`, `mount`, and `setRequirePath`.
- Spatialised audio through the bundled Steam Audio ([Audio](audio.md)).
- Windowless operation and `lovr.graphics.newReadback`, for GPU-headless testing.

## Boot

lunette keeps LÖVR's `lovr.run`, so `lovr.update` and `lovr.draw` behave as LÖVR documents. The loop cannot skip scene rendering, because it calls `lovr.headset.getPass` before anything decides whether to draw; lunette wraps `getPass` and `getTexture` where `package.preload` registers the headset module ([Rendering](rendering.md#skipping-the-scene)). The wrapper is a Lua closure, so Rust holds no reference into a state that a reload discards.

Each frame:

1. Frame start: drain the compositor channel, refresh window handles, and complete texture imports.
2. `lovr.update` runs.
3. Layer copies are recorded for damaged surfaces that hold granted layers.
4. `lovr.draw` runs.
5. Frame end: `setLayers` is called once from granted claims, and queued requests go to the compositor thread.

The configuration directory resolves as [Build and development](build-and-development.md#where-things-live-at-runtime) states, ending at the system default in `$SYSCONFDIR/xdg/lunette`. As in awesome, the system configuration is used in place rather than copied on first run, so an unedited configuration follows upgrades. `lunette --dump-config` writes a copy to edit.

## Backend selection

`t.headset.backend` accepts `auto`, `openxr`, or `openvr`, as a native enum validated by the Lua parser. The configuration metadata in `vendor/lovr-docs` defines the typed headset configuration and the closed union, and the declarations are generated from it. The upstream default is `openxr`; `etc/xdg/lunette/conf.luau` selects `auto`. `getDriver()` names the runtime, not the selector.

- `connect = false` selects desktop simulation.
- `openxr` behaves as upstream, including ordinary session fallback when the overlay extension is absent.
- `openvr` connects as an overlay application even when `overlay` is false. On failure it falls back to desktop simulation with a diagnostic, never to OpenXR.
- `auto` with an overlay request probes OpenXR with the overlay extension required, without creating a primary session. On failure it tries OpenVR, then ordinary OpenXR, then desktop simulation.
- `auto` without an overlay request tries ordinary OpenXR, then desktop simulation.

Each failed attempt releases its runtime state before the next, and at most one connection exists. Pending cleanup blocks further attempts and GPU creation. Selection freezes before Vulkan instance and device creation; a GPU or presentation-start failure does not trigger fallback. Stop and start reuse the selected backend and connection. Full teardown releases the connection before destroying Vulkan, and a fresh initialization selects again. The selected backend chooses the required adapter, and a missing one fails before device creation.

On the first completed frame, lunette warns when the resolved configuration requests headset connection and startup, the headset module is loaded, and no XR session exists. The configuration reads honor metatable inheritance, as LÖVR's startup reads do. The warning states that the desktop simulator is running instead. It names an unavailable runtime or headset, a runtime refusal, and insufficient GPU memory as possible causes, without identifying one as the cause. A runtime name from `getDriver()` does not establish that a session started; `lovrHeadsetGetSessionGeneration` supplies that observation. A session that reaches XR, disables the headset module, sets `connect = false`, or defers startup with `start = false` emits no fallback warning. The warning runs once per Lua state, including after a hard restart, and does not prevent simulation.

## Restart semantics

`lovr.event.restart` closes the Lua state and builds a new one in the same process. LÖVR's module state lives in that Lua state, so graphics and the XR session restart too, and the runtime sees the overlay session leave and return.

Before the state closes, the device is taken back from the compositor thread and its acknowledgement awaited, because closing runs `gpu_destroy`. A new device is lent afterwards and the compositor re-imports the buffers its clients hold. `crates/lunette/src/restart.rs` states the ordering; any other order is a use-after-free on the GPU. Wayland clients survive, because Rust owns them outside the Lua state and a dmabuf descriptor outlives the device it was imported into. A shared-memory client's pixels were copied at import, so its surface returns at its next commit.

Soft reload covers the common case and hard restart the rest ([The Lua API](lua-api.md#reload)).

## Error handling

lunette does not set `lovr.errhand`. An error reaching `boot.lua`'s handler has already unwound the frame loop, and the handler ends the process. Event listeners, plugin callbacks, and the frame provider's handlers therefore run under protected calls; each error is logged and emitted through `lunette.onError`. A raw `lovr.update` or `lovr.draw` in a configuration is unprotected ([The Lua API](lua-api.md#errors)). If `main.luau` fails to load, a built-in safe mode takes over.

## Decisions

Backend selection freezes before GPU creation so runtime callbacks, Vulkan extensions, and the adapter all belong to one backend. Live switching and fallback after GPU creation were rejected because the device already encodes those choices. The overlay-required OpenXR probe precedes ordinary OpenXR so a missing extension does not claim a primary session before OpenVR can supply an overlay.

OpenVR presentation uses native panels and two projection overlays rather than scene-compositor submission, so lunette remains an overlay. The overlay Vulkan descriptor cannot select a layer of an array image, so each eye has its own output. A regressed prediction is reported as unavailable rather than advancing a synthetic clock that does not match the sampled pose.

`SetOverlayTransformProjection` takes the inverse of the eye pose and a frustum of `tan(angleLeft)`, `tan(angleRight)`, `tan(angleDown)`, and `tan(angleUp)`, whose vertical pair is reversed relative to `GetProjectionRaw`. The SDK documents neither. Passing the eye pose and raw tangents made scene content move with the head while native panels stayed fixed. SteamVR's own OpenXR runtime makes the call this way, and `lovrOpenVRProjectionEye` matches it; its test derives the expected frustum from field-of-view angles. The rendered image still uses the eye pose and raw tangents.

OpenVR haptics use bounded pulses because the action interface cannot cancel a submitted vibration; the cost is possible gaps between pulses. Quit acknowledgement waits for a commitment to exit, because a quit callback can veto termination and a reload destroys the backend without exiting.

Generated declarations describe what LÖVR means, and the generator is where a wrong one is fixed. An argument with a documented default is optional, every callback is optional, and a function with both an empty and a variadic variant drops the empty one so calls are not ambiguous. Workarounds in calling code changed behaviour each time: returning `true` from `lovr.quit` vetoed the quit, and returning `true` from `lovr.draw` dropped the frame.

An array LÖVR reads from its caller is declared read-only, `{ read [number]: T }`, and an array it returns stays read-write. Luau compares a read-write indexer invariantly, so table literals matched no overload and `{integer}` did not satisfy `{number}`. The multicolour text table of `Pass:text` and `Font`'s `getLines`, `getVertices`, and `getWidth` is declared `{*}` rather than `{}`, because the new solver treats a string as a subtype of `{}` and reported every string call as ambiguous.

## Known gaps

`etc/boot.lua` discards the headset pass when `lovr.draw` returns a truthy value: `if headset and lovr.draw and lovr.draw(headset) then headset = nil end`. A configuration whose `lovr.draw` returns `true` renders nothing, while the session stays active, visible, and focused and the frame loop runs at the display's rate. The symptoms read as a runtime that accepts an overlay session and never composites it. The shipped configuration returns nothing from `lovr.draw`.

GLFW reports errors with `printf` in `src/core/os_glfw.h`, which bypasses the `lovrSetLogCallback` lunette installs, writes to stdout, and carries no level. `GLFW_BUILD_WAYLAND` is off in `vendor/lovr/CMakeLists.txt`, so LÖVR's GLFW is X11-only and a Wayland session without `DISPLAY` opens no window. With no window and no XR runtime, the simulator path calls `lovr.headset.getViewAngles` every frame, which reaches `os_window_get_size` and raises `GLFW_NOT_INITIALIZED`; one observed run wrote 112 MB in about seventy seconds. lunette exits on the first frame when the headset module is loaded and there is neither a window nor a session (`crates/lunette/src/boot.rs`). Routing GLFW's errors through LÖVR's log changes an existing path, so it belongs upstream as a pull request rather than as a carried patch.

Overlay sessions work under Monado only in service mode. In monolithic mode `multi_compositor_create` never initialises `z_order` from the session create-info, and only the IPC server calls `set_z_order`. In service mode an overlay session presents on an otherwise idle runtime, and LÖVR clears the overlay's projection layer transparent once `XR_EXTX_overlay` is enabled, so a configuration does not set a transparent background itself.

`l_lovrEventPush` allocates a custom event's `Variant` array with `lovrMalloc`, and the poll path destroys each `Variant` but never frees the array. lunette pushes payload-free events and builds the event table at dispatch (`crates/lunette/src/events/mod.rs`), which reduces each leak to the allocation `malloc(0)` returns. The fix belongs upstream.
