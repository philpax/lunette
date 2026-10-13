# Rendering validation

Observed results qualify [native rendering](rendering.md); they do not generalize beyond the tested driver, runtime, and headset. Draw recorders establish geometry and call order, not rasterization, alpha, stereo registration, or depth. Software-GPU checks do not establish headset presentation.

## Imported-image ownership barriers

Import defaults to `GENERAL` and the foreign queue family. One proprietary NVIDIA-driver comparison produced equal sampled colors with foreign and ignored queue families, without validation enabled. That does not establish that ignored ownership is valid or portable.

Earlier undefined-layout comparisons also used an invalid undefined release layout and are not evidence. Release now returns to `GENERAL`; a valid-sequence comparison remains pending. Driver retention of contents acquired from `UNDEFINED` cannot override Vulkan's permission to discard them. Issue #25 tracks validation with a GPU client. [Development overrides](build-and-development.md#the-development-loop) exist for diagnosis, not as supported alternatives.

## Layer budget and reuse

Monado reported 128 layers and submitted twelve layers without error. A Bigscreen Beyond run observed delayed initial allocation and faster same-sized pooled reuse without an allocation stall. Neither observation establishes every runtime's limit or latency.

Monado's null compositor also reports 128 and does not exercise a natural zero limit. Debugger injection of zero kept claims ungranted and made no layer-creation calls. It establishes pool refusal behavior, not runtime behavior. No naturally zero-limit runtime has been observed.

## Scene and composition-layer observations

One near-1:1 Bigscreen Beyond comparison found no visible sharpness difference between a scene panel and a composition layer. Oblique views, minification, and divergent frame rates remain unmeasured. An empty-scene debug measurement reduced CPU time when skipping the scene; it does not prove general sharpness or cost advantages. Issue #23 tracks measurement with shipped chrome.

Quad composition layers are single-sided. Granting a layer can therefore make a scene panel disappear from behind; fallback does not erase that difference.

## Restart with imported images

Restart abandons imported images while LÖVR may retain deferred texture views. Destroying those images first would leave views over freed memory. A validated restart with connected clients reported `VUID-vkDestroyDevice-device-05137` for abandoned images and memory, with successful re-import and no other observed validation messages. This accepted restart consequence does not establish normal-frame leakage.

LÖVR drains deferred destruction during graphics submission, which is unavailable through the host's FFI after the boot coroutine ends. Resolving the warning needs a safe final drain before import destruction. [Shader-cache lifetime checks](lovr-integration.md#shader-pipeline-cache-lifetimes) cover a separate resource boundary.

## Acceptance

Heavy GPU-client contention, valid alternative import barriers, shipped-scene cost, and backend-specific stereo, alpha, motion, and cleanup need live checks. Records must identify driver, runtime, headset, and validation settings. A completed diagnostic or successful software raster test does not close these requirements.
