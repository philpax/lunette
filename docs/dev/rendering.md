# Rendering

## Two ways a panel reaches the eye

In-scene geometry samples the surface texture in `lovr.draw`, on a quad, a cylinder, or any mesh a script draws. It costs no copy and supports custom shaders, depth against the scene, and post-processing. It renders at the projection layer's resolution and through its MSAA, so text is softer than on a layer.

A composition layer is composited by the XR runtime at the layer's own resolution, with its own reprojection, which makes desktop text legible. The client buffer is copied into backend-owned layer backing when it is damaged. OpenXR uses runtime swapchain images and supports quad and cylinder layers with `curve` and viewport sub-rectangles. OpenVR uses owned output images and native overlay handles. An operation a backend cannot perform is reported, not approximated with different geometry.

The panels provider's `rendering` setting is `'plane'` by default, so windows take part in scene depth. `'layer'` makes window panels claim layers and fall back to the scene when a claim is not granted. Monitor panels always render in the scene. That choice is Lua policy ([Standard library](stdlib.md)); the native layer supplies only the two mechanisms.

## Popups and subsurfaces

A window's texture is its own surface's buffer and holds none of its popups or subsurfaces. The compositor reports them with their textures and their places relative to the window ([Compositor](compositor.md#windows)), and the panels provider draws them with the window's content in `lua/lunette-plugins/panels/children.luau`. Children stacked below the window's surface are drawn first, then the window, then the children above it, so a menu covers the window and a video subsurface beneath a transparent region shows through it. Each child is drawn 0.2 mm further toward the viewer than the layer before it, because coplanar meshes z-fight, and a child below the window 0.2 mm behind it per layer.

A child is clipped to the panel's silhouette, its rounded corners included, and samples only the part of its crop that remains. Picking reaches only the window's own area, so the clip keeps what is drawn and what can be pointed at the same: the compositor routes a point inside a child's drawn area to the child. A child's mesh follows the panel's curve as the window's does, and is kept while the child's placement, its crop, and the panel's shape are unchanged.

A composition layer is composited over the scene, so a window's layer would cover the children drawn in the scene. A window panel showing any child releases its layer claim and draws in the scene, and claims a layer again once none remain.

## Rounded scene geometry

`lua/lunette-plugins/theme/rounded-geometry.luau` generates convex rounded-rectangle perimeters from a size and four corner radii. Each radius is clamped to the available extent, a zero radius gives a square corner, and each nonzero quarter arc has eight segments. Drawing and initial picking use the same emitted perimeter, chords included, so a point between a chord and its circle is outside. Borders are rings between an outer and an inner perimeter.

Scene-rendered windows and monitors clip their texture meshes to the perimeter. UVs come from the unclipped panel-local coordinates, so a corner loses pixels without the image stretching. Monitor rotation and flip apply after that mapping. Curved content splits the clipped polygon at the cylinder's strip boundaries and maps each vertex onto the cylinder. Picking maps back through the same perimeter.

Corner cutouts hold no content and no depth-writing geometry, so farther surfaces stay visible and pickable through them. Meshes belong to an owner or provider activation, are cached by size, clip, and corner profile, and are released when replaced, when the owner is cleaned up, or when the provider shuts down. Requiring a module creates no mesh.

A native pointer stops moving when the ray leaves the perimeter, and its button release still goes to the sink that received the press. Protocol surfaces keep projecting a captured pointer through cutouts with `inside = false`, so a release there cannot activate a control. A geometry change cancels the affected Lua captures before notifying callbacks; a palette change preserves captures, drafts, and focus.

Granted composition layers keep rectangular content and hits on both backends. A radius change never acquires or releases a claim. An ungranted window claim uses the rounded scene profile. Base, Dark, and Light use a zero monitor radius; Arcade uses 0.012 m.

### UI content clips

A UI panel's backing uses the full rounded silhouette. Controls, text, and input use a rectangular content clip inside it, so declared panel and control bounds are unchanged and the existing overflow indicators still apply. Rounded control faces keep rectangular hit targets. Default faces clip their polygons to the content clip. Text and custom hooks receive the clip as a rectangle and must respect `visual.clip`; nothing enforces it on an arbitrary shader. [UI panels](lua-api.md#ui-panels) defines the hook boundary.

### Joined flat frames

A shared titlebar joins its target only while the target is live, visible, flat, and rendered in the scene. A target with a granted layer does not join. The joined header rounds only its top outer corners and the body only its bottom outer corners; the inner edges are square and meet with no margin, and the header's inner width equals the body's. Header radii clamp to the header height. Hiding or removing the heading restores the body's own profile.

The target draws one outline around both, even with native `chrome = false`. The header's border thickness, depth, and normal or highlighted colour govern the whole outline. For body width W, body height H, and header height h, the inner envelope is W by H+h, centred at y = h/2 in target-local metres; the outer envelope grows by the border thickness. No outline runs along the seam, and nothing writes depth in the cutouts.

The titlebar still draws its face, text, and actions. Action faces clip to the header perimeter, and action and drag hits are gated by it, so a cutout is never a hidden grab target. A curved body keeps a separate flat titlebar, and so does a granted layer. [Joined frame attachments](lua-api.md#joined-frame-attachments) defines the relationship.

### UI scene depth

For lunette-owned UI, only opaque backing and outline geometry writes depth. Controls, details, and glyphs draw in painter order without writing depth. Offsets follow nesting: the backing sits 2 mm in front of its surface, control faces 1 mm further, contents 1 mm further, and glyphs 1 mm further. Intersecting or nearly coincident panels can show draw-order artefacts within that range.

## Aurora background

`desktop/backdrop` draws a head-centred sky and three translucent aurora curtains before foreground scene content. It requires the frame provider. Audio, attention, and controls are optional attachments with independent owner-scoped lifetimes. Requiring the modules allocates no graphics resources. The first visible draw creates three indexed GPU meshes and three shaders in the consumer's context, for the sky, the curtains, and the drifting fragments; context shutdown releases them.

The sky radius is the configured distance, clamped to 15 to 40 m. Curtain layers stay near that radius. Their elevation, fold depth, fine ripples, and travelling onset waves have bounded displacement. Quality changes mesh subdivisions rather than colour or response policy. The sky remains spatially varied without audio, and autonomous motion uses a bounded shared phase. Model time advances at the motion strength, in units per second, and wraps at 4096. The shaders take it as radians per 4096 units with whole-number multipliers, so every autonomous term stays continuous where the clock wraps. At full motion the folds travel along the curtains with a period of about 29 seconds, the arcs wander and the curtains meander over one to two minutes, and brightness streams up the rays every eight seconds or so.

The curtains follow the structure of a real aurora. Each has a sharp, bright lower hem, a body, and soft, uneven rays that fade as they rise, with tops at varying heights. The rays lean and wander as they rise and brighten and dim along their length, so they read as light rather than as pillars, and they drift slowly because fast-moving fine rays strobe in a headset. Every curtain carries the spectrum by altitude: bass lights the hem in the bass colour, mid the body, and treble the ray tops. At rest the body and tops keep the natural aurora's `low` and `high` colours. Each band's own colour takes over its zone as the band grows loud. A band's level is the mean of its sub-bands of the eight-band spectrum, squared, so a quiet band leaves its zone near rest. Rays rise further as overall energy grows. The curtains also differ in shape. In plan view each meanders toward and away from the viewer in broad folds, so the curtains overlap in depth, and travelling folds swing each curtain a few metres toward and away from the viewer. Each also tilts on its own slow cycle, so the curtains cross rather than stacking. Each curtain is a ribbon around the ring rather than a uniform band. Its coarse band level sets its extent, so a quiet curtain breaks into separate drifting arcs and a loud one encircles the sky. Normalised bass also raises the curtains' elevation, mid deepens their folds and radius, and treble adds fine ripples and strand shimmer, each weighted toward one curtain. A faint airglow in the mid colour lights the low sky and swells with the mid band.

A field of patchy aurora covers the sky overhead, above about 18 degrees of elevation and strongest near the zenith. Its patches are thresholded noise in stereographic coordinates, which have no seam at the zenith. A second, time-varying noise warps them, and the coordinates twist with a shear that grows with distance from the zenith. Together these move the patches sideways, swirl them, and make them form and dissolve, like particles in a fluctuating magnetic field. Each patch also breathes in and out on its own phase, as pulsating aurora does, and carries fine streaks along the field. Every time term moves around a circle with a whole-number multiplier, so the field is continuous where the clock wraps. Energy lowers the threshold and brightens the field, and its colour moves between the mid and treble colours across the field.

Sixty-four fragments drift away from the curtains, as loose patches do from a real aurora. Each is a soft, tall quad facing the viewer, and its shader derives its whole life from its index and model time; no state lives on the CPU. A fragment spawns on a random curtain at a random longitude and height, then rises, drifts sideways, and moves outward as it fades in and out over 9 to 15 seconds at full motion. Its period divides the clock's wrap, so it never jumps there. The share of fragments that are lit grows from 30 percent in silence to all of them at full energy, and their colour moves from the resting palette toward the mid and treble colours with energy. They draw after the curtains, emit light the same way, and limit their largest component to 0.6.

The curtains emit light rather than paint it. Each curtain's alpha stays well below its colour, so overlapping curtains add and glow while dimming the stars behind them a little. The colour is limited by scaling it so that the largest component is at most 0.9, which keeps the hue. Light beyond that bound turns slightly toward white, so the hottest cores glow instead of clipping into flat colour.

A bass onset heaves the curtains up and outward in a broad swell and flashes the hem in the bass colour. The flash climbs into the body. It punches at the origin, decaying with a time constant of about 0.12 seconds, then ripples outward both ways at 0.3 turns per second as a few narrow concentric rings that fade over the wave's 0.9-second life. The rings are narrow, so steady kicks never hold a whole curtain in the bass colour. A mid onset ripples a slightly whitened flare in the mid colour outward along the body at 0.16 turns per second and lifts the curtains briefly as it spreads. A treble onset swells in over about 0.08 seconds rather than popping, shoots the rays near it upward, flickers individual rays in the treble colour, and adds treble-coloured stars nearby. An onset restores a ribbon's full height and extent where it passes, so an onset in a gap raises a curtain rather than a thin line. Every onset acts at a longitude rather than as a screen-wide brightness pulse. Waves are pooled per band, with at most four bass, eight mid, and eight treble waves, so frequent treble onsets cannot evict a bass heave. Bass waves last 0.9 seconds, mid waves 1.2 seconds, and treble waves 0.9 seconds. One transient often completes two or three adjacent analysis hops, so the response treats a band onset within 1200 samples of that band's previous onset as the same event and keeps the stronger hop. An onset without a band is a mid flare.

Onsets land where the viewer is looking, quantised so that they do not chase the head. The base consumer reads the head's direction each frame. The response snaps it to the nearest twelfth of a turn and keeps that anchor until the view is past the sector's edge by a further 15 percent of its width. Before any head direction arrives, the anchor faces -z, LÖVR's forward direction. Each onset scatters about the anchor within a full width of 0.05 turns for bass, 0.08 for mid, and 0.16 for treble. The hop's sample end and its band seed the offset, so a replayed publication lands in the same place, and bands struck by one transient start apart.

The spectrum calibration is fixed rather than normalised per frame, so silence stays dark and loudness stays meaningful. Its per-band gains bring a typical mastered mix near half scale in every band. They were measured on system-output captures of commercial music, which falls off steeply above 2 kHz, and `response-child.luau` owns them. Treble-heavy mixes still reach full scale in the top bands.

Brightness, response, and motion controls are clamped to 0 to 1, and all three default to full. Each palette component is finite and clamped to 0 to 1. The sky shader limits its linear RGB components to 0.12 before premultiplication, and adds the overhead field limited to 0.35 per component. Each curtain shader limits its largest RGB component to about 1.08, including the whitening of hot cores, and its alpha to 0.2. These are per-draw bounds, not a display-luminance guarantee or a bound on the accumulated layers. Audio response changes geometry and coverage as well as colour. Provider loss settles the response toward zero while autonomous rendering continues.

The background uses premultiplied alpha blending with depth testing and depth writes disabled. Opaque foreground geometry hides it, translucent foreground content blends over it, and rounded cutouts remain open to farther scene content. Drawing restores shader, material, blend, colour, culling, depth state, and transforms. It does not change the pass's view pose. Foreground content retains the normal scene depth convention.

Visibility moves linearly from its current value toward one while enabled and no main session is visible, and toward zero otherwise. The default fade duration is 0.8 seconds; configuration clamps it to 0 to 5 seconds. Reversing main-session visibility or the enabled control reverses the current fade without restarting it. Zero duration changes visibility immediately. At zero visibility the background records no draws and contributes no RGB or alpha. `lovr.headset.isMainSessionVisible()` supplies the session observation; unsupported backends or unavailable visibility events return false, so absence of that observation cannot hide the background.

### Offscreen graphics checks

`make check-graphics` renders the production consumer, meshes, shaders, model updates, and public enabled control through real LÖVR graphics on an explicitly selected Mesa lavapipe Vulkan device. Only frame delivery and headset position/visibility observations are test-local. It initializes no headset, compositor, window, or host audio. All GPU cases run serially, and each fixture module receives a fresh interpreter and graphics state.

The checks use image ranges, brightness-normalised differences, alpha masks, onset-response positions, and interior foreground samples with tolerances rather than exact image goldens. They cover autonomous variation, separate bass/mid/treble shape response, spatial onset response, onset light in each band's palette hue, spectrum light ordered from low bands below to high bands above, hidden and partial alpha, continuous visibility reversal, opaque and translucent foregrounds, rounded-cutout depth, and subsequent draws with restored state. Ten renderer context shutdown/reacquisition cycles compare warmed pixels and `bufferMemory`/`textureMemory` budgets after recorded passes release their mesh references. Those counters exclude shaders, pipeline allocations and caches, driver heaps, and Lua memory; they do not establish a total renderer memory budget.

## Texture import

Client buffers arrive as dmabufs. The native layer imports each as a `VkImage` on LÖVR's device and wraps it as a LÖVR `Texture` through `TextureInfo.handle`. Import is zero-copy and per buffer. A client cycles among 2 to 4 buffers, and an import cache keyed on the dmabuf, as in WayVR, makes a surface rotate among a stable set of textures with no allocation after warm-up.

Clients choose tiled modifiers. On the NVIDIA proprietary driver, every advertised format offered six block-linear modifiers and `DRM_FORMAT_MOD_LINEAR`, and Alacritty committed `AR24` with a block-linear one, so the import honours the negotiated modifier rather than assuming a linear layout.

A texture from `window:getTexture()` is therefore valid for one frame only. wlroots, KWin, Mutter, and Hyprland also sample client buffers directly.

### Viewport crop

A client can show part of its buffer through `wp_viewport`, and `window:getSourceCrop()` reports which part. The panels provider samples only that rectangle: a cropped window draws on a mesh whose texture coordinates span the crop, rebuilt when the crop changes, and an uncropped flat window keeps the plain quad. A layer is claimed at the texture's size, because the copy into the layer is one texel to one pixel, and the layer's viewport is set to the crop in texture pixels. A window whose texture is larger than its committed size, as with a fractional-scale client, therefore fills its layer rather than having its copy cut short. The crop is computed after the buffer's transform, and no consumer applies a client's buffer transform when drawing, so a client that both transforms and crops its buffer shows the wrong region.

### `window:stabilize()`

`window:stabilize()` returns a lunette-owned texture that persists across frames, for shader chains, screenshots, cached mesh bindings, or freezing a window. It copies the client buffer through `lovrTextureCopy`, the call layer blits use, on each damaged frame. A second call returns the same texture. A resize releases the copy, and the next call allocates one of the new size. It returns `false` on a dead handle and before the client commits a buffer.

### Alpha

An imported buffer holds premultiplied alpha. A client configured with an opacity of 0.8 read back with every colour channel scaled by exactly 0.8 and an alpha of 0.8, a linear factor that rules out a gamma or sRGB misreading. A consumer draws with `pass:setBlendMode('alpha', 'premultiplied')`. LÖVR's default alpha mode multiplies by alpha a second time and darkens translucent clients.

`Xrgb8888`, `Xbgr8888`, and `Xbgr2101010` have a padding byte where alpha would be. Vulkan has no such format, so they import as the alpha-carrying format with the same component order, and the padding byte, usually zero, reads as alpha. `window.opaque` is true for such a buffer, and the consumer forces alpha to one. It is a property of the current buffer, so a consumer reads it each frame. The shared-memory path sets the padding byte to one when it repacks, so `window.opaque` is only ever true for a dmabuf. The panels provider implements both cases in `lua/lunette-plugins/panels/init.luau` (`OPAQUE_FRAGMENT`, `ALPHA_FRAGMENT`, and `contentShader`), creating the shaders on first use because the graphics module does not exist while a configuration loads.

Panel layers are opaque. A layer copy is a Vulkan copy or blit, which cannot force a component, and no shader runs on that path. `LovrLayers::create` clears `transparent` on every layer, so OpenXR receives no `XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT` and OpenVR uses its opaque convention. A window that needs translucency renders in the scene.

### Colour transfer

Imported desktop textures keep their encoded SDR sRGB values and use non-sRGB views. Layer copies keep those values unchanged. Scene rendering decodes them with LÖVR's `gammaToLinear` before linear blending. Translucent pixels are unpremultiplied, decoded, and premultiplied again in linear space; zero-alpha pixels give zero colour. The panels provider restores shader, material, blend mode, colour, and transform after drawing. A custom source renderer carries the same conversion obligation.

### Forced conversion

Multi-planar YUV buffers, from hardware video decoding and some PipeWire formats, need `VkSamplerYcbcrConversion`, which LÖVR lacks. They are converted to an RGBA texture. Lua sees no difference.

## Synchronisation

Client-to-compositor synchronisation is implicit, as in WayVR. There is no `linux-drm-syncobj-v1` support. Explicit sync needs external semaphore import in LÖVR ([LÖVR integration](lovr-integration.md#possibly-later)).

The compositor thread submits no GPU work; it only creates images. Every copy, including layer blits, stabilised copies, and conversions, is recorded in LÖVR's command stream on the main thread.

The OpenVR backend submits rendering and a transfer-source barrier before calling the runtime under the shared graphics queue guard, then submits a restoration barrier. Normal frames perform no device-wide wait. Retiring an overlay waits for quiescence, destroys the runtime handle, invalidates the backing, and drains deferred destruction; a failed runtime destruction keeps the backing for a retry.

## The layer pool

`lovr.headset.setLayers` sets a persistent, last-call-wins list, bounded by `MAX_LAYERS` and the runtime. Because the list persists, an undamaged layer needs no new work from lunette. OpenXR re-composites the last released swapchain image. OpenVR keeps the visible overlay texture, but a mutable layer still copies its backing into the output image and hands it off on every submission; only immutable OpenVR layers reuse their output.

Layers are expensive to create: an OpenXR layer allocates a swapchain synchronously, and an OpenVR layer allocates backing and overlay handles. Rust owns a pool that recycles whole `Layer` objects keyed on their size, the width and height `LayerInfo` fixes at creation. The other `LayerInfo` fields are the same for every layer: each is created mono, mutable, opaque, and filtered. No source produces stereo content, and a pooled layer is reused, so it cannot be immutable. A released 1920x1080 layer goes to the next 1920x1080 claimant with no allocation. Pose, size in metres, curve, colour, viewport, and origin all have setters and are not part of the key. Format is not part of the key, because LÖVR creates every OpenXR layer swapchain as `VK_FORMAT_R8G8B8A8_SRGB`.

Requested sizes are rounded up to a ladder of discrete steps before keying, so a panel resized by a drag settles on sizes the free list already holds. The same ladder supplies the fractional scale steps (`lunette.scaleSteps()`).

The division between Rust and Lua:

- A claim carries a priority number from Lua, fixed for the claim's life. A caller whose ranking changes releases the claim and claims again, as the panels provider does. Rust sorts by the number and grants the top claims within the budget; it adds no ranking of its own.
- A claim's `granted` and `layer` report the outcome of the latest frame boundary, and the panels provider reads them every frame: it draws in the scene while its claim holds no layer and onto the layer while it holds one. When a layer frees, the highest-priority ungranted claim receives it at the next frame boundary.
- A granted claim exposes a real LÖVR `Layer`, which becomes invalid on revocation.
- Rust makes one `setLayers` call per frame from the granted claims. A script that does not use claims can call `lovr.headset.setLayers` itself.
- Revocation happens at frame boundaries, so Lua never holds a dead `Layer` inside `lovr.draw`.
- A claim whose surface has not committed since its last copy is not copied again.

The OpenXR budget stays below `XrSystemGraphicsProperties::maxLayerCount`, because `XR_EXTX_overlay` shares the runtime's capacity with a primary application whose layer count is unknown. OpenVR caps created panels at 62 and reserves two overlays for the projection eyes; omitted panels and panels awaiting cleanup count. That cap is local accounting, not an SDK guarantee.

A live session whose reported limit leaves no budget grants no claims and attempts no layer creation. The pool logs the reported limit, size, and claim id once per claim in that session. A failed allocation uses the same once-per-claim refusal state. Session loss resets that state, and an absent session produces no zero-budget warning. `LayerBudget::from_runtime_limit` and `LayerPool::resolve` in `crates/lunette/src/layers/pool.rs` define the budget and reporting.

## Frame pacing

A Wayland client draws only after the compositor answers its `wl_surface.frame` callback, so lunette controls when every client renders. The native mechanisms are:

- Per-window frame-callback throttling, `window:setFrameRate(hz)`.
- Per-output advertised refresh, which clients use for their own pacing ([Compositor](compositor.md#outputs)).
- Damage-driven layer copies.
- Skipping lunette's scene when nothing needs drawing.

The native layer enforces a floor of 1 Hz: a lower rate is paced at 1 Hz. A client that receives no frame callbacks often stops processing input as well. The content type from `wp_content_type_v1` is reported as `win.contentType`.

Policy is Lua. The pacing provider, `@lunette-plugins/pacing`, applied by the `desktop/pacing` entry, sets each panel's rate from whether it is hidden, and exempts video, detected from the content-type hint or from a commit rate close to full. The hint covers a paused video; the commit rate covers a player that sets no hint. [Frame pacing and output scale](lua-api.md#frame-pacing-and-output-scale) states the policy.

lunette submits an XR frame every cycle, as an overlay must. The saving is in lunette's own scene rendering.

### Skipping the scene

`lunette.setSceneEnabled(false)` skips the scene ([Lua API](lua-api.md#scene-rendering)). OpenXR acquires the colour swapchain inside `lovr.headset.getPass` and `lovr.headset.getTexture`, so a frame that calls neither skips the acquire, the wait, the render pass, and the resolve. `etc/boot.lua` calls `getPass` every frame and `lovr.mirror` calls `getTexture`. lunette keeps LÖVR's `lovr.run` ([LÖVR integration](lovr-integration.md#boot)) and wraps those two functions (`crates/lunette/src/scene.rs`) so each returns nothing while the scene is skipped; `boot.lua` then finds no pass and does not call `lovr.draw`. `setLayers{ main = false }` on its own saves little, because on OpenXR it only omits the already-rendered projection layer. On OpenVR it hides the two projection overlays.

A skipped frame still paces the runtime and updates predicted tracking. On OpenXR it makes the three frame calls and submits a quad layer per flat panel. On OpenVR it performs the overlay wait and snapshot update, hides omitted overlays, and still copies and hands off each mutable panel's backing. When there is no pass and no window, lunette submits LÖVR's command stream itself, because `boot.lua` submits only alongside a pass.

## Decisions

Zero-copy import is the default, and stable per-surface textures are opt-in through `window:stabilize()`. A persistent texture per surface would cost a full copy per damaged frame (about 3 GB/s for a 4K mirror at 90 Hz) and would make the layer path two copies instead of one.

Rust owns the layer pool and Lua supplies the priority. Allocation needs one owner and a recycling policy; ranking is application knowledge. A pool in Lua was rejected because direct creation churned layers.

An opaque dmabuf's alpha is forced by the consumer, not at import. A `wl_shm` buffer is repacked on import, so its padding byte is fixed during the copy; a dmabuf is imported without a copy, so nothing writes to it. A `VkComponentMapping` on the image view would solve it structurally, but LÖVR creates the view from `TextureInfo`, and adding a swizzle field is a fork patch not yet justified. It becomes the right fix if a second consumer has to repeat the shader.

Composition layers are opaque rather than transparent per claim. A view swizzle does not reach a copy, and a copy cannot force a component, so the layer's blend flag is the only place to discard padding alpha. A per-claim transparency flag was rejected because the key is fixed at claim time while a client's format can change afterwards. The cost is that a translucent client holding a layer is composited opaque.

The layer path counts its own buffer installs rather than using smithay's `RendererSurfaceState`. `on_commit_buffer_handler` takes the buffer that the compositor's `commit` handler needs for import, and reading it back from smithay would move buffer release to smithay while lunette already releases it. `TextureLedger` stamps each installed texture with a session-wide `SurfaceCommit`, and the blit path copies when the stamp differs from the last copied one. This also catches a new buffer committed with no damage, which smithay's damage counter misses.

A mirrored monitor has its own texture ledger keyed by monitor identity. A surface needs a death flag, damage, a stabilised copy, and retirement scheduling; a monitor needs none of them but must record the image behind each texture, because the importer answers a recycled PipeWire buffer with an existing image.

The imported-image acquire uses `VK_QUEUE_FAMILY_FOREIGN_EXT` from `VK_IMAGE_LAYOUT_GENERAL` by default. The specification describes the foreign family for a producer outside Vulkan, and `VK_EXT_queue_family_foreign` is enabled for it. WayVR uses `VK_QUEUE_FAMILY_IGNORED` on Mesa, and on the NVIDIA proprietary driver both families gave the same content census from `GENERAL`: five distinct colours, with the background at 98.5 per cent of the samples. Two drivers tolerating `IGNORED` do not show that it is correct, and the run had no validation layer to tell a correct barrier from a tolerated one, so the default stays on the conformant value. `TextureInfo.foreign` stays for the same reason. That driver kept an imported image's contents across a per-frame acquire from `UNDEFINED`, but the specification permits the discard, and a Mesa driver that performs it would not be caught on that machine. `LUNETTE_IMPORT_QUEUE_FAMILY` and `LUNETTE_IMPORT_LAYOUT` select the alternatives ([Build and development](build-and-development.md#the-development-loop)).

The two measurements taken with the `UNDEFINED` old layout, one per queue family, are invalid. The release barrier then passed `UNDEFINED` as its `newLayout`, which `VUID-VkImageMemoryBarrier2-newLayout-01198` forbids, so they describe a driver tolerating a violation rather than an indifferent queue family. The release now returns the image in `VK_IMAGE_LAYOUT_GENERAL` whatever the switch says. Until the two are repeated on a GPU with a client, the `UNDEFINED` half of the queue-family comparison and of the discard question is unmeasured. The default rests only on the `GENERAL` measurements, so nothing depends on the repeat. Issue #25 tracks it.

`LayerBudget::CEILING` caps the layer budget at 12 slots, below which the budget is a quarter of the runtime's reported limit. Monado with a real compositor reports `XRT_MAX_LAYERS`, 128 on Linux, so a quarter is 32 and the ceiling binds. Twelve layers, more than LÖVR's former `MAX_LAYERS` of 10, were drawn and submitted for 60 frames against that limit with no OpenXR error. With a Bigscreen Beyond under Monado, an 800x600 window took the 832x640 rung, the first grant arrived two frames after the claim with no stall in `lovrLayerCreate`, and a release followed by a claim of the same size was granted from the free list in one frame. Monado's null compositor is not a zero-layer runtime. At revision `1c5fbbdadcccacd947abb1b6089c7303ab3c3bce`, a run with `XRT_COMPOSITOR_NULL=1`, `SIMULATED_ENABLE=1`, a private `XDG_RUNTIME_DIR`, and an explicit `XR_RUNTIME_JSON` reported a Monado driver, session generation 1, and a layer limit of 128. Its [null compositor](https://gitlab.freedesktop.org/monado/monado/-/blob/1c5fbbdadcccacd947abb1b6089c7303ab3c3bce/src/xrt/compositor/null/null_compositor.c) advertises `XRT_MAX_LAYERS`. It cannot verify a runtime-reported zero limit.

A fault-injection run against that live session forced `lovrHeadsetGetLayerLimit` to return zero through a debugger. Three claims requesting 800x600 for a mapped Wayland window, followed by one replacement claim at frame 120, stayed ungranted for 240 frame boundaries. A breakpoint on `lovrLayerCreate` recorded no calls, and the pool logged four zero-budget warnings, one per claim. The run exited successfully. Layer-pool tests cover zero allocation attempts, limits below one budget slot, an absent session, recovery to a positive budget, and reporting after session replacement. The regression tests and live-session fault injection provide sufficient coverage for issue #3. A runtime that natively reports zero remains unobserved; the injected limit does not establish that runtime behaviour.

A composition layer is not required to be visibly sharper than a scene quad. A 1600x1200 client on its 1664x1280 rung, shown 0.6 m wide at 0.8 m and facing the viewer, was alternated every five seconds with a scene quad at the same pose and size. The panel subtended about 41 degrees at about 40 display pixels per degree, close to 1:1, and the observer could not tell the two apart. One well-filtered resample of a stationary, axis-aligned, roughly 1:1 image costs little. A layer is expected to win at oblique angles, under minification at a distance, and under reprojection when the session's frame rate diverges from the runtime's, and that comparison covered none of them. The layer pool rests on the scene skip instead: with three panels on layers and an empty `lovr.draw`, skipping the scene cut CPU time per frame from 0.312 ms to 0.153 ms on a debug build, at the same frame count, because the display paces both. Issue #23 tracks the same measurement under the shipped configuration, whose scene draws chrome.

A panel on a layer cannot be seen from behind, because a quad composition layer is single-sided, while the same panel on a scene quad can. The panels provider chooses when a panel holds a layer, so a grant landing makes a panel that was readable from behind disappear. The scene quad is the fallback rather than a degraded mode, and this is the one visible difference between the two paths that the fallback does not account for.

### Bounded analytic background

The aurora uses indexed meshes and analytic shaders instead of texture feedback or offscreen history. This keeps per-frame work bounded and lets context shutdown release all renderer-owned meshes and shaders. A screen-wide audio brightness response was rejected because it obscures the spatial effect and can create abrupt changes. Band features instead alter separate geometric parameters, and bounded onset waves carry local events. Each band has its own hue, altitude, and onset action so that registers stay distinguishable when several are active; a single colour ramp driven by loudness was rejected because it merges the registers. An eight-band spectrum laid across the height of every curtain was rejected after offscreen renders of recorded music: adjacent bands drew horizontal rows that crossed the strands into a plaid, and the band hues at the extremes fell where the curtain feathers out, so only the mid hue showed. Giving each band a whole curtain was tried next and rejected: three stacked solid-colour curtains read as a flag rather than an aurora, and lost the glow of the original translucent gradient. The present design keeps three coarse altitude zones with smooth falloffs, which avoids the plaid, and puts the hem, the bass zone, at the sharp bright lower edge rather than in the feathered region. Painted curtains with alpha comparable to their colour were rejected because overlapping curtains occluded one another into flat colour; emitted light adds where curtains overlap. A per-channel colour clamp was rejected because stacked onset light pushed two or three channels to the bound and bleached the curtains toward grey; scaling by the largest channel keeps the hue. A bass flash on the sky's horizon was rejected because it sat below the curtains as a detached stripe. Steady kicks had held every bass-coloured effect on continuously when the whole swell took the bass colour. A fast decay of the whole flash fixed that but removed the outward ripple, so the colour now travels only in narrow rings while the punch at the origin decays within a beat. High-contrast rays drawn as powered sines read as bars reaching into the sky and strobed as they moved, so the rays are soft, lean with height, and vary along their length. The steady band levels attack over 0.12 seconds rather than 0.06, because frame-to-frame level changes flickered the ray tops; onsets carry the transients instead. The autonomous terms once used multipliers so small that a cycle took tens of minutes, which left the curtains almost static, so they now run in the range of seconds to about two minutes. Onsets once anchored at the panel that played the selected process's audio, or at -z for system audio, which gave the environment a fixed front; scattering them all around the ring put most of them out of view. Anchoring them to a quantised head direction keeps them in view without following every head movement. Shader colour bounds and continuous fades reduce abrupt contrast changes but do not establish headset comfort.

### Child surfaces are drawn by Lua

The compositor reports a window's popups and subsurfaces with their own textures, and the panels provider draws them, as it draws the window. Compositing the surface tree into one texture per window on the frame thread, as WayVR does into its overlay, was rejected. It would replace the zero-copy import with a render pass into a lunette-owned image whenever a window has a child, duplicate the alpha and colour conversion the panels provider already performs in a native shader, and take the decision of where a child appears away from Lua, which places, clips, and picks panels. It would have made layers, `window:stabilize()`, and every other consumer of a window's texture show children with no change of their own. Drawing them in Lua instead gives a window with children the scene path, and leaves a custom renderer to draw them itself.

### Rejected: keying the pool on swapchains

The pool recycles whole `Layer` objects. LÖVR offers no way to separate a layer from its swapchain: `struct Layer` embeds its `Swapchain` by value, `lovrLayerDestroy` destroys it inline, and nothing sets the swapchain a layer's `subImage` names. Separating them would mean refcounting `Swapchain` and rewriting `subImage` on both the quad and cylinder records, a behavioural patch the fork rules forbid. Keeping the whole layer meets the same goal, because everything a panel varies has a setter.

### Imported images are abandoned at a restart, not destroyed

A restart destroys the `VkDevice` every imported image belongs to. lunette forgets the images rather than destroying them. LÖVR retires an imported texture's view through its morgue, which only `gpu_destroy` empties, and destroying an image that still has a view is invalid. Forgetting ensures no old handle outlives its device.

This violates `VUID-vkDestroyDevice-device-05137`: the validation layers report one image and one device memory object per abandoned image on every restart. That output is expected. A restart with two clients connected, under the Khronos validation layer against a live session, reported only that message, and both clients re-imported. Flushing the morgue first was rejected: `FrameDriver::quiesce` runs after the boot coroutine has finished, so no further LÖVR tick is available, and the morgue is emptied inside `lovrGraphicsSubmit`, outside lunette's FFI surface. Destroying the images and leaving views over freed memory would be a use-after-free.

### A lost session is observed by the pool, and by identity

A restart is a teardown lunette performs: `FrameDriver::quiesce` shuts the pool down while the session exists, then forgets the claims. A session lost under a live Lua state, such as `lovr.headset.stop()` followed by `start()`, is one lunette observes. The native backend retires every registered layer before destroying the session, so a retained layer holds only a CPU wrapper.

`LayerPool::resolve` reads `LayerBackend::session` at every frame boundary. A missing or different session runs `session_lost`: stale layers are released, every grant is revoked so Lua falls back to the scene, and nothing is granted until a session is present at a boundary, where the budget is read again. The session is identified by `lovrHeadsetGetSessionGeneration` rather than by presence, because a stop and start within one callback leaves a session present at both boundaries while every swapchain died between them. The layer limit is not a signal either, because it belongs to the system, which survives a stopped session.

### Rounded meshes and conservative clips

Clipped meshes remove corner pixels, hit area, and depth together. Rectangular content clips let text and hooks stay inside the silhouette without stencil or offscreen passes, which were rejected for their pass requirements and composition cost. The cost is less content room near corners. Controls keep rectangular hit targets, because a chord-clipped hit area would remove usable area from small keys; the panel perimeter still excludes the outer cutouts.

### Joining follows the actual rendering path

The target owns joining and the single outline because it owns the body geometry and the actual layer state. A narrow attachment avoids exposing curve or grant state through generic surfaces and avoids a general container API. The header's outline governs the whole frame so header and body styles cannot produce a doubled seam. Granted layers stay rectangular because the runtime receives an unchanged copy; forcing scene fallback on a radius change would trade legible text for appearance and churn claims. A curved body keeps a separate titlebar because joining would need a curved header.

### Native drag policy stays unchanged

Native pointer motion stops on a perimeter miss, and the release still reaches the original sink. Extending motion through cutouts would add capture projection and change application drag behaviour. Protocol surfaces already project captures with an explicit outside state.

## Known gaps

A popup is clipped to its window's panel, because a panel is picked only over the window's own area. The compositor constrains a popup to its window where the client's positioner allows, but a popup that reaches outside it anyway, such as a menu taller than its window, is cut off and its outside part cannot be pointed at.

A window that shows a subsurface for its whole life, as some video players do, never holds a composition layer, and `window:stabilize()` copies only the window's own surface.

A client's buffer transform is not applied when a window is drawn, so a transformed buffer is drawn untransformed and a crop of one samples the wrong region.

The OpenVR backend does not detect unchanged mutable layer content, so an idle native panel still costs an internal copy and handoff each frame.

OpenVR presentation uses native panels and two per-eye projection overlays. It submits no `IVRCompositor::Submit` frames and has no occlusion against a game's depth. On hardware, native overlays appear at their intended positions, scene content registers with native panels under head motion ([LÖVR integration](lovr-integration.md#decisions) records the projection convention), and the wrist UI appears on Steam Frame controllers.

Geometry and draw recorders do not establish rasterization, MSAA edges, alpha blending, stereo seams, or cutout depth on a GPU. The offscreen graphics checks establish selected single-sample rasterization, blending, and cutout-depth properties for the production aurora on lavapipe. Stereo seams, headset comfort, brightness under sustained loud input, prolonged motion, and runtime-specific visibility transitions still require manual headset checks.

OpenXR main-session visibility depends on `XR_EXTX_overlay` events. An unsupported runtime or one that does not send those events leaves the observation false. The background then remains eligible to render until its enabled control is disabled; false does not establish that no main session exists.

LÖVR graphics pipelines belong to the shader specialization that creates them. A clone has its own cache even while it shares its parent's GPU shader. Shader release removes its cache entries and pipeline wrappers; the GPU defers native pipeline destruction until submitted work completes. This prevents a reacquired sky or curtain shader from selecting a pipeline left by a released shader whose shader and flag addresses were reused. Compute pipelines follow the same ownership boundary, and failed clone initialization releases its partial resources. The strict ten-reacquisition pixel test and a clone-specialization pixel test pass in 20 repeated lavapipe runs. Native regressions cover identical raw keys across 9,000 released cache lifetimes, clone isolation, and compilation failure cleanup. These checks establish lifetime and selected pixel properties, not a total pipeline-memory or driver-cache budget.

Captured dmabufs use the client importer. Shared-memory capture frames in the supported 32-bit RGB layouts are copied, normalised, and uploaded on the frame thread. Frames that supply only a mapped pointer are unsupported, because the pinned callback provides no owned descriptor or validated extent.

Multi-planar YUV costs a conversion.

Synchronisation is implicit only. A client repainting every 100 ms tracked continuously across 24 samples, but no test samples a heavy GPU client under contention, which is the race implicit sync exists to prevent.
