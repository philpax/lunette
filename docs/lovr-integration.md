# LÖVR integration

## The fork

LÖVR lives at `vendor/lovr` as a git submodule pointing at our fork, tracking upstream on a branch. Our checkout baseline is `v0.19.0-131-gfdf1669f`.

Its `deps/` are themselves submodules (glfw, luajit, openxr, glslang, joltc, msdfgen, phonon, tracy, vulkan-headers), so cloning is recursive.

We fork rather than carry a patch series because every file we need to touch is a file we'd be rebasing constantly, and LÖVR moves weekly. A branch resolves each conflict once. The discipline that keeps this honest:

- **Patches stay narrow and additive.** New accessors, new struct fields, new build options. No behavioural changes to existing paths.
- **Each patch is shaped as an upstream PR** and opened early. External texture import is a feature other LÖVR users want; if it lands upstream, our divergence shrinks toward zero.

## The patch set

### 1. Vulkan handle export

LÖVR creates the Vulkan device and exposes nothing about it — `lovr.graphics.getDevice()` returns names and IDs only (`inspiration/lovr/src/api/l_graphics.c`). We need the actual handles to import dmabufs onto the same device.

Add a C-level accessor returning `VkInstance`, `VkPhysicalDevice`, `VkDevice`, queue family index, and queue. Not exposed to Lua — this is for our Rust side.

### 2. Foreign image import

`TextureInfo` already carries a `handle` field (`inspiration/lovr/src/modules/graphics/graphics.h:237`), and `gpu_texture_info` likewise, so LÖVR can already wrap an existing `VkImage`. What's missing is everything around it: the image is created by us from imported memory, arrives in a foreign queue family (`VK_QUEUE_FAMILY_FOREIGN_EXT`) and an undefined layout, and LÖVR needs to not assume it owns its lifecycle.

This is the patch with the most unknowns, which is why milestone 0 exists to answer them ([Roadmap](roadmap.md)).

### 3. Static library target

LÖVR offers `LOVR_BUILD_EXE` and `LOVR_BUILD_SHARED` but no static target. Add `LOVR_BUILD_STATIC` so `lunette` links into one binary — no `rpath` handling, no `.so` to keep in lockstep with the executable, no ABI surface to keep stable across submodule bumps.

### 4. Embedding entry point

`main.c` owns the Lua state, the boot sequence, and the restart loop. We need those pieces callable from Rust without `main()`. Factor the body into functions the binary can drive.

### 5. Raise `MAX_LAYERS`

Hard-coded to 10 (`inspiration/lovr/src/modules/headset/headset.h:9`). Make it configurable at build time. The runtime imposes its own cap regardless, but 10 is low for a WM that wants a layer per panel.

### Possibly later

- **External semaphore import**, so client work can be ordered against LÖVR's reads under `linux-drm-syncobj-v1`. Not needed for v1; see [Rendering](rendering.md#synchronisation).
- **`VkSamplerYcbcrConversion`**, if we want to sample multi-planar buffers directly rather than converting.

## What we get for free

Worth stating plainly, because it's most of why LÖVR is the right engine here:

- **Overlay sessions.** `XR_EXTX_overlay` is requested when `t.headset.overlay` is set (`headset.c:509`), and LÖVR switches the layer to alpha-blended when overlay or passthrough is active (`headset.c:3067`).
- **Composition layers.** `lovr.headset.newLayer` with position, orientation, dimensions, `curve`, viewport, and `getTexture` — quad and cylinder layers, which is exactly the mechanism WayVR uses for legible screens.
- **`setLayers{ main = false }`**, which disables the projection layer entirely. An overlay showing only quad layers can skip scene rendering altogether.
- **Custom events.** `lovr.event.push(name, ...)` dispatches through `lovr.handlers`, which `__index`es `lovr` (`etc/boot.lua:345`), so a pushed `'lunwindowopened'` calls `lovr.lunwindowopened`. Native-to-Lua event delivery needs no new machinery. The poll loop unpacks four arguments, so payloads travel as a single table.
- **Filesystem mounting.** `lovr.filesystem.setSource`/`mount`/`setRequirePath` let us point LÖVR at the user's config directory and mount the standard library.
- **Spatialised audio** via bundled Steam Audio, which makes [per-application audio](audio.md) a matter of routing rather than DSP.
- **Windowless operation.** `boot.lua:171` only opens a window if `conf.window` is set, and `lovr.graphics.newReadback` gives pixel readback — so GPU-headless testing is available.
- **LuaJIT** by default (`LOVR_USE_LUAJIT ON`), including its FFI for users who want it.

## Boot

We keep LÖVR's `lovr.run` rather than replacing it. Its loop already has the shape we need, and staying on it means `lovr.update`/`lovr.draw` behave exactly as LÖVR's documentation says. Replacing it later is a one-file change if we ever need control it can't express.

Our per-frame work injects around the existing steps:

1. Frame start: drain the compositor channel, refresh window handles, complete texture imports.
2. `lovr.update` runs user code.
3. Layer blits are issued into LÖVR's command stream for damaged surfaces holding granted layers.
4. `lovr.draw` runs user code.
5. Frame end: `setLayers` is called once from granted claims; requests queued by Lua are sent to the compositor thread.

Config resolution: `~/.config/lunette/main.lua` if it exists, otherwise `$SYSCONFDIR/xdg/lunette/main.lua`. `lunette --dump-config` writes a copy to start from. This mirrors awesome, which falls back to the system `rc.lua` rather than copying one on first run — no stale forks of a config you never edited, and upgrades improve the default for people who haven't customised.

## Restart semantics

`lovr.event.restart` returns to `main.c`'s outer loop, which closes the entire Lua state and builds a fresh one in the same process, passing a `cookie` variant across. Because LÖVR's module state is anchored in that Lua state, **restart tears down graphics and the XR session too**: imported textures die and re-import, and Monado sees the overlay session leave and return.

Our Wayland clients survive, because they're owned by Rust outside the Lua state.

That's why two reload paths exist ([The Lua API](lua-api.md#reload)): soft reload for the common case, hard restart for when soft isn't enough.

## Error handling

We override `lovr.errhand`. LÖVR's default shows an error screen and stops, which is right for a game and wrong for a window manager. The standard library installs a handler that logs, emits an event, and shows a floating error panel, rate-limiting identical repeats. Users can replace it — that's why it lives in Lua.

Native owns only the load-time fallback: if `main.lua` fails to load at all, there's no user handler yet, so a built-in safe mode takes over.
