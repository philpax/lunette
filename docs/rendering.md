# Rendering

## Two ways a panel reaches the eye

Both are available; neither is privileged.

**In-scene geometry.** The surface texture is sampled by a shader in `lovr.draw` — a textured quad, a cylinder, a mesh, whatever you drew. Zero copies. Fully general: arbitrary geometry, custom shaders, depth-correct occlusion against your 3D scene, post-processing. It renders at your projection layer's resolution and through your MSAA path, so a 1080p terminal at arm's length is noticeably softer than it could be.

**OpenXR composition layer.** The runtime composites a quad or cylinder itself at native panel resolution, with its own reprojection. This is what makes desktop text legible in VR, and it's why every serious overlay uses them. Costs a blit per frame from the imported client buffer into the runtime-owned swapchain image, and geometry is limited to what the runtime supports — which for LÖVR means quad and cylinder with `curve`, plus viewport sub-rects.

The standard library defaults flat panels to composition layers and falls back to in-scene when the layer budget is exhausted or when you want geometry, shaders, or depth interaction. That policy lives in Lua ([Standard library](stdlib.md)); the native side supplies only the two mechanisms.

## Texture import

Client buffers arrive as dmabufs. We import them as `VkImage`s on LÖVR's device and wrap them as LÖVR `Texture`s via `TextureInfo.handle`.

**Import is zero-copy and per-buffer.** Wayland clients cycle among 2–4 buffers, so a surface's pixels live in a different `VkImage` each frame. An import cache keyed on the dmabuf — WayVR's approach at `inspiration/wayvr/wayvr/src/backend/wayvr/image_importer.rs:102` — means a surface rotates among a small stable set of textures rather than allocating anything after warm-up.

`window:getTexture()` is therefore **per-frame. Don't hold it across frames.** That's consistent with the snapshot model, and it's what every real compositor does: wlroots, KWin, Mutter and Hyprland all sample client buffers directly and never make a stabilising copy.

The alternative — one persistent texture per surface, updated by copy — was considered and rejected as a default. It buys stable Lua identity and format normalisation, but it costs a full-surface copy per damaged frame (a 4K mirror at 90 Hz is ~3 GB/s, which matters on an integrated GPU sharing memory with the game underneath), and it makes the composition-layer path *two* copies instead of one. The copy is on the path that matters most for legibility, so paying it twice is exactly backwards.

### `surface:stabilize()`

Opt-in, for when you genuinely want a persistent texture: running a multi-pass shader chain over a window, screenshotting, feeding a mesh with cached bindings, or freezing a window that stopped painting. Damage-updated, so an idle window costs nothing.

### Forced conversion

Some buffers can't be sampled directly. Multi-planar YUV needs `VkSamplerYcbcrConversion`, which LÖVR has no concept of; those get converted into an RGBA texture transparently. Expect this with hardware-decoded video and some PipeWire capture formats. The Lua-visible behaviour is identical; only the cost differs.

## Synchronisation

Client-to-compositor synchronisation is **implicit**, as in WayVR — there's no `linux-drm-syncobj-v1` handling and no imported semaphores anywhere in their tree. This works in practice on Mesa.

Explicit sync is a later addition. It needs external semaphore import in LÖVR ([LÖVR integration](lovr-integration.md#possibly-later)) so client fences can be waited on before sampling.

Internal synchronisation is sidestepped by construction: **the compositor thread never submits GPU work.** Its only Vulkan activity is image creation. Every copy — layer blits, stabilise updates, format conversions — is issued inside LÖVR's own command stream on the main thread, so ordering against LÖVR's rendering is LÖVR's internal business.

## The layer pool

`lovr.headset.setLayers` is a per-frame, global, last-call-wins list, capped by `MAX_LAYERS` and by whatever the runtime allows. Layers are also expensive: `newLayer` allocates an OpenXR swapchain with images, memory, and runtime state. A panel manager that promotes and demotes as you look around would churn swapchains every few frames if Lua allocated them directly.

So **Rust owns the pool**, and recycles by `(width, height, format)`. A demoted 1920×1080 panel's swapchain goes straight to the next 1920×1080 claimant with no allocation.

The seam that keeps this from becoming policy-in-Rust:

- A claim carries a **Lua-supplied scalar priority**, recomputed as often as Lua likes. Rust never invents the ranking — it sorts by the number it was given and assigns top-N deterministically. Focus, gaze, distance, "video beats terminal", hysteresis to stop flapping: all of that is Lua computing a different number.
- Grants and revocations arrive as **events** (`lovr.lunlayergranted`, `lovr.lunlayerrevoked`) carrying the claim handle. The standard library degrades to an in-scene quad on revoke and upgrades back on grant. Upgrades are automatic: when a layer frees, the highest-priority ungranted claim takes it next frame.
- A granted claim yields a **real LÖVR `Layer` userdata**, not a wrapper. Full `setPose`/`setCurve`/`setViewport`/`getTexture` API; it simply becomes invalid on revoke.
- Rust makes the single `setLayers` call per frame from granted claims. `lovr.headset.setLayers` remains reachable for anyone who wants to opt out of the scheme entirely.

Two details that bite if ignored:

- **Revocation is deferred to frame boundaries.** Revoking mid-frame would leave Lua holding a dead `Layer` inside `lovr.draw`.
- **Stale claims skip their blit.** A claim whose surface hasn't been damaged since its last blit doesn't get copied again.

## Frame pacing

We control when every client renders, because a Wayland client draws only after we deliver its `wl_surface.frame` callback. Combined with `setLayers{ main = false }`, an idle lunette can be nearly free.

**Native mechanism:**

- Per-surface frame-callback throttling: `surface:setFrameRate(hz)`.
- Per-output advertised refresh, which clients use for their own pacing ([Compositor](compositor.md#outputs)).
- Damage-driven layer blits: an unchanged surface isn't copied.
- Skipping the projection layer when Lua drew nothing.

**Lua policy:** deciding each panel's rate from visibility, gaze, distance, focus, and whether a game is running.

Two defaults worth stating because they're easy to get wrong:

- **The floor is ~1 Hz, not zero.** Clients starved of frame callbacks often stop pumping their event loops entirely, so they stop responding to input too. A window that's frozen but alive is worse than one costing 1 Hz.
- **Video is exempt by default.** A throttled video player stutters conspicuously. The standard library leaves high-rate surfaces alone unless told otherwise.

lunette's own XR frame rate isn't negotiable — an overlay submits every cycle whether or not anything changed. What we skip is our own scene rendering, which is where the savings actually are.
