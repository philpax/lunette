# Rendering

## Two ways a panel reaches the eye

Both mechanisms are available. Neither is privileged.

In-scene geometry. The surface texture is sampled by a shader in `lovr.draw`: a textured quad, a cylinder, a mesh, or any other geometry drawn by a script. It costs zero copies and supports arbitrary geometry, custom shaders, depth-correct occlusion against the 3D scene, and post-processing. It renders at the projection layer's resolution and through its MSAA path, so a 1080p terminal at arm's length is noticeably softer than the alternative.

Composition layer. The selected runtime composites a native panel at its backing resolution, with its own reprojection. Native-resolution compositing makes desktop text legible in VR. The imported client buffer is copied into backend-owned layer backing when damaged. OpenXR uses runtime swapchain images and supports quad and cylinder layers with `curve`, plus viewport sub-rects. OpenVR uses owned output images and native overlay handles. Backend capability limits remain explicit; unsupported operations must not silently change geometry.

The panels provider defaults to in-scene rendering so windows participate in scene depth and remain behind session controls. Its `rendering = 'layer'` setting opts window panels into the selected backend's composition layers, with scene rendering as the fallback when a claim is not granted. Monitor panels always render in the scene. That policy lives in Lua ([Standard library](stdlib.md)). The native layer supplies only the two mechanisms.

## Rounded scene geometry

The shared geometry in `lua/lunette-plugins/theme/rounded-geometry.luau` generates convex rounded-rectangle perimeters from actual dimensions and four corner radii. It clamps each radius to the available extents. Zero radius produces a square corner. Each nonzero quarter arc uses eight segments. Drawing and initial picking use the same emitted perimeter, including its straight chords and boundary inclusion rules. A point between an arc's chord and its analytic circle is outside the surface. Border meshes form rings between an outer and an inner perimeter, rather than rectangles behind the content.

Scene-rendered windows and monitors clip their texture meshes to that perimeter. Texture UVs derive from the original panel-local coordinates, so trimming a corner removes pixels without stretching the remaining image. Monitor rotation and flip apply after that local mapping. Curved content splits the clipped polygon at the existing horizontal arc-strip boundaries, then maps each resulting vertex onto the cylinder. The contour is not flattened onto a single plane. Picking maps source-pixel coordinates back to physical surface coordinates and tests the same perimeter. Pose, distance, source orientation, back-face handling, and radius-zero coordinate mapping remain unchanged.

Corner cutouts contain no content triangles or depth-writing border geometry. Farther scene surfaces can remain visible and pickable through them. The existing opaque and premultiplied-alpha colour-conversion shaders still process captured pixels. Geometry excludes cutouts directly; no rounded-alpha shader replaces that geometry.

Meshes belong to an owner or provider activation. The drawing records cache them by dimensions, clip, and corner profile. A geometry change replaces and releases the affected mesh; owner cleanup and provider shutdown release the remaining meshes. Requiring a module acquires no native mesh, and unchanged drawing does not regenerate a mesh each frame.

Native button releases remain paired with the original sink that received the press. Native pointer motion stops when the ray misses the emitted perimeter, as it stops beyond a rectangular edge. Rounding adds no native capture projection. Protocol surfaces retain unbounded `project` for captured movement through cutouts, with `inside = false`. A release there cannot activate a control. The optional boolean passed to `raycast` remains `backFace`; it is not a capture flag. Geometry changes cancel affected Lua captures before notification callbacks. Palette-only changes preserve captures, drafts, focus, and identities.

Granted composition layers retain rectangular content and rectangular hits on either backend. Their claims, raw copies, and rendering mode remain unchanged by a radius update. Rounding never acquires or releases a claim and never forces a granted layer into scene fallback. An ungranted window claim uses the actual scene-rendered profile. Monitor panels always render in the scene. Base, Dark, and Light use zero monitor radius; Arcade uses 0.012 m. An explicit zero monitor radius restores the square scene image and its full rectangular hits.

### UI content clips

A UI panel backing uses its full rounded silhouette. Default controls, descriptions, item geometry, and input use a conservative rectangular content clip inside that silhouette. The backing visual retains full panel bounds; other visuals receive the content-safe clip. Declared panel dimensions and control bounds remain unchanged. Rounded control faces retain ergonomic rectangular hit targets inside the panel content clip, while text safe bounds stay within the rounded face. Reduced content room keeps the existing clipping and overflow indicators.

Default faces clip their emitted polygons to the declared rectangular clips. Text and custom hooks receive conservative rectangular clips instead of a stencil or offscreen target. Hooks must obey `visual.clip`; shipped graph, sidebar, and titlebar action hooks follow that rule. Pass restoration does not forcibly constrain arbitrary shaders or unbalanced stack operations. [UI panels](lua-api.md#ui-panels) defines the hook boundary and logical coordinates.

### Joined flat frames

A shared titlebar joins a supporting live, visible, flat target only while that target actually renders in the scene. A native target with a granted layer cannot join. A joined header rounds only its top outer corners, and the body rounds only its bottom outer corners. The adjoining edges are square and meet at zero margin, regardless of a separated-header margin override. The header's inner width equals the body width. The header top radii clamp to the header's own height; the body bottom radii resolve and clamp independently. Removing or hiding the heading restores the ordinary all-corner body profile.

The target draws one combined outline, including when native `chrome = false`. The header's resolved border thickness, depth, and current normal or highlighted colour govern the whole outline and supersede the body's outline overrides while joined. The former separate header border and ordinary body border are suppressed. For body width W, body height H, and header height h, the inner envelope has width W and height H+h, centred at y=h/2 in target-local metres. The outer envelope expands by the border thickness with consistently derived corner radii. One ring surrounds the envelope, with no outline along the internal seam and no rectangular backing that writes depth in the cutouts.

The titlebar still draws its header face, text, and actions. Action backings and their hover and held faces clip to the actual top-only header perimeter, so an edge action cannot square the outer corner. Action descriptions and hits use the header's content-safe clip. The separate drag surface gates its hit with the same header perimeter before excluding the reserved action width. Cutouts cannot become invisible grab targets. Back-face handling, the owning pose, `grabTarget`, and the existing close, action, and grab behavior remain unchanged.

Curved scene content rounds independently, but its flat titlebar remains separate. Granted layer content also keeps a separate titlebar. Neither treatment implies clipped layer pixels or a continuous frame around a curved body. [Joined frame attachments](lua-api.md#joined-frame-attachments) defines the optional target-owned relationship and its lifecycle.

### UI scene depth

For lunette-owned UI, only opaque backing and outline geometry writes scene depth. Controls, details, selection drawing, and glyphs retain no-write painter ordering. Rendering offsets follow nesting rather than the number of sibling controls. The panel backing is 2 mm in front of its offered surface; control faces add 1 mm, built-in contents add another 1 mm, and glyphs add a further 1 mm. Rounded cutouts add no phantom depth. Intersecting or nearly coincident panels can retain draw-order-dependent details within this millimetre range. This accepted limit does not add per-panel visibility masks.

## Texture import

Client buffers arrive as dmabufs. The native layer imports them as `VkImage`s on LÖVR's device and wraps them as LÖVR `Texture`s via `TextureInfo.handle`.

Import is zero-copy and per-buffer. Wayland clients cycle among 2 to 4 buffers, so a surface's pixels live in a different `VkImage` each frame. An import cache keyed on the dmabuf, WayVR's approach in upstream `src/backend/wayvr/image_importer.rs`, means a surface rotates among a small stable set of textures rather than allocating anything after warm-up.

`window:getTexture()` is therefore valid for one frame only; a script must not hold it across frames. This is consistent with the snapshot model, and matches the practice of other compositors: wlroots, KWin, Mutter, and Hyprland all sample client buffers directly and never make a stabilising copy.

An alternative design, one persistent texture per surface updated by copy, was considered and rejected as a default. It would provide stable Lua identity and format normalisation, but it costs a full-surface copy per damaged frame. A 4K mirror at 90 Hz is approximately 3 GB/s, which matters on an integrated GPU sharing memory with the underlying application. It would also make the composition-layer path two copies instead of one. The composition-layer path is the one that determines text legibility, so doubling its cost is counterproductive.

### `window:stabilize()`

This method is opt-in, for cases that require a persistent texture: running a multi-pass shader chain over a window, taking a screenshot, feeding a mesh with cached bindings, or freezing a window that stopped painting. It is damage-updated, so an idle window costs nothing.

It allocates a lunette-owned texture and copies the client's buffer into it through `lovrTextureCopy`, which is the same call the layer blits use, so there is one copy mechanism rather than two. The cost is the full-surface copy per damaged frame described above, which is why it is opt-in.

A second call returns the same texture rather than allocating another. The identity survives the client cycling its buffers, which is the point of it, and does not survive the client resizing: a LÖVR texture's dimensions are fixed when it is created, so a resize releases the copy and the next call allocates one that matches. It returns `false` on a dead handle, and on a window whose client has committed nothing.

### Alpha

An imported buffer holds premultiplied alpha. A client rendering at 80 per cent opacity writes 0.8 into every channel including alpha, which the milestone measured directly ([Milestone 0 findings](2026-08-06-milestone-0-findings.md#colour-fidelity-and-premultiplied-alpha)). A consumer therefore draws with premultiplied blending; LÖVR spells that `pass:setBlendMode('alpha', 'premultiplied')`. The default alpha mode multiplies the colour by the alpha a second time in the shader, which darkens every translucent client.

Some buffers have no alpha channel at all. `Xrgb8888`, `Xbgr8888`, and `Xbgr2101010` name three components and a padding byte, and Vulkan has no format for that, so each is imported as the alpha-carrying format with the same component order. Whatever the client left in the padding byte then arrives as alpha, and most renderers leave it at zero. Sampling it draws the window fully invisible.

The native layer records the distinction rather than resolving it: `window.opaque` is true for such a buffer, and a consumer forces alpha to one instead of sampling it. The panels provider uses an opaque fragment shader over the default `unlit` vertex stage. It creates the shader on first use because the graphics module does not exist while a configuration loads. `OPAQUE_FRAGMENT` and `contentShader` in `lua/lunette-plugins/panels/init.luau` implement this path. The shared-memory path sets the padding byte to one during repacking, so `window.opaque` is only true for a dmabuf.

Both facts are properties of the buffer, not of the window: a client that renegotiates its format changes `window.opaque` between one frame and the next, so it is read each frame alongside the texture rather than cached.

A composition layer resolves both differently, because it has no shader and no Lua consumer to resolve them in. The copy into a layer is a Vulkan image copy or blit, which reads the image and cannot force a component, and an image-view swizzle does not apply to either. Panel layers are therefore opaque. OpenXR omits `XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT`; OpenVR uses its opaque panel alpha convention. The runtime ignores source alpha on this path, so the padding byte is unreachable whatever the source format, and premultiplication stops mattering. A window that wants its translucency composited renders as an in-scene quad rather than claiming a layer. [Decisions](#decisions) below records the alternatives.

### Colour transfer

Imported desktop textures preserve encoded SDR sRGB values and use non-sRGB sampler views. Raw composition-layer copies keep those values intact. Scene rendering decodes them with LÖVR's `gammaToLinear` before linear blending and the projection target's output encoding. Treating an encoded pixel as linear would encode it again and brighten midtones.

Opaque windows and monitor captures ignore padding alpha. Translucent window pixels are unpremultiplied before decoding and premultiplied again in linear space. Zero-alpha pixels produce zero colour. The panels provider owns both lazily created shaders and restores shader, material, blending, colour, and transforms after drawing. Custom source renderers have the same colour-conversion obligation. HDR colour metadata and actual headset colour fidelity remain unverified.

### Forced conversion

Some buffers cannot be sampled directly. Multi-planar YUV needs `VkSamplerYcbcrConversion`, which LÖVR has no concept of. Those buffers are converted into an RGBA texture transparently. This occurs with hardware-decoded video and some PipeWire capture formats. The Lua-visible behaviour is identical; only the cost differs.

## Synchronisation

Client-to-compositor synchronisation is implicit, as in WayVR: there is no `linux-drm-syncobj-v1` handling and no imported semaphores anywhere in its tree. This works in practice on Mesa.

Explicit sync is a later addition. It needs external semaphore import in LÖVR ([LÖVR integration](lovr-integration.md#possibly-later)) so client fences can be waited on before sampling.

The compositor thread never submits GPU work; its only Vulkan activity is image creation. Every copy, including layer blits, stabilise updates, and format conversions, is issued inside LÖVR's own command stream on the main thread.

The private OpenVR backend uses owned two-dimensional output images. LÖVR submits rendering and a transfer-source barrier before calling the runtime under the shared graphics queue guard, then submits a restoration barrier and completion marker. Normal frames perform no global device wait. Overlay retirement establishes quiescence, destroys runtime handles, invalidates their backing, and drains deferred graphics destruction. A failed runtime destruction preserves the backing for retry.

## The layer pool

`lovr.headset.setLayers` sets a global, last-call-wins list, capped by `MAX_LAYERS` and by whatever the runtime allows. The list persists across frames. `lovrHeadsetSetLayers` retains it in `state.layers` and `lovrHeadsetGetLayers` reads it back, so it does not need setting again every frame.

That persistence makes damage skipping safe. OpenXR's per-layer image work is gated behind `getTexture` or `getPass`, and the runtime re-composites the most recently released swapchain image. OpenVR retains the visible overlay texture, but mutable layers still copy their backing into the output image and perform a Vulkan handoff on every submission. lunette's damage ledger skips the client-to-layer copy; it does not skip OpenVR's internal copy or handoff. Immutable OpenVR layers reuse their submitted output until the viewport changes.

Layers are expensive to create. OpenXR `newLayer` allocates a swapchain with images, memory, and runtime state, synchronously, ending in a wait with `XR_INFINITE_DURATION`. Runtime errors end the wait without an endless retry. OpenVR allocates owned render backing and runtime overlay handles. A panel manager that promotes and demotes panels as the user looks around would allocate one every few frames if Lua created them directly.

Rust owns the pool instead, and recycles whole `Layer` objects, keyed on the properties `LayerInfo` fixes at creation: width, height, stereo, immutable, transparent, and filter. A demoted 1920x1080 panel's layer goes straight to the next 1920x1080 claimant with no allocation.

The unit is the whole `Layer` rather than backend backing. For OpenXR, LÖVR offers no way to separate the layer from its swapchain: `struct Layer` embeds its `Swapchain` by value, `lovrLayerDestroy` calls `xrDestroySwapchain` inline, and nothing exposes the swapchain a layer's `subImage` points at. Nor is a way needed. Everything a panel varies — pose, metre dimensions, curve, colour, viewport, and origin — has a setter and lives outside `LayerInfo`, so keeping the layer alive keeps its swapchain alive and available to any claimant of the same key.

Format is absent from the key because panel backing uses one fixed format. On OpenXR, `lovrSwapchainInit` hard-codes `VK_FORMAT_R8G8B8A8_SRGB`, and session start aborts if the runtime refuses it, so there is nothing to negotiate and nothing to key on.

Requested sizes are quantised to a ladder of discrete steps before becoming a key, so that a panel resized continuously by a drag settles on a rung the free list already holds rather than allocating on every frame of the drag. The same ladder supplies the discrete scale steps reported through `wp_fractional_scale_v1`.

The design keeps this from becoming policy implemented in Rust, through the following division.

- A claim carries a Lua-supplied scalar priority, recomputed as often as Lua requires. Rust never invents the ranking; it sorts by the number it was given and assigns the top N deterministically. Focus, gaze, distance, a rule such as video ranking above a terminal, and hysteresis to stop flapping are all cases of Lua computing a different number.
- Grants and revocations arrive as events (`lunette.onLayerGranted`, `lunette.onLayerRevoked`) carrying the claim handle. The standard library degrades to an in-scene quad on revoke and upgrades back on grant. Upgrades are automatic: when a layer frees, the highest-priority ungranted claim takes it on the next frame.
- A granted claim yields a real LÖVR `Layer` userdata, not a wrapper. It exposes the full `setPose`/`setCurve`/`setViewport`/`getTexture` API and becomes invalid on revoke.
- Rust makes the single `setLayers` call per frame from granted claims. `lovr.headset.setLayers` remains reachable for scripts that opt out of the scheme entirely.

The OpenXR budget stays below `XrSystemGraphicsProperties::maxLayerCount`, because `XR_EXTX_overlay` shares runtime capacity with a primary application whose layer count is unknown. OpenVR separately caps created panels at 62 and reserves two local slots for projection eyes. Omitted panels and pending cleanup still count. This cap is conservative local accounting, not an SDK guarantee of global capacity.

Two details matter if ignored.

- Revocation is deferred to frame boundaries. Revoking mid-frame would leave Lua holding a dead `Layer` inside `lovr.draw`.
- Stale claims skip their blit. A claim whose surface has not been damaged since its last blit is not copied again.

## Frame pacing

The compositor controls when every client renders, because a Wayland client draws only after the compositor delivers its `wl_surface.frame` callback. Combined with `setLayers{ main = false }`, an idle lunette instance can run at close to zero cost.

Native mechanism:

- Per-window frame-callback throttling: `window:setFrameRate(hz)`.
- Per-output advertised refresh, which clients use for their own pacing ([Compositor](compositor.md#outputs)).
- Damage-driven layer blits: an unchanged surface is not copied.
- Skipping the projection layer when Lua drew nothing.

Lua policy decides each panel's rate from visibility, gaze, distance, focus, and whether a game is running. The shipped policy is the pacing provider, `@lunette-plugins/pacing`, applied by the `desktop/pacing` entry, which reads whether each panel is hidden; [Frame pacing and output scale](lua-api.md#frame-pacing-and-output-scale) states it.

Two defaults matter because they are easy to get wrong.

- The floor is approximately 1 Hz, not zero, and the native layer enforces it: a rate below the floor is paced at the floor rather than honoured. Clients starved of frame callbacks often stop pumping their event loops entirely, so they stop responding to input as well. A window that is frozen but alive is worse than one costing 1 Hz.
- Video is exempt by default. A throttled video player stutters conspicuously. The native layer supplies the signal — `wp_content_type_v1`, reported as `win.contentType` — and the pacing provider decides. It exempts on either the hint or an observed commit rate close to full, because each covers the other's blind spot: the hint catches a video paused on a still frame, which commits nothing, and the commit rate catches a player that sets no hint at all, which is most of them.

lunette's own XR frame rate is not negotiable: an overlay submits every cycle whether or not anything changed. What is skipped is lunette's own scene rendering, which is where the savings actually occur.

### Skipping the scene

`setLayers{ main = false }` is the smaller half of it. On OpenXR, the flag leaves the `XrCompositionLayerProjection` out of `XrFrameEndInfo::layers`, by which point the pass has been rendered and resolved. On OpenVR, it hides the two projection overlays. The saving is in not asking for the pass at all. OpenXR acquires the colour swapchain lazily, inside `lovr.headset.getPass` and `lovr.headset.getTexture`, so a frame that calls neither skips the acquire, the swapchain wait, the render pass, and the resolve outright.

`etc/boot.lua` calls `getPass` unconditionally, and `lovr.mirror` calls `getTexture` for the desktop window. lunette keeps LÖVR's `lovr.run` ([LÖVR integration](lovr-integration.md#boot)) and gates those two functions instead: while the scene is skipped each answers nothing, so `boot.lua` finds no pass and does not call `lovr.draw`. Every other function on the module, `lovr.headset.submit` above all, is untouched.

`lunette.setSceneEnabled(false)` is the switch, and the decision is the configuration's ([Lua API](lua-api.md#scene-rendering)).

An idle frame still paces the runtime and updates predicted tracking. On OpenXR, it makes the three frame calls and submits one `XrCompositionLayerQuad` per flat panel without copying unchanged content. On OpenVR, it performs the bounded overlay wait and snapshot update and hides omitted overlays. Mutable OpenVR panels still copy and hand off their unchanged backing each frame. The client-to-layer copies remain damage-gated on either backend. On a frame with no window open and no pass, lunette submits LÖVR's command stream itself, because `boot.lua` submits it only alongside a pass and backend presentation still requires completed command work.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

Zero-copy import over stable per-surface textures. Zero-copy is cheaper and matches what other compositors do. The stabilising copy is available as an opt-in. See [Texture import](#texture-import) for the numbers.

Rust owns the layer pool; Lua supplies the priority. Layer allocation needs one owner and a recycling policy; ranking is application knowledge. This decision was revisited mid-design: the first proposal put the pool in Lua, and layer churn is what ruled it out.

An opaque dmabuf's alpha is forced by the consumer, not by the import. This leaves the same semantic problem solved two different ways in one crate: a `wl_shm` buffer is repacked on the way in, so the padding byte becomes one during the copy and the question never reaches Lua, while a dmabuf is imported without a copy, so whatever the client left in the padding byte survives to the sampler and `window.opaque` reports that it must be ignored. The asymmetry follows from zero-copy import rather than from a preference: there is no write to the dmabuf's memory to fix it in, and adding one would give up the property the import exists for. The alternative considered was a `VkComponentMapping` on the image view, which resolves it structurally at no per-frame cost and would make `window.opaque` unnecessary. It was not taken because LÖVR creates the view itself from `TextureInfo`, so it needs a fifth patch to the fork adding a swizzle field, and the patch set is kept narrow while the milestone is still measuring. It remains the right fix if a second consumer has to repeat the shader. See [Alpha](#alpha) for what a consumer does today.

That obligation is discharged by making composition layers opaque. A layer hands its image to the XR runtime rather than through `lovr.draw`, so no Lua consumer exists on that path and no shader runs, and the padding byte would reach the compositor as alpha. Neither of the two mechanisms named above reaches it. A `VkComponentMapping` lives on an image view, and the copy into a layer is `vkCmdCopyImage` or `vkCmdBlitImage`, both of which read the image and ignore views; and there is no way to force a component during a copy. What is left is the layer's own blend flag. `LayerProperties::PANEL` therefore clears `transparent`, LÖVR passes no `XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT`, and the runtime does not look at the layer's alpha channel at all — for every source format, before and after a client renegotiates one, with no per-frame check to bypass. Premultiplication stops being a question on this path for the same reason.

The cost is that a genuinely translucent client is composited opaque while it holds a layer. Lua chooses: a panel that wants translucency renders as an in-scene quad, where the shader path resolves alpha correctly, and one that wants sharpness claims a layer. Making transparency a per-claim property was considered and rejected: the key is fixed when the claim is made, a client's format changes under it, and a layer that had become wrong for its source would have to be revoked from the blit path rather than from the ranking.

The layer path does not use smithay's `RendererSurfaceState` for damage. `on_commit_buffer_handler` is what populates it, and its first act is `attrs.buffer.take()` — the same buffer `CompositorState::apply_commit` reads to perform the import. Calling it first, as smithay documents, therefore leaves the import path with nothing to import and no client ever displays anything; reading the buffer back out of `RendererSurfaceState` instead would move buffer ownership to smithay, which releases a `wl_buffer` when it drops its own `Arc`, and lunette already releases the same buffer itself. So lunette counts its own installs instead: `TextureLedger` stamps every texture it installs with a `SurfaceCommit` drawn from one counter for the whole session, and the blit path copies when the stamp behind a claim differs from the one it last copied. That predicate is also strictly better than the one smithay offers, because `DamageSnapshot::add` returns without incrementing when a commit posted no non-empty rectangle, so a new buffer with no damage moves neither the counter nor the damage set, while counting installs sees it.

A mirrored monitor's textures are a separate ledger from a surface's, keyed by monitor identity. Reusing `TextureLedger` would mean parameterising it over its key, and the two ledgers want different bookkeeping rather than the same bookkeeping under two keys: a surface carries a death flag, a damage flag, a stabilised copy, and a retirement schedule, because a client can exit mid-frame and Lua can ask for a copy that outlives the frame, and a monitor has none of those. What a monitor's ledger needs and a surface's does not is the image handle behind the texture, because the dmabuf importer answers a recurring PipeWire buffer with the image it already made — so without recording which image is installed, every frame from a recycled buffer would allocate a fresh texture over memory a texture already covers.

### Rejected: keying the pool on swapchains

The pool recycles whole `Layer` objects, not their swapchains. The original framing put the swapchain in that role, keyed by size and format; that is the obvious framing and will be proposed again, so the reason it was not taken is recorded here. LÖVR offers no way to detach one from the other. `struct Layer` embeds its `Swapchain` by value, `lovrLayerDestroy` calls `xrDestroySwapchain` inline and unconditionally, every swapchain function is `static`, and there is no setter for the swapchain a layer's `subImage` names. Patching the fork to allow it would mean splitting `Swapchain` out into a refcounted object and rewriting `subImage` on both the quad and the cylinder structs, because `lovrLayerSetCurve` copies `subImage` between them and a stale handle left in the inactive one resurfaces on a curve change. That is a behavioural change to an existing path, which the fork discipline forbids. The original framing was wrong about the unit and right about the goal, and the goal is met exactly by keeping the whole layer: everything a panel varies has a setter and lives outside `LayerInfo`, so a layer of a given size serves any panel wanting that size, and keeping the layer alive keeps its swapchain alive. Format leaves the key for a separate reason — `lovrSwapchainInit` hard-codes `VK_FORMAT_R8G8B8A8_SRGB` and session start aborts if the runtime refuses it, so there is exactly one and nothing to key on.

### Imported images are abandoned at a restart, not destroyed

Decided 2026-08-07, building Phase 7 Task 3.

A restart destroys the `VkDevice` every imported image was created against, so the images have to be dealt with before `luax_close` runs. They are forgotten rather than destroyed.

Destroying them there would be invalid. LÖVR retires an imported texture's image view through its own morgue, and that morgue is emptied only by `gpu_destroy`; `vkDestroyImage` on an image that still has a view is not allowed. The deferral that makes this work in an ordinary frame counts in frames, and a restart has no further frames of that device to count. This is the same reasoning Phase 2 recorded for shutdown, and the answer is the same.

What forgetting buys is the thing that would otherwise be a defect rather than an untidiness — no handle from the old device survives into the new one's lifetime, where destroying it would be a use-after-free against a device that never created it.

Nothing is leaked, in the sense that `vkDestroyDevice` frees what the device still owns and it runs moments later. It is nevertheless a specification violation, and calling it merely untidy would be wrong. `VUID-vkDestroyDevice-device-05137` requires that every child object created on a device has been destroyed before the device is: a live `VkImage` or `VkDeviceMemory` at that point is invalid usage, not a leak question. The Vulkan validation layers report one `VK_OBJECT_TYPE_IMAGE` and one `VK_OBJECT_TYPE_DEVICE_MEMORY` "Object has not been destroyed" per abandoned image on every restart, under `VUID-vkDestroyDevice-device-05137` and its `OBJTRACK` companion. That is expected output, and the restart gate in the phase plan says so, so that an object the quiesce genuinely missed is still distinguishable from these.

The alternative considered was flushing LÖVR's morgue before the teardown, by releasing the textures and then running enough further LÖVR ticks to empty it through the mechanism `destroy_due_images` already uses. It is not reachable. `crate::frame::FrameDriver::quiesce` runs from `crate::boot::run_steps` after the boot coroutine has already yielded `restart` and finished, so there is no coroutine left to step; and LÖVR empties its morgue inside `lovrGraphicsSubmit`, which is not in `lunette-lovr`'s allowlisted FFI surface. Adding a way to tick the morgue from outside a frame would be a behavioural patch to an existing path, which `CONTRIBUTING.md` rules out for the fork.

The narrower alternative — destroying the images and accepting a `VkImageView` naming freed memory — is worse. That is a use-after-free the driver may act on rather than a validation message, and `crates/lunette/src/texture/lovr.rs` records why the view outlives the image here.

### A lost session is observed by the pool, and by identity

Two teardowns invalidate the layer pool's backend resources, and they are not the same event. A restart is one lunette performs: `FrameDriver::quiesce` runs `LayerPool::shutdown` while the XR session still exists, and `forget_claims` follows because the Lua state that named the claims is going too. A session lost underneath a live Lua state is one lunette observes. The native backend retires every registered layer, including never-submitted layers, before destroying the session. A retained layer then owns a CPU wrapper rather than a live swapchain. The Rust backend releases that wrapper normally. Combined native lifetime regressions exercise retained layers, textures, views, and passes through stop and restart, and enforce GPU retirement before runtime image destruction.

Nothing reports the second event to the pool. The OpenXR backend in `vendor/lovr/src/modules/headset/headset_openxr.c` turns `XR_SESSION_STATE_LOSS_PENDING` into `EVENT_QUIT`, which ends the session rather than rebuilding it, so a runtime-initiated loss is not a case the pool can come back from. The case that is reachable is a configuration calling `lovr.headset.stop()`: it retires the layers, destroys the session, and returns to Lua with the state still running and `lovr.headset.start()` available. A teardown failure retains runtime resources for retry and rejects presentation operations while teardown remains pending.

So the pool asks rather than waits. `LayerBackend::session` answers which session is running, `LayerPool::resolve` reads it at every frame boundary, and a boundary that finds the session gone — or finds a different one in its place — runs `session_lost`: every stale layer reference is released, every grant is revoked so Lua falls back to in-scene quads, and the budget goes to zero. The claims survive holding nothing and are re-evaluated at the boundary after that.

The answer is an identity rather than a flag because presence is not observable at the rate the pool observes it. `lovr.headset.stop()` followed by `lovr.headset.start()` inside one callback is the natural way to reconfigure a session, and both boundaries around that callback see a session while every swapchain the pool held died between them. `lovrHeadsetIsActive` reports true on both sides of it. So the LÖVR fork carries `lovrHeadsetGetSessionGeneration`, a counter incremented when a session is created and zero when there is none ([LÖVR integration](lovr-integration.md)), and `SessionPresence::Present` carries it: two boundaries reading different generations is a loss, whatever presence says.

The layer limit is not the signal either. The OpenXR backend reads `lovrHeadsetGetLayerLimit` from the system, and the system survives a session being stopped, so a pool that inferred loss from a zero limit would see nothing at the one moment it matters.

### Rounded meshes and conservative clips

Clipped meshes remove corner pixels, hit regions, and depth geometry together. Conservative rectangular content clips let the existing text and hook renderers stay inside the silhouette without requiring a stencil-capable pass or offscreen composition. Stencil and offscreen clipping are rejected because they add pass requirements, render targets, and composition cost to bounded panel geometry. The cost of the conservative clip is less content room near corners. Declared bounds and overflow reporting remain intact. Hook clipping is cooperative because arbitrary shader or stack misuse cannot be enforced by this boundary.

Rounded controls keep rectangular ergonomic hit targets inside the panel content clip. Applying each control face's chord perimeter to its hit target would remove usable corner area from small buttons and keys. The panel perimeter still excludes initial hits in outer cutouts, so this control policy does not make invisible panel corners interactive.

### Joining follows the actual rendering path

The target owns joined-frame eligibility and the single outline because it owns the body geometry and actual layer state. An optional narrow attachment avoids exposing native curve or grant fields through generic surfaces and avoids a general container or shape-transform API. The resolved header outline governs the complete joined frame so explicit header and body styles cannot create conflicting thicknesses or a doubled seam.

Granted layers stay rectangular because the runtime receives an unchanged raw image copy and supplies its own quad or cylinder. Forcing scene fallback on a radius change would silently trade native-resolution text for appearance and cause claim churn. Flat titlebars remain separate from curved bodies because joining them would require a curved header outside the shared titlebar contract. Rounded curved content remains supported independently.

### Native drag policy stays unchanged

Native motion stops on a perimeter miss, while the matching release still reaches the original sink. Extending native motion through cutouts would add capture projection and change application drag policy. Protocol surfaces already support unbounded projection with an explicit outside state, so their captures continue without permitting corner release activation.

## Known gaps

The OpenVR backend does not detect unchanged mutable layer content before its internal output copy and Vulkan handoff. Pooled panel layers are mutable, so an idle native panel still incurs that work even when lunette skips its client-to-layer copy. Backend content-change tracking remains unimplemented.

Named, not solved.

Geometry and draw recorders do not establish native rasterization, MSAA edge quality, alpha blending, stereo seams, or cutout depth behavior on a GPU. The operator-run `theme-rounded-content`, `theme-joined-frame`, `theme-widget-edges`, and `theme-rendering-exceptions` checks remain pending. They cover flat and curved content, transformed and portrait monitor UVs, emitted-edge hits, no-gap joined seams, action and drag cutouts, safe clips, and actual granted-layer behavior. The `theme-appearance-matrix` and `theme-runtime-switch` checks remain pending for preset contrast and input continuity. `theme-font-fit` covers real development and installed-session font loading and fit. Neither a geometry recorder nor an installed artifact byte check completes those gates.

OpenVR presentation is implemented through native panels and two per-eye projection overlays. It submits no `IVRCompositor::Submit` scene frames and provides no occlusion against a game's depth. Internal scene depth and MSAA do not imply game-depth integration. Hardware observation confirms native terminal overlays appear at their intended positions. Scene-rendered content registers with native panels at the same world pose, across the field of view and under head motion, once the projection overlays receive the overlay API's view matrix and frustum convention, recorded in [lovr-integration.md](lovr-integration.md#decisions). The wrist UI appears once Steam Frame controllers have a binding for the grip pose it attaches to. Stereo alignment, alpha, motion, and full visual acceptance remain unverified. Deterministic metadata and handoff tests do not prove visual equivalence.

Captured DMA buffers use the existing importer. Descriptor-backed shared-memory frames in the supported 32-bit RGB layouts are copied, normalized, and uploaded or refilled on the frame thread. Arbitrary mapped-pointer frames remain unsupported because the pinned callback does not supply an owned descriptor and a validated storage extent. The built-in monitor panels apply the frame's rotation and flip to UVs and use logical geometry for proportions; GPU-backed portrait capture still needs manual acceptance testing.

Multi-planar YUV costs a conversion. LÖVR has no `VkSamplerYcbcrConversion`. This affects hardware-decoded video and some capture formats.

Implicit sync only, for now. This works on Mesa in practice, as WayVR demonstrates. Explicit sync needs a LÖVR patch.
