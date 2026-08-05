# LÖVR integration

## The fork

LÖVR lives at `vendor/lovr` as a git submodule pointing at the lunette fork, tracking upstream on a branch. The checkout baseline is `v0.19.0-131-gfdf1669f`.

Its `deps/` are themselves submodules (glfw, luajit, openxr, glslang, joltc, msdfgen, phonon, tracy, vulkan-headers), so cloning is recursive.

lunette forks LÖVR rather than carrying a patch series. Every file that needs a change would otherwise require constant rebasing, since LÖVR moves weekly. A branch resolves each conflict once. Two rules keep the fork disciplined.

- Patches stay narrow and additive: new accessors, new struct fields, new build options. They introduce no behavioural changes to existing paths.
- Each patch is shaped as an upstream pull request and opened early. External texture import is a feature other LÖVR users want. If it lands upstream, the divergence from upstream shrinks toward zero.

## The patch set

### 1. Vulkan handle export

LÖVR creates the Vulkan device and exposes nothing about it. `lovr.graphics.getDevice()` returns names and IDs only (`inspiration/lovr/src/api/l_graphics.c`). The compositor needs the actual handles to import dmabufs onto the same device.

The patch adds a C-level accessor returning `VkInstance`, `VkPhysicalDevice`, `VkDevice`, queue family index, and queue. It is not exposed to Lua; it exists only for the Rust side.

### 2. Foreign image import

`TextureInfo` already carries a `handle` field (`inspiration/lovr/src/modules/graphics/graphics.h:237`), and `gpu_texture_info` likewise, so LÖVR can already wrap an existing `VkImage`. What is missing is everything around it. The image is created by the native layer from imported memory, arrives in a foreign queue family (`VK_QUEUE_FAMILY_FOREIGN_EXT`), and has an undefined layout. LÖVR must not assume it owns the image's lifecycle.

This patch carries the most unknowns of the set. Milestone 0 exists to resolve them ([Roadmap](roadmap.md)).

### 3. Static library target

LÖVR offers `LOVR_BUILD_EXE` and `LOVR_BUILD_SHARED` but no static target. The patch adds `LOVR_BUILD_STATIC` so lunette links into one binary. This removes the need for `rpath` handling, for a `.so` kept in lockstep with the executable, and for an ABI surface kept stable across submodule bumps.

### 4. Embedding entry point

`main.c` owns the Lua state, the boot sequence, and the restart loop. These pieces must be callable from Rust without `main()`. The patch factors the body into functions the binary can drive.

### 5. Raise `MAX_LAYERS`

`MAX_LAYERS` is hard-coded to 10 (`inspiration/lovr/src/modules/headset/headset.h:9`). The patch makes it configurable at build time. The runtime imposes its own cap regardless, but 10 is low for a window manager that wants a layer per panel.

### Possibly later

- External semaphore import, so client work can be ordered against LÖVR's reads under `linux-drm-syncobj-v1`. Not needed for v1; see [Rendering](rendering.md#synchronisation).
- `VkSamplerYcbcrConversion`, for sampling multi-planar buffers directly rather than converting.

## Capabilities available without a patch

The following require no change to LÖVR.

- Overlay sessions. `XR_EXTX_overlay` is requested when `t.headset.overlay` is set (`headset.c:509`), and LÖVR switches the layer to alpha-blended when overlay or passthrough is active (`headset.c:3067`).
- Composition layers. `lovr.headset.newLayer` takes position, orientation, dimensions, `curve`, viewport, and `getTexture`. Quad and cylinder layers are the same mechanism WayVR uses for legible screens.
- `setLayers{ main = false }` disables the projection layer entirely. An overlay showing only quad layers can skip scene rendering altogether.
- Custom events. `lovr.event.push(name, ...)` dispatches through `lovr.handlers`, which `__index`es `lovr` (`etc/boot.lua:345`), so a pushed `'lunwindowopened'` calls `lovr.lunwindowopened`. Native-to-Lua event delivery needs no new machinery. The poll loop unpacks four arguments, so payloads travel as a single table.
- Filesystem mounting. `lovr.filesystem.setSource`/`mount`/`setRequirePath` allow LÖVR to be pointed at the user's config directory and to mount the standard library.
- Spatialised audio, via bundled Steam Audio. This makes [per-application audio](audio.md) a matter of routing rather than DSP.
- Windowless operation. `boot.lua:171` only opens a window if `conf.window` is set, and `lovr.graphics.newReadback` gives pixel readback, so GPU-headless testing is available.
- LuaJIT by default (`LOVR_USE_LUAJIT ON`), including its FFI for scripts that use it.

## Boot

lunette keeps LÖVR's `lovr.run` rather than replacing it. Its loop already has the required shape, and staying on it means `lovr.update`/`lovr.draw` behave exactly as LÖVR's documentation describes. Replacing it later is a one-file change, if a need for control it cannot express arises.

Per-frame work injects around the existing steps:

1. Frame start: drain the compositor channel, refresh window handles, complete texture imports.
2. `lovr.update` runs user code.
3. Layer blits are issued into LÖVR's command stream for damaged surfaces holding granted layers.
4. `lovr.draw` runs user code.
5. Frame end: `setLayers` is called once from granted claims; requests queued by Lua are sent to the compositor thread.

Config resolution: `~/.config/lunette/main.lua` if it exists, otherwise `$SYSCONFDIR/xdg/lunette/main.lua`. `lunette --dump-config` writes a copy to start from. This mirrors awesome, which falls back to the system `rc.lua` rather than copying one on first run. This avoids stale forks of a config the user never edited, and lets upgrades improve the default for users who have not customised it.

## Restart semantics

`lovr.event.restart` returns to `main.c`'s outer loop, which closes the entire Lua state and builds a fresh one in the same process, passing a `cookie` variant across. LÖVR's module state is anchored in that Lua state, so restart tears down graphics and the XR session too. Imported textures die and re-import, and Monado sees the overlay session leave and return.

Wayland clients survive, because they are owned by Rust outside the Lua state.

This is why two reload paths exist ([The Lua API](lua-api.md#reload)): soft reload for the common case, hard restart for when soft reload is not enough.

## Error handling

lunette overrides `lovr.errhand`. LÖVR's default shows an error screen and stops, which suits a game but not a window manager. The standard library installs a handler that logs the error, emits an event, and shows a floating error panel, rate-limiting identical repeats. Users can replace this handler, which is why it lives in Lua.

The native layer owns only the load-time fallback. If `main.lua` fails to load at all, no user handler exists yet, so a built-in safe mode takes over.
