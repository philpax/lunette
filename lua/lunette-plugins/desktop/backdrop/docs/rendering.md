# Backdrop rendering

The renderer draws a head-centred sky, three aurora curtains, and drifting fragments before foreground content. Requiring the module allocates no graphics resources; the first draw creates meshes and shaders owned by the rendering context.

The curtains form translucent ribbons with bright lower hems, soft rays, and broad folds that cross in depth. Coarse band levels set each curtain’s extent, so quiet regions break into arcs instead of remaining solid bands. The overhead field uses warped thresholded noise in stereographic coordinates to avoid a zenith seam. Fragments derive their motion from index and model time, so they need no per-fragment CPU state.

Analytic shaders and indexed meshes keep per-frame work bounded and let context shutdown release renderer resources. Emitted light makes overlapping curtains glow. Scaling colour by its largest channel preserves hue better than a per-channel clamp. The overhead noise uses integer lattice hashing: a floating-point sine hash produced GPU-dependent seams in the field.

The background uses premultiplied alpha with depth testing and writes disabled. Opaque foreground geometry hides it; translucent content blends over it, and rounded cutouts reveal farther scene content. Drawing restores the graphics state it changes. Visibility fades with main-session visibility when that observation is available. Some OpenXR runtimes do not provide the required visibility events, leaving the background eligible to render until disabled.

Lavapipe graphics tests cover selected rasterization, blending, depth, and resource-lifetime behavior. They do not establish stereo presentation, headset comfort, sustained-loudness brightness, or runtime visibility behavior. Manual headset acceptance remains pending; see [audio acceptance](../../../../../docs/dev/audio.md#acceptance). The native shader-pipeline cache is documented in [LÖVR integration](../../../../../docs/dev/lovr-integration.md#shader-pipeline-cache-lifetimes).

## Acceptance

Pending headset checks cover appearance, comfort, stereo presentation, tracking loss, enable/disable transitions, and frame-time comparisons at each quality. Offscreen rendering does not establish these properties.
