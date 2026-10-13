# Rendering validation

Driver and runtime observations qualify the [native rendering guarantees](rendering.md). They do not generalise beyond the stated setups. Automated graphics and layer-pool tests provide regression checks.

## Imported-image ownership barriers

Imported-image acquisition defaults to `VK_IMAGE_LAYOUT_GENERAL` and `VK_QUEUE_FAMILY_FOREIGN_EXT`, matching the external producer ownership model. On Mesa, WayVR uses `VK_QUEUE_FAMILY_IGNORED`. On an NVIDIA proprietary driver, a content census from `GENERAL` showed the same five distinct colours with either queue-family choice; the background accounted for 98.5 per cent of samples. The run had no validation layer, so equal output does not establish that `IGNORED` is valid. The default therefore remains the conformant foreign queue family, and `TextureInfo.foreign` remains enabled.

That driver also retained imported-image contents when each acquire used `VK_IMAGE_LAYOUT_UNDEFINED`. The Vulkan specification permits contents to be discarded, so the observation does not establish portability. Two earlier comparisons using `UNDEFINED` as the old layout are invalid: their release barrier also used `UNDEFINED` as `newLayout`, violating `VUID-VkImageMemoryBarrier2-newLayout-01198`. The release barrier now returns images to `GENERAL` regardless of the selected acquire alternative. The `UNDEFINED` acquire and queue-family comparison therefore remains unmeasured on a valid barrier sequence. Development overrides `LUNETTE_IMPORT_QUEUE_FAMILY` and `LUNETTE_IMPORT_LAYOUT` are documented in [build and development](build-and-development.md#the-development-loop); the default relies only on the `GENERAL` observations. Issue #25 tracks a repeat on a GPU with a client.

## Layer budget and reuse

Monado with a real compositor reports `XRT_MAX_LAYERS`, 128 on Linux. Twelve layers were drawn and submitted for 60 frames without an OpenXR error, including a count above LÖVR's former `MAX_LAYERS` value of 10. With a Bigscreen Beyond under Monado, an 800x600 request rounded to the 832x640 size rung. The first grant arrived two frames after the claim without a stall in `lovrLayerCreate`; after release, a new same-sized claim received a pooled layer in one frame.

Monado's null compositor is not evidence for runtimes that report zero layers. At Monado revision `1c5fbbdadcccacd947abb1b6089c7303ab3c3bce`, a simulated null-compositor session reported a driver, session generation 1, and a limit of 128 because the null compositor advertises `XRT_MAX_LAYERS`.

A debugger fault-injection run forced `lovrHeadsetGetLayerLimit` to return zero in that live session. Three claims for 800x600 layers and a replacement claim at frame 120 stayed ungranted for 240 frame boundaries. A breakpoint on `lovrLayerCreate` recorded no calls, the pool emitted four zero-budget warnings (one per claim), and the run exited successfully. Layer-pool tests also cover no allocation at zero budget, limits below one budget slot, absent sessions, recovery to a positive budget, and reporting after session replacement. No runtime that naturally reports a zero limit has been observed; fault injection establishes the pool response, not runtime behaviour.

## Scene and composition-layer observations

A 1600x1200 client on the 1664x1280 layer rung was shown 0.6 m wide at 0.8 m and facing the viewer. Alternating it every five seconds with a scene quad at the same pose and size produced no visible sharpness difference to the observer. The panel subtended about 41 degrees at about 40 display pixels per degree, close to 1:1. This comparison does not cover oblique viewing, distant minification, or reprojection when session and runtime frame rates diverge.

With three panels on composition layers and an empty `lovr.draw`, skipping the scene reduced debug-build CPU time per frame from 0.312 ms to 0.153 ms at the same display-paced frame count. This supports scene skipping as a reason to use layers; it does not establish that layers are generally sharper. Issue #23 tracks the measurement under the shipped scene, which draws chrome.

A quad composition layer is single-sided. A panel visible from behind in the scene is not visible from behind after its layer claim is granted. The scene fallback does not remove this difference.

## Restart with imported images

Device restart abandons imported images rather than destroying them while LÖVR may still retain their texture views for deferred destruction. A restart with two connected clients under the Khronos validation layer reported `VUID-vkDestroyDevice-device-05137` for one image and one device-memory object per abandoned image. No other validation message was observed, and both clients re-imported successfully.

Flushing LÖVR's deferred-destruction morgue is not available after the boot coroutine finishes: quiescence runs after the last LÖVR tick, and the morgue is drained inside `lovrGraphicsSubmit`, outside lunette's FFI surface. Destroying the images while their views remain would leave views over freed memory. The reported device-destruction message is therefore an accepted consequence of restart, not evidence that normal frame submission leaks images.

## Related checks

Geometry and draw recorders do not establish GPU rasterisation, MSAA edges, alpha blending, stereo seams, or cutout depth. [LÖVR integration](lovr-integration.md#shader-pipeline-cache-lifetimes) records shader pipeline-cache lifetime tests and their limits.
