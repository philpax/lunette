# Rendering

## Presentation paths

Scene geometry shares projection resolution, MSAA, and depth. Composition layers have independent resolution and runtime reprojection. Lua chooses a path and its fallback; native code reports unsupported backend operations rather than approximating different geometry. [Panel rendering](../../lua/lunette-plugins/panels/README.md) owns shipped drawing policy.

## Texture import and lifetime

Client dmabufs import zero-copy on LÖVR's device and cache per buffer using the negotiated format and modifier. A current-frame texture must not be retained across frames. `window:stabilize()` makes an owned persistent copy updated on damage and replaced after resize. Making every surface persistent would add full-resolution copies unnecessarily.

Monitor capture tracks underlying image identity separately because a capture texture can be reused. Supported shared-memory frames are copied and normalized before main-thread upload; pointer-only frames lack an owned descriptor and validated extent and remain unsupported. Monitor transforms apply once, with proportions from logical geometry.

Consumers sample the compositor's viewport crop. Client buffer transforms are not applied by current consumers, so transformed content or crops can render incorrectly.

## Pixel and colour semantics

Client alpha is premultiplied. Opaque dmabuf formats use alpha-bearing Vulkan views whose padding may appear as alpha; consumers use the buffer's opaque flag to force alpha one. Shared-memory repacking normalizes it. Composition layers remain opaque because their copy path cannot force alpha or preserve client transparency.

Imported SDR values stay encoded sRGB through views and layer copies. Scene consumers decode before linear blending; translucent values require unpremultiplication, decoding, and premultiplication. Zero alpha produces zero color. Custom renderers have the same obligation. Multi-planar YUV converts to RGBA because LÖVR has no sampler YCbCr conversion.

## Synchronisation

Client synchronization is implicit. `linux-drm-syncobj-v1` requires external-semaphore import and is unsupported. The compositor creates images but submits no GPU work; LÖVR records all copies and conversions on the main thread. Foreign imports acquire from `GENERAL` and the foreign queue family by default. `TextureInfo.foreign` prevents LÖVR from discarding existing contents.

OpenVR hands textures to the runtime under the shared queue guard and restores image state afterward. Normal frames do not wait for device quiescence. Retirement does, and failed overlay destruction retains backing for retry. [Validation](rendering-validation.md#imported-image-ownership-barriers) limits the driver evidence.

## Layer allocation

Rust pools complete layers because creation can synchronously allocate swapchains or native overlay backing. Fixed dimensions form the pool key. Lua supplies fixed claim priority; native code grants the highest priorities without application ranking policy. Grants and revocations occur at frame boundaries, and one persistent layer list is submitted per frame. Lua handles unavailable claims.

OpenXR uses a conservative fraction of the reported runtime limit because overlays share that limit with the primary application. OpenVR reserves projection-eye slots and counts omitted panels and pending cleanup against its local cap. Exact ceilings and size steps belong in the pool implementation; the OpenVR cap is not an SDK guarantee.

Session generation detects replacement even when stop and start occur between snapshots. Missing or replaced sessions revoke grants and release stale layers. A live zero-budget session makes no allocation attempt and reports refusal once per claim per session. Copies track installed buffer identity as well as damage; a new commit must not be missed because its damage counter is unchanged.

## Frame pacing and scene skipping

Native pacing withholds Wayland frame callbacks and arms a timer so a waiting client cannot leave the event loop asleep indefinitely. The native floor is 1 Hz because stopping callbacks can stop input processing. Advertised output refresh is separate. Lua owns selection policy through [the pacing plugins](../../lua/lunette-plugins/pacing/README.md).

`lunette.setSceneEnabled(false)` skips scene resources and drawing while XR pacing, tracking, and composition-layer submission continue. Omitting the main layer from `setLayers` alone does not avoid scene rendering. OpenVR still updates tracking and hands off mutable panel backings. The command stream submits even without a scene pass or desktop window.

## Known gaps

Implicit synchronization remains untested under heavy GPU-client contention. OpenVR copies unchanged mutable layers every submission and has no occlusion against game depth. Buffer transforms, YUV conversion, and pointer-only capture have the limits stated above.

Imported images are abandoned on device restart while LÖVR may retain deferred texture views. [Rendering validation](rendering-validation.md#restart-with-imported-images) records the accepted validation message and remaining measurements. A quad layer is single-sided, unlike a scene panel that can be drawn from behind.
