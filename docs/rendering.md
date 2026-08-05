# Rendering

## Two ways a panel reaches the eye

Both mechanisms are available. Neither is privileged.

In-scene geometry. The surface texture is sampled by a shader in `lovr.draw`: a textured quad, a cylinder, a mesh, or any other geometry drawn by a script. It costs zero copies and supports arbitrary geometry, custom shaders, depth-correct occlusion against the 3D scene, and post-processing. It renders at the projection layer's resolution and through its MSAA path, so a 1080p terminal at arm's length is noticeably softer than the alternative.

OpenXR composition layer. The runtime composites a quad or cylinder itself at native panel resolution, with its own reprojection. Native-resolution compositing is what makes desktop text legible in VR, and existing overlays use this mechanism for that reason. It costs a blit per frame from the imported client buffer into the runtime-owned swapchain image, and geometry is limited to what the runtime supports, which for LÖVR means quad and cylinder with `curve`, plus viewport sub-rects.

The standard library defaults flat panels to composition layers and falls back to in-scene rendering when the layer budget is exhausted or when geometry, shaders, or depth interaction are required. That policy lives in Lua ([Standard library](stdlib.md)). The native layer supplies only the two mechanisms.

## Texture import

Client buffers arrive as dmabufs. The native layer imports them as `VkImage`s on LÖVR's device and wraps them as LÖVR `Texture`s via `TextureInfo.handle`.

Import is zero-copy and per-buffer. Wayland clients cycle among 2 to 4 buffers, so a surface's pixels live in a different `VkImage` each frame. An import cache keyed on the dmabuf, WayVR's approach at `inspiration/wayvr/wayvr/src/backend/wayvr/image_importer.rs:102`, means a surface rotates among a small stable set of textures rather than allocating anything after warm-up.

`window:getTexture()` is therefore valid for one frame only; a script must not hold it across frames. This is consistent with the snapshot model, and matches the practice of other compositors: wlroots, KWin, Mutter, and Hyprland all sample client buffers directly and never make a stabilising copy.

An alternative design, one persistent texture per surface updated by copy, was considered and rejected as a default. It would provide stable Lua identity and format normalisation, but it costs a full-surface copy per damaged frame. A 4K mirror at 90 Hz is approximately 3 GB/s, which matters on an integrated GPU sharing memory with the underlying application. It would also make the composition-layer path two copies instead of one. The composition-layer path is the one that determines text legibility, so doubling its cost is counterproductive.

### `surface:stabilize()`

This method is opt-in, for cases that require a persistent texture: running a multi-pass shader chain over a window, taking a screenshot, feeding a mesh with cached bindings, or freezing a window that stopped painting. It is damage-updated, so an idle window costs nothing.

### Forced conversion

Some buffers cannot be sampled directly. Multi-planar YUV needs `VkSamplerYcbcrConversion`, which LÖVR has no concept of. Those buffers are converted into an RGBA texture transparently. This occurs with hardware-decoded video and some PipeWire capture formats. The Lua-visible behaviour is identical; only the cost differs.

## Synchronisation

Client-to-compositor synchronisation is implicit, as in WayVR: there is no `linux-drm-syncobj-v1` handling and no imported semaphores anywhere in its tree. This works in practice on Mesa.

Explicit sync is a later addition. It needs external semaphore import in LÖVR ([LÖVR integration](lovr-integration.md#possibly-later)) so client fences can be waited on before sampling.

Internal synchronisation is sidestepped by construction. The compositor thread never submits GPU work; its only Vulkan activity is image creation. Every copy, including layer blits, stabilise updates, and format conversions, is issued inside LÖVR's own command stream on the main thread, so ordering against LÖVR's rendering is handled internally by LÖVR.

## The layer pool

`lovr.headset.setLayers` is a per-frame, global, last-call-wins list, capped by `MAX_LAYERS` and by whatever the runtime allows. Layers are also expensive: `newLayer` allocates an OpenXR swapchain with images, memory, and runtime state. A panel manager that promotes and demotes panels as the user looks around would churn swapchains every few frames if Lua allocated them directly.

Rust owns the pool instead, and recycles swapchains by `(width, height, format)`. A demoted 1920x1080 panel's swapchain goes straight to the next 1920x1080 claimant with no allocation.

The design keeps this from becoming policy implemented in Rust, through the following division.

- A claim carries a Lua-supplied scalar priority, recomputed as often as Lua requires. Rust never invents the ranking; it sorts by the number it was given and assigns the top N deterministically. Focus, gaze, distance, a rule such as video ranking above a terminal, and hysteresis to stop flapping are all cases of Lua computing a different number.
- Grants and revocations arrive as events (`lovr.lunlayergranted`, `lovr.lunlayerrevoked`) carrying the claim handle. The standard library degrades to an in-scene quad on revoke and upgrades back on grant. Upgrades are automatic: when a layer frees, the highest-priority ungranted claim takes it on the next frame.
- A granted claim yields a real LÖVR `Layer` userdata, not a wrapper. It exposes the full `setPose`/`setCurve`/`setViewport`/`getTexture` API and becomes invalid on revoke.
- Rust makes the single `setLayers` call per frame from granted claims. `lovr.headset.setLayers` remains reachable for scripts that opt out of the scheme entirely.

Two details matter if ignored.

- Revocation is deferred to frame boundaries. Revoking mid-frame would leave Lua holding a dead `Layer` inside `lovr.draw`.
- Stale claims skip their blit. A claim whose surface has not been damaged since its last blit is not copied again.

## Frame pacing

The compositor controls when every client renders, because a Wayland client draws only after the compositor delivers its `wl_surface.frame` callback. Combined with `setLayers{ main = false }`, an idle lunette instance can run at close to zero cost.

Native mechanism:

- Per-surface frame-callback throttling: `surface:setFrameRate(hz)`.
- Per-output advertised refresh, which clients use for their own pacing ([Compositor](compositor.md#outputs)).
- Damage-driven layer blits: an unchanged surface is not copied.
- Skipping the projection layer when Lua drew nothing.

Lua policy decides each panel's rate from visibility, gaze, distance, focus, and whether a game is running.

Two defaults matter because they are easy to get wrong.

- The floor is approximately 1 Hz, not zero. Clients starved of frame callbacks often stop pumping their event loops entirely, so they stop responding to input as well. A window that is frozen but alive is worse than one costing 1 Hz.
- Video is exempt by default. A throttled video player stutters conspicuously. The standard library leaves high-rate surfaces alone unless told otherwise.

lunette's own XR frame rate is not negotiable: an overlay submits every cycle whether or not anything changed. What is skipped is lunette's own scene rendering, which is where the savings actually occur.
