# Backdrop rendering

The backdrop draws a head-centred sky and three translucent aurora curtains before foreground scene content. Audio, attention, and controls are optional attachments with independent owner-scoped lifetimes. Requiring the modules allocates no graphics resources. The first visible draw creates three indexed GPU meshes and three shaders in the consumer's context: one each for the sky, curtains, and drifting fragments. Context shutdown releases them.

## Sky and curtains

The sky radius uses the configured distance, clamped to 15 to 40 m. Curtain layers stay near that radius. Their elevation, fold depth, fine ripples, and travelling onset waves have bounded displacement. Quality changes mesh subdivisions, not colour or response policy. The sky remains spatially varied without audio.

The curtains follow the structure of a real aurora. Each curtain has a sharp, bright lower hem, a body, and soft, uneven rays that fade as they rise, with tops at varying heights. The rays lean and wander as they rise and brighten and dim along their length, so they read as light rather than as pillars. They drift slowly because fast-moving fine rays strobe in a headset. The curtains also differ in shape. In plan view, each meanders toward and away from the viewer in broad folds, so the curtains overlap in depth. Travelling folds swing each curtain a few metres toward and away from the viewer. Each curtain tilts on its own slow cycle, so the curtains cross rather than stack. Each curtain is a ribbon around the ring rather than a uniform band. Its coarse band level sets its extent, so a quiet curtain breaks into separate drifting arcs and a loud one encircles the sky.

Autonomous motion uses a bounded shared phase. Model time advances at the motion strength, in units per second, and wraps at 4096. The shaders take it as radians per 4096 units with whole-number multipliers, so every autonomous term stays continuous at the wrap. At full motion the folds travel along the curtains with a period of about 29 seconds. The arcs wander and the curtains meander over one to two minutes. Brightness streams up the rays every eight seconds or so.

A field of patchy aurora covers the overhead sky above about 18 degrees of elevation and is strongest near the zenith. Its patches are thresholded noise in stereographic coordinates, which have no seam at the zenith. A second, time-varying noise warps them, and the coordinates twist with a shear that grows with distance from the zenith. Together these move the patches sideways, swirl them, and make them form and dissolve, like particles in a fluctuating magnetic field. Each patch breathes in and out on its own phase and carries fine streaks along the field. Every time term moves around a circle with a whole-number multiplier, so the field is continuous where the clock wraps. Energy lowers the threshold and brightens the field, and its colour moves between the mid and treble colours across the field.

Sixty-four fragments drift away from the curtains, as loose patches do from a real aurora. Each is a soft, tall quad facing the viewer. Its shader derives its whole life from its index and model time; no state lives on the CPU. A fragment spawns on a random curtain at a random longitude and height, then rises, drifts sideways, and moves outward as it fades in and out over 9 to 15 seconds at full motion. Its period divides the clock's wrap, so it never jumps there. The share of fragments that are lit grows from 30 percent in silence to all of them at full energy. Their colour moves from the resting palette toward the mid and treble colours with energy. They draw after the curtains, emit light the same way, and limit their largest component to 0.6.

## Light and scene state

The curtains emit light rather than paint it. Each curtain's alpha stays well below its colour, so overlapping curtains add and glow while dimming the stars behind them a little. The colour is limited by scaling it so that its largest component is at most 0.9, which keeps the hue. Light beyond that bound turns slightly toward white, so the hottest cores glow instead of clipping into flat colour.

Brightness, response, and motion controls are clamped to 0 to 1, and all three default to full. Each palette component is finite and clamped to 0 to 1. The sky shader limits its linear RGB components to 0.12 before premultiplication, and adds the overhead field limited to 0.35 per component. Each curtain shader limits its largest RGB component to about 1.08, including whitening of hot cores, and its alpha to 0.2. These are per-draw bounds, not a display-luminance guarantee or a bound on accumulated layers.

The background uses premultiplied alpha blending with depth testing and depth writes disabled. Opaque foreground geometry hides it, translucent foreground content blends over it, and rounded cutouts remain open to farther scene content. Drawing restores shader, material, blend, colour, culling, depth state, and transforms. It does not change the pass's view pose. Foreground content retains the normal scene depth convention.

Visibility moves linearly from its current value toward one while enabled and no main session is visible, and toward zero otherwise. The default fade duration is 0.8 seconds; configuration clamps it to 0 to 5 seconds. Reversing main-session visibility or the enabled control reverses the current fade without restarting it. Zero duration changes visibility immediately. At zero visibility, the background records no draws and contributes no RGB or alpha. `lovr.headset.isMainSessionVisible()` supplies the session observation. Unsupported backends or unavailable visibility events return false, so absence of that observation cannot hide the background.

## Bounded analytic background decision

The aurora uses indexed meshes and analytic shaders instead of texture feedback or offscreen history. This keeps per-frame work bounded and lets context shutdown release all renderer-owned meshes and shaders.

A painted curtain with alpha comparable to its colour was rejected because overlapping curtains occluded one another into flat colour. Emitted light adds where curtains overlap. A per-channel colour clamp was rejected because stacked onset light pushed two or three channels to the bound and bleached the curtains toward grey. Scaling by the largest channel keeps the hue.

High-contrast rays drawn as powered sines read as bars reaching into the sky and strobed as they moved. The rays are soft, lean with height, and vary along their length. The autonomous terms once used multipliers so small that a cycle took tens of minutes, which left the curtains almost static. They now run in the range of seconds to about two minutes.

The overhead field's noise hashes its lattice points with integer arithmetic. The common `fract(sin(x) * 43758.5453)` hash was rejected after it tore the field into angular shards on an NVIDIA GPU but not on lavapipe. At the arguments the field reaches, a last-bit rounding difference changes the result entirely, and the corner two cells share can be computed differently from each side. The diagnostic view is selected in the controls panel or configuration. It draws each stage of the overhead field on the sky with the curtains and fragments hidden, so a defect like this can be located on the affected GPU.

## Offscreen graphics checks

`make check-graphics` renders the production consumer, meshes, shaders, model updates, and public enabled control through real LÖVR graphics on an explicitly selected Mesa lavapipe Vulkan device. Only frame delivery and headset position and visibility observations are test-local. It initializes no headset, compositor, window, or host audio. All GPU cases run serially, and each fixture module receives a fresh interpreter and graphics state.

The checks use image ranges, brightness-normalised differences, alpha masks, onset-response positions, and interior foreground samples with tolerances rather than exact image goldens. They cover autonomous variation, separate bass/mid/treble shape response, spatial onset response, onset light in each band's palette hue, spectrum light ordered from low bands below to high bands above, hidden and partial alpha, continuous visibility reversal, opaque and translucent foregrounds, rounded-cutout depth, and subsequent draws with restored state. Ten renderer context shutdown/reacquisition cycles compare warmed pixels and `bufferMemory`/`textureMemory` budgets after recorded passes release their mesh references. Those counters exclude shaders, pipeline allocations and caches, driver heaps, and Lua memory. They do not establish a total renderer memory budget.

## Decisions

A screen-wide audio brightness response is rejected because it obscures the spatial effect and can create abrupt changes. Band features alter separate geometric parameters, and bounded onset waves carry local events. The feature mapping and rejected band layouts are recorded in [audio response](audio-response.md#decisions).

Shader colour bounds and continuous fades reduce abrupt contrast changes but do not establish headset comfort.

## Known gaps

Offscreen graphics checks establish selected single-sample rasterization, blending, and cutout-depth properties for the production aurora on lavapipe. They do not establish stereo seams, headset comfort, brightness under sustained loud input, prolonged motion, or runtime-specific visibility transitions. The separate headset acceptance checks appearance, comfort, stereo presentation, tracking loss, enable and disable transitions, and frame-time comparisons at each quality. These properties require manual headset checks. Live headset acceptance remains pending, as [audio acceptance](../../../../../docs/dev/audio.md#acceptance) records.

OpenXR main-session visibility depends on `XR_EXTX_overlay` events. An unsupported runtime or one that does not send those events leaves the observation false. The background then remains eligible to render until its enabled control is disabled. False does not establish that no main session exists.

The strict ten-reacquisition and clone-specialization pixel tests passed in 20 repeated lavapipe runs. These checks establish lifetime and selected pixel properties, not a total pipeline-memory or driver-cache budget. [LÖVR integration](../../../../../docs/dev/lovr-integration.md#shader-pipeline-cache-lifetimes) owns pipeline-cache lifetimes, the upstream defect rationale, and the native regression inventory.