# Rendering

## Presentation paths

Scene geometry samples a texture during `lovr.draw`. It shares projection-layer resolution, MSAA, and scene depth. A composition layer is submitted to the XR runtime at its own resolution and can receive its own reprojection. OpenXR uses runtime swapchain images for quad and cylinder layers; OpenVR uses owned images and native overlay handles. A backend operation that cannot be performed is reported rather than approximated with different geometry.

The native API provides both paths. Lua decides which path to use and what to render when a layer is unavailable. The panels provider's geometry, child-surface, and chrome policy is specified in [panel rendering](../../lua/lunette-plugins/panels/docs/rendering.md).

## Texture import and lifetime

Client dmabufs are imported as `VkImage`s on LÖVR's device and wrapped as LÖVR textures through `TextureInfo.handle`. Import is zero-copy and cached per buffer, so a client can rotate among its committed buffers without allocating an image for every frame. The negotiated DRM format and modifier determine the import layout; clients may use tiled modifiers, so import does not assume linear memory.

`window:getTexture()` refers to the buffer committed for the current frame and must not be retained across frames. Mirrored monitor capture has separate image tracking because a capture source can reuse a texture for a different underlying image. Supported shared-memory capture frames in 32-bit RGB layouts are copied, normalised, and uploaded on the frame thread. A frame supplied only as a mapped pointer is unsupported because the capture callback provides neither an owned descriptor nor a validated extent.

Monitor consumers apply the reported transform exactly once when deriving sampling coordinates and derive panel proportions from logical geometry rather than transformed buffer dimensions. The panels provider's UV permutations are described in [panel rendering](../../lua/lunette-plugins/panels/docs/rendering.md#monitor-transforms).

The compositor reports a window's source crop for `wp_viewport`. Consumers use that crop when sampling the buffer. Crop coordinates are computed after the client buffer transform, but consumers do not apply client buffer transforms; a client that combines a transform with a crop can therefore render incorrectly. `window:stabilize()` returns a lunette-owned texture that remains valid across frames. The native implementation copies into it when the surface is damaged, reuses it on subsequent calls, and replaces it after a resize. It returns `false` for a dead window or before the client commits a buffer.

## Pixel and colour semantics

Imported client buffers use premultiplied alpha. Consumers preserve that convention when blending; applying alpha a second time darkens translucent pixels. `Xrgb8888`, `Xbgr8888`, and `Xbgr2101010` have padding where Vulkan expects alpha. Those dmabufs are imported through alpha-carrying formats with matching component order, so the padding value can appear as alpha. `window.opaque` identifies this case for the current buffer and consumers treat its alpha as one. Shared-memory repacking sets the padding byte to one, so the opaque flag is needed for dmabuf imports.

Composition layers are opaque. A Vulkan copy or blit cannot force an alpha component, and the layer path does not run a shader during the copy. The layer path therefore cannot preserve per-pixel client transparency.

Imported desktop textures retain encoded SDR sRGB values through non-sRGB views and layer copies. Scene consumers decode before linear blending. For translucent pixels they unpremultiply, decode, and premultiply again in linear space; zero-alpha pixels produce zero colour. Custom source renderers carry the same conversion obligation. Multi-planar YUV formats require sampler YCbCr conversion, which LÖVR does not provide, so those buffers are converted to RGBA.

## Synchronisation

Client-to-compositor synchronisation is implicit. `linux-drm-syncobj-v1` is not supported; explicit synchronisation requires external semaphore import in LÖVR, as noted in [LÖVR integration](lovr-integration.md#possibly-later).

The compositor thread creates imported images but submits no GPU work. Copies, layer blits, stabilised copies, and format conversions are recorded in LÖVR's command stream on the main thread. Imported images are acquired from `VK_IMAGE_LAYOUT_GENERAL` with `VK_QUEUE_FAMILY_FOREIGN_EXT` by default. `TextureInfo.foreign` carries the external-ownership information into LÖVR.

The OpenVR backend submits rendering and a transfer-source barrier before calling the runtime under the shared graphics-queue guard, then restores the image state. Normal frames do not wait for the whole device. Overlay retirement waits for quiescence before destroying the runtime handle and invalidating its backing; a failed runtime destruction retains the backing for retry.

## Layer allocation

`lovr.headset.setLayers` sets a persistent, last-call-wins list bounded by LÖVR's `MAX_LAYERS` and the runtime. OpenXR re-composites the last released swapchain image for an unchanged layer. OpenVR retains the visible overlay image, but mutable layers still copy their backing into the output image and hand it off on each submission.

Native Rust code owns the layer pool. Layer creation can allocate an OpenXR swapchain synchronously or allocate OpenVR backing and overlay handles, so the pool recycles complete layer objects. Width and height are fixed at creation and form the pool key; other layer properties have setters. Requests round up to discrete size steps before pooling. Pooled layers are mono, mutable, opaque, and filtered.

Lua supplies a numeric priority for each claim. The priority remains fixed for the claim's lifetime; native code grants the highest-priority claims within the available budget and adds no ranking policy. `granted` and `layer` report the result at the latest frame boundary. Native code updates the persistent layer list once per frame. Revocation also occurs at a frame boundary, so a layer is not invalidated during `lovr.draw`; a caller handles an unavailable claim in Lua.

The OpenXR claim budget is limited by the runtime's `XrSystemGraphicsProperties::maxLayerCount`, a local ceiling of 12, and one quarter of the reported runtime limit. The runtime limit is shared with the primary application when `XR_EXTX_overlay` is in use. OpenVR caps created panels at 62, reserving two overlays for the projection eyes; omitted panels and panels awaiting cleanup count toward this local cap. The OpenVR limit is not an SDK guarantee.

A missing or changed session revokes grants and releases stale pooled layers. Session generation, rather than session presence alone, detects a stop and start between frame boundaries. The pool reads the limit again when a session is present. A live session with no usable budget grants no claims and makes no layer-creation attempts; refusal reporting is once per claim per session. An absent session does not produce a zero-budget warning.

Surface copies use installed-buffer identity as well as damage. The compositor's buffer-commit handler consumes the buffer needed for import, so the layer path records a session-wide commit stamp when each texture is installed and copies when that stamp changes. This detects a newly committed buffer even when the damage counter does not change. Monitor capture uses a separate ledger keyed by monitor identity and records the image behind a reused capture texture.

## Frame pacing and scene skipping

Wayland clients render after lunette answers their `wl_surface.frame` callbacks. Native mechanisms include per-window frame-callback throttling through `window:setFrameRate(hz)`, advertised output refresh, damage-driven layer copies, and skipping lunette's scene rendering. The native frame-rate floor is 1 Hz. A client that receives no frame callbacks may also stop processing input. The `wp_content_type_v1` hint is exposed as `win.contentType`. The pacing provider's policy is described in [pacing policy](../../lua/lunette-plugins/pacing/docs/pacing-policy.md).

lunette continues submitting an XR frame each cycle so the runtime can pace and update predicted tracking. `lunette.setSceneEnabled(false)` skips scene rendering. On OpenXR, the wrapped `lovr.headset.getPass` and `lovr.headset.getTexture` return no projection resources, avoiding colour-swapchain acquisition, waiting, rendering, and resolve. Composition layers still submit. Setting `main = false` in `lovr.headset.setLayers` alone does not skip that scene work; it omits the already-rendered projection layer. On OpenVR, skipped frames still perform the overlay wait and snapshot update, hide omitted projection overlays, and submit mutable panel backings. When a frame has no pass and no window, lunette submits LÖVR's command stream so layer work is not left unsubmitted.

## Decisions

Imported buffers remain zero-copy by default. A persistent copy is available through `window:stabilize()` for consumers that need a texture to survive buffer rotation; making every surface persistent would add a full-resolution copy on each damaged frame and another copy for layer presentation.

Native code owns allocation and recycling, while Lua owns claim priority. A Lua-owned pool would duplicate runtime allocation and recycling, while native code has no application knowledge for ranking claims.

Opaque dmabuf alpha is normalised by consumers because import does not copy or modify the image. A view swizzle would require a new LÖVR texture-import field. Layers remain opaque because a copy cannot force alpha and the client format can change during a claim.

## Known gaps

Buffer transforms are not applied by consumers, so transformed content and transformed crops can be wrong. Multi-planar YUV requires an RGBA conversion. Shared-memory capture does not support pointer-only frames.

Implicit synchronisation has not been tested under contention from a heavy GPU client. OpenVR does not detect unchanged mutable layer content, so it still copies and hands off those backings each submitted frame. OpenVR presents native overlays and two projection-eye overlays without `IVRCompositor::Submit` frames or occlusion against a game's depth.

Imported images are forgotten during device restart rather than explicitly destroyed because LÖVR can still hold their texture views for deferred destruction. The validation-layer consequence and restart observation are recorded in [rendering validation](rendering-validation.md). Driver, layer-budget, and scene-versus-layer observations are also recorded there; LÖVR pipeline-cache validation remains in [LÖVR integration](lovr-integration.md#shader-pipeline-cache-lifetimes).
