# Milestone 0 findings

Milestone 0 exists to de-risk two unknowns before a standard library is written on top of them: the LÖVR Vulkan patch, and the compositor-thread split with the snapshot model it forces on Lua. [Roadmap](roadmap.md) states both. This document records what the two actually did, so phases 4 to 8 are detailed against measurement rather than against the design's expectations.

Eight acceptance criteria are human gates and are not recorded here as passed: two from milestone 0, one from the composition-layer work that follows it, and five from the monitor-mirroring work after that. They are listed under [Outstanding](#outstanding), together with the two measurements that have to be taken.

## The machine

Every measurement below comes from one machine, and every conclusion is therefore about one driver.

| | |
|---|---|
| GPU | NVIDIA GB202, PCI `10de:2b85`, marketed as the RTX 5090 |
| Driver | NVIDIA proprietary, through `nvidia_icd.json` |
| Vulkan device | 1.4, of which LÖVR requests 1.1 |
| Render node | `/dev/dri/renderD128`, reported by `VkPhysicalDeviceDrmPropertiesEXT` as `226:128` |
| Validation layers | none installed |

The absence of a validation layer matters for how the results below should be read. Nothing here is VUID evidence. Every claim is functional: the call returned success and the pixels were what the client drew. A layout or ownership rule broken in a way this driver tolerates would not have been caught. WayVR's experience is on Mesa, so a difference between the two is itself a finding rather than a contradiction.

## The check suite

All five commands from [CONTRIBUTING.md](../CONTRIBUTING.md) pass, run inside `nix develop`.

| Command | Result |
|---|---|
| `cargo +nightly fmt --all -- --check` | clean |
| `cargo clippy --all-targets --all-features -- -D warnings -W clippy::unwrap_used -W clippy::expect_used` | clean |
| `cargo clippy --all-targets --no-default-features -- -D warnings -W clippy::unwrap_used -W clippy::expect_used` | clean |
| `cargo test --workspace` | 623 passed, 0 failed, 0 ignored |
| `cargo test --workspace --no-default-features` | 623 passed, 0 failed, 0 ignored |

The 623 are 256 in `lunette`, 18 in its binary target, 3 in `tests/exit_status.rs`, 6 in `tests/host_outputs.rs`, 234 in `lunette-capture`, 96 in `lunette-compositor`, 6 in `tests/client_lifecycle.rs`, and 4 in `tests/pointer_routing.rs`. The compositor's 106 run with no graphics device and no XR runtime, which is the separation [CONTRIBUTING.md](../CONTRIBUTING.md) requires of `lunette-compositor`. The count is the whole workspace as it stands, so it grew past milestone 0: the composition-layer work under [composition layers](#composition-layers) is 61 of it, being everything under `layers::` and `lua::tests::layers`, and the monitor-mirroring work under [monitor mirroring and host input](#monitor-mirroring-and-host-input) is the 234 in `lunette-capture` plus the 6 in `tests/host_outputs.rs`.

No dependency in the tree names `async-std` or `ashpd`: `cargo tree | rg -c 'async-std|ashpd'` counts zero. Both would arrive with the published wlx-capture 0.5.4, and the pin is the 0.6.0 in the WayVR monorepo at `98f800c6` for that reason.

## Provenance

Every file in `crates/lunette-compositor/src/` either carries the WayVR header or is lunette's own. The check is `rg --files-without-match 'Ported from WayVR' crates/lunette-compositor/src/`, compared against the list of original files in [crates/lunette-compositor/PROVENANCE.md](../crates/lunette-compositor/PROVENANCE.md). Seven files are headerless and all seven are on that list.

`vendor/lovr` carries three patches on top of upstream `fdf1669f`, touching `src/core/gpu.h`, `src/core/gpu_vk.c`, `src/modules/graphics/graphics.c`, and `src/modules/graphics/graphics.h`. None adds a file. Upstream carries per-file copyright headers only under `src/lib/`, which is its own vendored third-party code, so the four patched files inherit the repository's MIT `LICENSE` and a per-file header would be a departure from upstream rather than a match to it.

`CREDITS.md` and the licensing table in [decisions.md](decisions.md#licensing-and-credit) agree: WayVR GPL-3.0-only with `wayvr-ipc` MIT, LÖVR MIT, awesome GPL-2.0 for ideas only.

## The LÖVR Vulkan patch

### The transition out of an undefined layout

The hazard is `gpu_vk.c:3789` upstream: `gpu_texture_upload` records a barrier whose `oldLayout` is `VK_IMAGE_LAYOUT_UNDEFINED`, and a texture created with no images still submits an empty upload solely to reach the natural layout. Over an imported image that already holds a client's contents, that transition permits the driver to discard them. `TextureInfo.foreign` exists to suppress it.

The driver does not discard. `LUNETTE_IMPORT_LAYOUT=undefined` makes `gpu_import_acquire` record the same `UNDEFINED` to `GENERAL` transition over the imported image, once per frame, and the contents survive it. A terminal on a solid background was imported, left quiescent for four seconds while several hundred such barriers were recorded and submitted, and then read back. The census is identical to the `general` run to within sampling noise: 7500 samples, 5 distinct colours, the background occupying 98.5 per cent of them.

That run is subject to the release-barrier defect recorded under [the queue family for the acquire](#the-queue-family-for-the-acquire): with the switch at `undefined` the release recorded an illegal `newLayout` as well, so what survived was a frame of barriers of which one was invalid. The acquire under test was legal throughout, and the content surviving is still the observation, but the run should be repeated now that the release is fixed before the result is treated as settled.

So the `foreign` flag was prudent rather than necessary on this driver. That is not an argument for removing it. The specification permits the discard, the patch is written against the specification rather than against one implementation, and the cost of the flag is one branch. The finding to carry forward is narrower and more useful: a discard on a Mesa driver will not be caught by any test on this machine, so the first Mesa run is where this question is genuinely answered.

### The queue family for the acquire

`VK_QUEUE_FAMILY_FOREIGN_EXT` and `VK_QUEUE_FAMILY_IGNORED` are indistinguishable here. `LUNETTE_IMPORT_QUEUE_FAMILY` was measured at both values, crossed with both layouts, and all four runs produced the same census:

| Queue family | Old layout | Distinct colours | Dominant colour share |
|---|---|---|---|
| `foreign` | `general` | 5 | 0.9853 |
| `foreign` | `undefined` | 5 | 0.9855 (invalid, see below) |
| `ignored` | `general` | 5 | 0.9855 |
| `ignored` | `undefined` | 5 | 0.9853 (invalid, see below) |

The two `undefined` rows are not evidence and are kept only so the record is not silently rewritten. The release barrier passed the same layout the acquire did, so with the switch at `undefined` every frame recorded `VK_IMAGE_LAYOUT_UNDEFINED` as a barrier's `newLayout`, which VUID-VkImageMemoryBarrier2-newLayout-01198 forbids. With no validation layer present the run could not have noticed. Those two rows therefore describe a driver tolerating a spec violation rather than the queue family being indifferent, and the same defect taints the `undefined` half of [the transition out of an undefined layout](#the-transition-out-of-an-undefined-layout) above.

The release now hands the image back in `VK_IMAGE_LAYOUT_GENERAL` whatever the switch says — the acquire is the half the switch was measurable in, and `UNDEFINED` is legal only there. The four-cell measurement was not re-run; it needs the census harness, a real GPU, and a client. It is tracked under [Outstanding](#the-two-undefined-rows-of-the-queue-family-measurement), and it should be re-run before either row is cited. The `general` rows are unaffected, and they are the rows the default rests on.

`foreign` remains the default, because it is what the specification describes for a producer outside Vulkan and because it is what `VK_EXT_queue_family_foreign` is enabled for. WayVR uses `IGNORED` and works on Mesa; this run shows the NVIDIA proprietary driver is equally indifferent. Two drivers being indifferent is weak evidence that all are, and with no validation layer present the run cannot distinguish "correct" from "tolerated". The default stays on the specification-conformant value for that reason.

### Implicit sync

Implicit sync sufficed. No stale frame and no torn frame was observed.

The staleness test spawns a terminal repainting on a 100 ms timer, samples the imported texture 24 times at 250 ms intervals, and reduces each sample to a signature. All 24 signatures were distinct and no two consecutive samples matched. The client cycles three buffers and lunette imported exactly three images for the whole run, so every sample after the first read a recycled buffer whose contents the client had rewritten. Content tracked the client continuously, which is the property a missing acquire would break.

The result is weaker than it sounds, and the weakness should be recorded rather than glossed. The failure implicit sync exists to prevent is a GPU-side race: lunette sampling a buffer whose write the client's GPU has not finished. A terminal at 800x600 completes its work far faster than the interval between reads, so this environment never forced the race. A test that samples a heavy GPU client under contention would be a stronger instrument, and no such test exists yet. The strong form of this question is unresolved, and the human gate under a real headset is where it will first be exercised in earnest.

### Formats and modifiers advertised

Six fourccs are offered. Each one reported seven modifiers through the two-call `vkGetPhysicalDeviceFormatProperties2` idiom, all seven single-plane, and all seven survived the per-candidate `vkGetPhysicalDeviceImageFormatProperties2` pass at `VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT` with the sampled, transfer-source, and transfer-destination usage lunette declares. `advertise` therefore produced 48 entries: six fourccs times seven modifiers plus `Modifier::Invalid` each.

The seven are the same set for every fourcc.

| Modifier | Decoded |
|---|---|
| `0x0300000000606010` | NVIDIA block-linear 2D, kind 6, Turing-or-later gob layout, uncompressed, 1 gob high |
| `0x0300000000606011` | the same, 2 gobs high |
| `0x0300000000606012` | the same, 4 gobs high |
| `0x0300000000606013` | the same, 8 gobs high |
| `0x0300000000606014` | the same, 16 gobs high |
| `0x0300000000606015` | the same, 32 gobs high |
| `0x0000000000000000` | `DRM_FORMAT_MOD_LINEAR` |

The six fourccs are `AR24`, `XR24`, `AB24`, `XB24`, `AB30`, and `XB30`. The first four reported the full tiling feature set including colour attachment; `DRM_FORMAT_MOD_LINEAR` reported no colour-attachment bit, which does not matter because lunette imports for sampling and transfer only.

A real client picked a tiled modifier, not the linear one. Alacritty negotiated `AR24` at `0x0300000000606014`, decimal 216172782120099860, which is the 16-gob-high block-linear layout. The modifier plumbing is therefore load-bearing rather than decorative: a compositor that advertised only `DRM_FORMAT_MOD_LINEAR`, or that ignored the modifier on import, would have got this buffer wrong.

### Disjoint dmabufs

None arrived, and structurally none can. `single_plane_modifiers` drops every modifier whose `drmFormatModifierPlaneCount` exceeds one before the list is advertised, and all seven modifiers on this hardware are single-plane for all six fourccs anyway. A single-plane buffer is never disjoint, which `is_disjoint` asserts directly. `DmabufError::Disjoint` was never reached in any run.

This is a filtered result rather than a measured one. It says nothing about what clients would send if multi-plane modifiers were advertised, which is what a YUV video path would require. The recorded gap in [rendering.md](rendering.md) stands unchanged.

### Colour fidelity and premultiplied alpha

The import is colour-exact, and clients send premultiplied alpha.

This was checked because the first census returned a background of `#cc0066` where the client had been told `#ff007f`, a uniform factor of 0.8. Repeating with `#ffffff`, `#808080`, and `#00ff00` returned `#cccccc`, `#666666`, and `#00cc00`: a linear scale by 0.8 in every channel, which rules out a gamma or sRGB misinterpretation, since those are nonlinear. Probing the alpha channel at a single pixel returned `0.8000, 0.8000, 0.8000, 0.8000`. The terminal was configured with `opacity = 0.8`, so the buffer holds exactly what the client wrote, premultiplied.

The consequence is recorded in [rendering.md](rendering.md#alpha) and acted on by the in-scene path now: `etc/xdg/lunette/main.lua` draws with `pass:setBlendMode('alpha', 'premultiplied')`, because LÖVR's default alpha mode multiplies the colour by the alpha a second time and so darkens every translucent client. The composition-layer path inherits the same requirement in phase 3.

### The `wl_shm` fallback

The fallback path works and is exercised by clients that exist. `weston-flower`, which renders through cairo into shared memory, produced a usable 200x200 texture with 105 distinct colours across 2500 samples and no dmabuf import recorded for the run.

## The thread split and the snapshot model

The snapshot model is workable, and the question it actually raises is not the one the design anticipated.

The design's worry was that Lua seeing a snapshot rather than live compositor state would be awkward to write against. It is not. A configuration reads `lunette.windows()`, indexes it, reads `window.width`, calls `window:getTexture()`, and calls `sink:pointer` and `sink:button`, and none of that reads differently from live state. Every measurement harness in this document is written that way. The snapshot is refreshed once at frame start and is immutable for the frame, so a configuration cannot observe a window changing size midway through its own `lovr.draw`, which is a property that removes a class of bug rather than adding one.

Three concrete observations support the model rather than merely tolerating it.

Commands are queued and flushed rather than applied. `lunette.spawn` called from `lovr.load` is flushed at the end of the first frame, which is why `FrameDriver::end_frame` starts the compositor as well as `begin_frame` does: on the first frame there is no graphics device to lend at frame start, but there is by frame end, and without the second call the first frame's spawn would be dropped. This is the one place where the asynchrony is visible, and it is visible as a one-frame latency on the first command rather than as a semantic surprise.

Input round-trips within the model. A Lua `sink:pointer(120, 90)` followed by `sink:button('left', true)` and `sink:button('left', false)` was reported by the child as `button: 272, state: pressed, x: 120, y: 90`. The command travels to the compositor thread, is applied there, and its effect appears in a later snapshot; nothing in the Lua code has to know that.

The texture rotation rule holds under the model. `window:getTexture()` returns the current buffer's texture, and a client cycling three buffers produced exactly three imports over a run of thousands of frames, with each repeat import of a buffer returning the same `ImageHandle` from the cache. The rule that a texture must not be cached across frames is real, and the frame generation on the handle is what makes violating it detectable rather than silently wrong.

The cost the design predicted — that the compositor cannot be interrogated synchronously — did not become an obstacle in a configuration of this size. Whether it becomes one at the scale of the standard library is a phase 6 question, not one this milestone can answer.

## Findings that later phases depend on

These came out of building the slice rather than out of the two unknowns, and each constrains a later phase.

LÖVR requests `apiVersion = VK_MAKE_VERSION(1, 1, 0)` at `gpu_vk.c:3089`. Vulkan 1.1 is therefore the ceiling for anything lunette does on the borrowed device, regardless of what the physical device supports. `ash::Device::load` cannot fail: a missing entry point becomes a stub that panics when called, so a 1.2 or 1.3 function looks present and aborts the process on first use. Any later work that reaches for a newer entry point must go through an extension whose presence is checked, not through a core function of a later version.

`l_lovrEventPush` allocates the `Variant` array with `lovrMalloc` at `l_event.c:171`, and the poll path at `l_event.c:139-145` destroys each `Variant` but never frees the array. Every custom event leaks that allocation. lunette pushes payload-free events and builds the event table at dispatch, which reduces the leak to the minimal allocation `malloc(0)` returns rather than eliminating it. A fix belongs upstream; until then, no lunette path should push a custom event carrying a payload.

Retirement is swept once per compositor dispatch and whenever a surface's content goes away, not only when the next import happens to run. An import-driven sweep alone holds every image of a client that has disconnected or fallen quiet, because neither performs an import, and the count the shutdown path logs would then describe buffers freed minutes earlier.

Imported images are not destroyed at shutdown, by design. LÖVR empties its morgue only in `gpu_destroy`, so an image released after the last frame is held until the graphics module is torn down, and the process exit bounds it. The shutdown path logs the count it is leaving behind. This is correct for a process that exits and would not be correct for a long-lived process that started and stopped the compositor repeatedly, which nothing currently does.

A restart drops the compositor and does not bring it back. `lovr.event.restart` closes the Lua state, closing it destroys LÖVR's graphics module, and that destroys the `VkDevice` the compositor borrowed, so the compositor is stopped before the state closes and its socket goes with it. The soft reload that keeps clients across a reconfiguration is phase 7's, and it works by not discarding the graphics module at all. Phase 7 must not be built on `lovr.event.restart`.

[compositor.md](compositor.md) documented a socket named `lunette-0`. Task 7 implemented WayVR's scheme instead, probing `wayland-20` through `wayland-40` for a free name, and the document was changed to match the code. Whether `lunette-0` was the real intent is an open question. A distinctive name is easier to recognise in `WAYLAND_DISPLAY`; WayVR's range is what existing tooling and habits expect. This was resolved in favour of the code without a decision being taken, and it should be settled deliberately.

## Composition layers

These come out of phase 3, which is past milestone 0 proper. They are recorded here because they are measurements of the same machine and the same runtime, and splitting them into a second document would separate them from the driver description they have to be read against.

Two of the four questions phase 3 set out to answer are unresolved, and the reason is the same for both: no session has yet granted a layer to a real panel. What is recorded below is what the runtime reported, what a scratch configuration did with it, and what the automated tests establish about the pool's decisions. The pool's arithmetic is thoroughly tested against a fake backend and barely exercised against a real one.

### The layer limit, which is not one number

Two Monado configurations reported two limits, and the difference is large enough that neither should be quoted on its own.

| Configuration | `lovrHeadsetGetLayerLimit()` | Budget it yields |
|---|---|---|
| Monado with the simulated HMD, `SIMULATED_ENABLE=1` | 128 | 12 slots, which is `LayerBudget::CEILING` |
| Monado headless with the null compositor, `XRT_COMPOSITOR_NULL=1` | 0 | 0 slots |

128 is `XRT_MAX_LAYERS` on Linux, which is what a Monado carrying a real compositor reports whatever the hardware is. Against it the budget is `limit / SHARE` capped at `CEILING`, so 32 capped to 12.

A scratch configuration created 12 layers, above LÖVR's old ceiling of 10, drew into each through `getPass`, and submitted all 12 for 60 frames. It exited 0 with no OpenXR error, which is what the vendored LÖVR bump was made to establish. That configuration predates the pool and drove LÖVR directly, so it says nothing about the pool's own behaviour.

The null compositor is the more interesting row. A limit of 0 yields a budget of 0 slots, so nothing is granted and nothing is attempted — which is correct, and is the path `nothing_is_granted_before_the_runtime_reports_a_limit` covers. Forcing the limit to 64 in a scratch build to get past that reached `lovrLayerCreate`, which returned NULL on every frame: the null compositor does not implement quad layers at all. The degradation was as designed. No crash, no stall, `claim.granted` stayed false, and the Lua configuration went on drawing its in-scene quad.

That run did expose a defect, now fixed. The refusal was warned about on every frame of every retry, which is thousands of identical lines a second and buries everything else in the log. It is now reported once per claim, and again after a session is lost and rebuilt, which is the treatment `BlitLedger` already gave the unsupported-device warning.

### Free-list hit rate and the size ladder

Unresolved, and honestly so. Every free-list measurement available is against `FakeLayers`, where a hit is asserted by the test that arranged it. `a_revoked_layer_is_reused_by_the_next_claim_of_the_same_key_with_no_allocation` and `two_sizes_the_ladder_rounds_together_share_one_layer` establish that the mechanism works; neither is a rate, because the claims in a test are the ones the test made.

A rate needs a session with panels being promoted and demoted as a person looks around, which needs the sharpness gate under [outstanding](#the-sharpness-gate) to have happened first. The ladder's steps are in the same position: whether the rungs are the right ones is a question about what sizes real panels ask for, and the only real sizes seen so far are one terminal at 800x600, which the ladder rounds to 1024x1024.

### Format conversion, which is the ordinary case rather than the exception

Conversion is needed on every copy, and the device supports it.

A layer's swapchain image is `FORMAT_RGBA8` with sRGB. A client's window is `FORMAT_BGRA8` without, because `Argb8888` and `Xrgb8888` both map to `FORMAT_BGRA8`, and phase 2 recorded Alacritty negotiating `AR24` — which is `Argb8888`. So the two formats differ in both channel order and colour space on the only real client observed, `lovrTextureCopy` degrades to `lovrTextureBlit`, and the blit path is the normal path rather than a fallback.

`GPU_FEATURE_BLIT` is present. `vkGetPhysicalDeviceFormatProperties` was read directly on this machine for the four formats the copy can involve, and every one of them carries `BLIT_SRC` and `BLIT_DST` in `optimalTilingFeatures` on all three physical devices the loader offers.

| Format | NVIDIA GB202 | RADV Raphael | llvmpipe |
|---|---|---|---|
| `B8G8R8A8_UNORM` | blit source and destination | the same | the same |
| `B8G8R8A8_SRGB` | the same | the same | the same |
| `R8G8B8A8_UNORM` | the same | the same | the same |
| `R8G8B8A8_SRGB` | the same | the same | the same |

That is a Vulkan-level answer rather than a LÖVR-level one. LÖVR derives `GPU_FEATURE_BLIT` from the same `optimalTilingFeatures` bits, so the two should agree, but `lovrGraphicsGetFormatSupport` was not read against a live layer because no live layer has existed. `Blitted::Unsupported` has therefore never been observed outside a test, and the fallback it drives is unexercised on real hardware.

### The creation cap and stalls

Neither has been observed, and neither has been ruled out.

`CREATIONS_PER_FRAME` is 1, and `at_most_one_layer_is_created_a_frame` establishes that the pool honours it. Whether it binds in practice is a question about how many panels appear at once, and no session has created a layer through the pool at all. The same is true of a stall: `lovrLayerCreate` ends in `xrWaitSwapchainImage` with `XR_INFINITE_DURATION` inside a retry loop with no escape, which is why the cap exists, but nothing has yet timed a real call. Under the null compositor the call returned NULL immediately rather than blocking, which is the opposite of the case the cap guards against.

### The margin around a source smaller than its layer

The size ladder quantises upwards, so an 800x600 window is served by a 1024x1024 layer. The blit copies the source into that image and writes nothing else, so the margin holds whatever that swapchain image last had — which for an image nothing has written is uninitialised Vulkan memory. `lovrLayerCreate` sets `subImage.imageRect` to the whole image (`headset.c:3148`), so without a viewport the runtime composites the margin too, and a clear at creation would not answer it either: a swapchain holds up to `MAX_IMAGES` images and each frame acquires a different one.

The blit clears the destination before a copy that does not cover it, so what composites is transparent black. The clear costs a full-image clear on each frame that copies into an oversized layer, and only such a copy pays it.

That is a safety floor rather than the layout answer. `claim.width` and `claim.height` report the layer's dimensions, and [lua-api.md](lua-api.md) documents them as the numbers a caller needs for `layer:setViewport`. Nothing enforces the call. The pool deliberately does not set the viewport itself: it is one of the per-panel properties that let a layer of a given key serve any panel wanting that key, so setting it from underneath Lua would remove the mechanism a panel needs to place a source inside a larger layer. Phase 6 writes mullion's panel and owns that, and it is recorded in [phase 6](implementation-plans/2026-08-05-lunette-v1/phase_06.md) as a fact the panel is built against.

### A recycled layer is not granted until it has been copied into

A layer coming off the free list still holds the pixels the previous claim put there. It is therefore handed to the new claim awaiting its first blit, exactly as a newly created one is, and neither granted nor submitted until that claim's own copy has been issued.

Granting on reuse would be a frame cheaper and would put one window's content inside another window's panel whenever the new claim has nothing to copy — a window that has not committed a buffer yet, a window whose client has just died, or a device that cannot blit the format. The reuse itself is untouched: no allocation happens either way, which is what AC2.4 is about.

## Monitor mirroring and host input

These come out of phase 4. Every acceptance criterion the phase carries is a human gate, and none of them has been performed: the machine this was checked on runs at a bare TTY, with `XDG_SESSION_TYPE=tty` and neither `DISPLAY` nor `WAYLAND_DISPLAY` set. There is no compositor to capture, no display to point at, and no session to grant a portal request. What is recorded below is what could be established without one, and what could not is under [Outstanding](#the-five-monitor-mirroring-gates).

### The portal on this machine

The portal is reachable on the session bus without a graphical session, and it is the version this phase requires. `org.freedesktop.portal.Desktop` answers on `/org/freedesktop/portal/desktop`, `org.freedesktop.portal.ScreenCast` reports `version = 5`, `AvailableSourceTypes = 7`, and `AvailableCursorModes = 7`.

The backends registered on the bus decide which path a real grant would take.

| Backend | State |
|---|---|
| `org.freedesktop.impl.portal.desktop.gnome` | running |
| `org.freedesktop.impl.portal.desktop.gtk` | running |
| `org.freedesktop.impl.portal.desktop.wlr` | activatable |

So a grant on this machine exercises the GNOME path. That is the backend under which `mapping_id` is mutter's `g_uuid_string_random()`, and only when the ScreenCast session is attached to a RemoteDesktop session, which lunette's is not. The expected result there is no `mapping_id` at all, and a UUID rather than a connector name if one did appear. `ConnectorName::parse` rejects both, which `a_uuid_shaped_mapping_id_is_not_a_connector_name` and `a_uuid_whose_last_group_is_all_digits_is_not_a_connector_name` cover. The reasoning is in [decisions.md](decisions.md).

### What the pinned wlx-capture drops

Two fields of the portal's response never reach lunette, and both were confirmed against the pinned source at `98f800c6` rather than against the published crate.

`persist_mode` appears once in `wlx-capture/src/pipewire/mod.rs`, at line 512, where the request states it. `parse_start_response` (`mod.rs:686-691`) reads `streams` and `restore_token` and nothing else, so the granted mode is discarded before lunette can see it. Every real grant therefore records `GrantedPersistMode::Unstated`, and the store holds no mode. The consequence is diagnostic rather than functional — the restore token is stored either way — but it means the store cannot report what the backend actually granted, and a backend that downgrades the mode does so invisibly.

`mapping_id` appears nowhere in that file at all. `parse_streams` (`mod.rs:693-733`) reads `node_id`, `position`, and `size`. `PortalStream::connector` is therefore always `None` on every backend, including wlroots where the field would have carried a real connector name. This does not cost anything, because the connector name comes from `wl_output.name` instead: version 4 of `wl_output` added a `name` event whose documented content is the connector name, both wlroots and mutter send it, and it arrives from the compositor lunette is already talking to. Both gaps are recorded in [decisions.md](decisions.md).

### What is established without a session

`crates/lunette/tests/host_outputs.rs` runs the real enumeration against lunette's own compositor over a socket pair, with a fake buffer importer, no graphics device, and no listening socket. It establishes that make and model arrive from `wl_output.geometry`, that the mode reaches `Monitor::pixels` unchanged at three different sizes, that the transform survives the trip rather than being defaulted at the far end, that the logical size is derived from the mode and the scale when no `zxdg_output_manager_v1` is advertised, and that an output whose name is not a DRM connector type is identified by its descriptor instead.

Each of those six tests enumerates a fresh compositor. None of them changes anything under a live watcher, which is the limit described below.

The mirror lifecycle is covered against a fake portal in `crates/lunette-capture/src/mirror/tests.rs`: one request however many monitors are wanted, dismissal stopping the stream while keeping the session, re-adding restarting without a second request, a stored token offered with the first request, and a declined dialog reported rather than leaving the monitor waiting. Those are the decisions AC3.4 and AC3.5 rest on, and they are tested against a fake because the real portal needs a session to grant anything.

### Gaps this phase leaves

The hotplug path is untested end to end. A monitor appearing and a monitor detaching are covered against fakes in `mirror/tests.rs`, and the roster's accumulator is unit-tested over the same events, but nothing exercises a real compositor advertising or withdrawing a `wl_output`, or changing a mode, while a watcher is live. Every end-to-end test enumerates once against a compositor whose configuration was fixed before it started.

A rotated monitor is unresolved in two directions. `monitor.width` and `monitor.height` report the panel's mode, which for a rotated output is not the shape the desktop presents. Whether a capture stream of a rotated output delivers frames in the panel's orientation or the desktop's is unverified on any backend, and the two answers imply different code.

`wl_virtual` is deliberately left unconfigured, so the provider chain reports it as not configured and falls through to uinput. A `zwp_virtual_keyboard_v1` needs a keymap before its first keystroke, and building one is phase 5's work. This is a chosen order rather than a defect, and the chain is honest about it.

`UNITS_PER_DETENT` is 10.0 in `hid/wl_virtual.rs`, carried from WayVR, whose own comment on the value is "no clue". Nothing has measured what a host compositor does with it.

uinput has never issued `UI_DEV_CREATE` to a kernel. The device setup, the axis setup, and the teardown are written and unit-tested over a recording fake, and no test has opened `/dev/uinput`.

## Outstanding

Ten items are unfinished: eight human gates, and two measurements that have to be taken.

### The two human gates

Neither gate has been performed. Both are in [phase 2](implementation-plans/2026-08-05-lunette-v1/phase_02.md) as acceptance criteria, and neither is automatable.

The first gate is that a terminal spawned by lunette appears on a quad in the desktop simulator and responds to a click. Its constituent parts have each been observed: the terminal appears in `lunette.windows()` at 800x600 with a matching texture, it is drawn on a quad and screenshotted from the simulator, and a Lua-issued click is reported by the child at the right coordinates. What has not happened is a person looking at the quad and clicking it. The parts passing separately is not the gate.

The second gate is that the same build runs as an overlay under Monado alongside another OpenXR application, compositing over it with undrawn areas transparent. Nothing in this document bears on it. It requires a running Monado, a second OpenXR application, and a person to judge the compositing.

Both gates should be performed before phase 3 begins, because phase 3 is the composition-layer work and it is detailed against the assumption that the overlay session behaves as designed.

### The sharpness gate

Not performed. It is phase 3's `lunette-v1.AC2.2`: a text-heavy terminal is visibly sharper rendered on a composition layer than the same terminal rendered in-scene. Nobody has looked, and no part of it has been observed indirectly either — unlike the two gates above, whose constituent parts have each been seen separately. No session has granted a layer to a panel at all, which is why the two unresolved questions under [composition layers](#composition-layers) are unresolved.

It has to be checked under Monado in service mode. Overlay sessions do not work in monolithic mode: `multi_compositor_create` never initialises `z_order` from the session create-info, and only the IPC server calls `set_z_order`.

Performing it also answers, or begins to answer, three things this document currently records as open: the free-list hit rate, whether the ladder's rungs are the right ones, and whether `lovrLayerCreate` stalls.

### The five monitor-mirroring gates

None of the five has been performed, and none of them can be performed on the machine this document records. It runs at a bare TTY, so there is no compositor to capture, no display to point at, and no session to grant a portal request. They are phase 4's acceptance criteria, all five of them human gates.

- A mirrored monitor appears with a texture matching the captured output's resolution (AC3.1). The enumeration half is established by `tests/host_outputs.rs`; what has not happened is a frame arriving from a real stream and a person seeing it at the right size.
- Pointing at a mirrored monitor moves the host cursor to the corresponding position on that physical display (AC3.2). It has to be checked on a scaled display and on a monitor at a non-zero origin, which are the two cases the mapping arithmetic gets wrong if it is wrong at all.
- Keystrokes reach whatever the host focuses (AC3.3). Hardware is not the only thing missing: there is no Lua path to a key at all. `Sink` exposes `pointer` and `button`, and nothing calls `send_key`, `set_modifiers`, or `set_keymap`, so the provider chain's keyboard half is built and unreachable. The criterion is deferred to phase 5, which owns `sink:key` and keymap construction, and which is also what `wl_virtual` is waiting on — it is deliberately left unconfigured until there is a keymap to upload, because a virtual keyboard is disconnected by its first keystroke without one. uinput is the provider this would use, and it has never issued `UI_DEV_CREATE` to a kernel either.
- Monitors are selected once, in one dialog, in any order, and reattach correctly after a restart (AC3.4). The second run is the half that matters: whether the stored restore token avoided a second prompt is unanswered, and it is unanswerable without a first grant.
- Dismissing a mirror stops its stream, and re-adding it restarts capture without re-prompting (AC3.5). The decisions are tested against a fake portal; the stream actually stopping is not.

The four questions [phase 4](implementation-plans/2026-08-05-lunette-v1/phase_04.md) asks to be recorded are the same four, restated: which portal backend was tested and what it put in `mapping_id`, whether restore avoided a prompt on the second run, whether the uinput mapping was correct on a scaled or rotated display, and the GNOME result. All four are open. What is known about the backend without a grant is under [the portal on this machine](#the-portal-on-this-machine).

### The GNOME pointer-mapping unknown

Unmeasured, and it decides whether AC3.2 is achievable on GNOME at all. It is not known whether mutter maps a bare absolute uinput device across the whole layout or binds it to a single monitor. If it maps across the layout, the phase's arithmetic is what it needs. If it binds to one monitor, no arrangement of absolute coordinates reaches the others, and the honest answer on GNOME is libei through `org.freedesktop.portal.RemoteDesktop`, which v1 does not implement — so the limitation would be recorded rather than worked around.

This machine registers the GNOME backend and runs no GNOME session, so it can name the path that would be exercised and measure nothing about it.

### The two `undefined` rows of the queue-family measurement

The two `undefined` rows under [the queue family for the acquire](#the-queue-family-for-the-acquire) are annotated as invalid rather than replaced, and re-running them is a task rather than a condition attached to citing them. It needs the census harness, a real GPU, and a client, which is why it was not done when the release barrier was fixed. Until it is done, the `undefined` half of the queue-family question and the `undefined` half of [the transition out of an undefined layout](#the-transition-out-of-an-undefined-layout) are unmeasured, not merely uncertain. The default rests on the `general` rows, which are unaffected, so nothing is blocked on this; it is recorded here so the hole stays visible.
