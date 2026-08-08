# Milestone 0 findings

Milestone 0 exists to de-risk two unknowns before a standard library is written on top of them: the LÖVR Vulkan patch, and the compositor-thread split with the snapshot model it forces on Lua. [Roadmap](roadmap.md) states both. This document records what the two actually did, so phases 4 to 8 are detailed against measurement rather than against the design's expectations.

Twenty-one acceptance criteria are human gates and are not recorded here as passed: two from milestone 0, one from the composition-layer work that follows it, five from the monitor-mirroring work after that, five from the keyboard, seat, and clipboard work after that, four from the standard library after that, and four from the reload, `lunctl`, and error-handling work after that. They are listed under [Outstanding](#outstanding), together with the four measurements that have to be taken.

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
| `cargo test --workspace` | 1136 passed, 0 failed, 0 ignored |
| `cargo test --workspace --no-default-features` | 1136 passed, 0 failed, 0 ignored |

The 1136 are 522 in `lunette`, 17 in the `lunctl` binary target, 27 in the `lunette` binary target, 3 in `tests/default_configuration.rs`, 3 in `tests/exit_status.rs`, 6 in `tests/host_outputs.rs`, 9 in `tests/lunctl.rs`, 1 in `tests/mullion_spec.rs`, 3 in `tests/reload.rs`, 3 in `tests/safe_mode.rs`, 4 in `tests/standard_library.rs`, 239 in `lunette-capture`, 189 in `lunette-compositor`, 6 in `tests/client_lifecycle.rs`, 20 in `tests/clipboard.rs`, 5 in `tests/content_type.rs`, 8 in `tests/fractional_scale.rs`, 8 in `tests/frame_pacing.rs`, 17 in `tests/outputs.rs`, 8 in `tests/pointer_routing.rs`, 7 in `tests/restart.rs`, 14 in `tests/seats.rs`, 6 in `tests/surface_routing.rs`, and 11 in `tests/type_text.rs`. The compositor's 299 run with no graphics device and no XR runtime, which is the separation [CONTRIBUTING.md](../CONTRIBUTING.md) requires of `lunette-compositor`, and they are re-run with no Vulkan ICD visible at the end of each phase to keep it that way. The count is the whole workspace as it stands, so it grew past milestone 0: everything under `layers::` and `lua::tests::layers` is 74 of it, of which the composition-layer work under [composition layers](#composition-layers) is the 61 that phase added — later phases put tests in the same modules, so the module total and the phase's contribution are no longer the same number. The monitor-mirroring work under [monitor mirroring and host input](#monitor-mirroring-and-host-input) is the 239 in `lunette-capture` plus the 6 in `tests/host_outputs.rs`, the keyboard, seat, and clipboard work under [keyboard, seats, and clipboard](#keyboard-seats-and-clipboard) is 157 of it, the standard library under [the mullion standard library](#the-mullion-standard-library) is the 69 the workspace grew by after that, the reload, `lunctl`, and error-handling work is the 164 after that, and the outputs, scale, and pacing work under [outputs, scale, and pacing](#outputs-scale-and-pacing) is the 115 after that. The remaining 8 are the review fixes that followed it: `lunette.restart()`, the layer pool observing a lost session, and the pool telling a session from the one that replaced it. The single test in `tests/mullion_spec.rs` runs the Lua cases, which are not counted in the 1136.

Two test binaries print xkbcommon compilation errors to stderr and still pass. The errors come from the negative cases — a keymap string that is not a keymap, and a layout name no `xkeyboard-config` carries — which are `a_layout_that_does_not_exist_is_refused_rather_than_silently_defaulted` and `text_that_is_not_a_keymap_is_refused` in `keymap.rs`, and the refused-layout case again in `tests/seats.rs`. libxkbcommon writes to stderr through its own log handler before returning the failure lunette then asserts on, and suppressing it would mean installing a process-global handler for the benefit of three tests.

No dependency in the tree names `async-std` or `ashpd`: `cargo tree | rg -c 'async-std|ashpd'` counts zero. Both would arrive with the published wlx-capture 0.5.4, and the pin is the 0.6.0 in the WayVR monorepo at `98f800c6` for that reason.

## Provenance

Every file in `crates/lunette-compositor/src/` either carries the WayVR header or is lunette's own. The check is `rg --files-without-match 'Ported from WayVR' crates/lunette-compositor/src/`, compared against the list of original files in [crates/lunette-compositor/PROVENANCE.md](../crates/lunette-compositor/PROVENANCE.md). Twenty-six files are headerless and all twenty-six are on that list.

The list went stale once, between the file-size sweep that split six oversized files and the phases that followed it, and the check named eleven files the list did not. `PROVENANCE.md` now records a verdict per file for the three method groups carved out of the header-carrying `state/compositor.rs`: `state/processes.rs` took `accept_connection` and `cleanup_clients` with it and carries the header, and `state/outputs.rs` and `state/pacing.rs` do not, because virtual monitors and frame pacing have no upstream counterpart. `CompositorState::millis` is the one thing in the latter that does, and it is a contrast rather than a port — WayVR reads a wall clock, lunette an `Instant`, and Wayland's timestamps must be monotonic.

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

## Keyboard, seats, and clipboard

These come out of phase 5. As with phase 4, every acceptance criterion the phase carries is a human gate and none has been performed, for the same reason: the machine runs at a bare TTY, with `XDG_SESSION_TYPE=tty` and neither `DISPLAY` nor `WAYLAND_DISPLAY` set. There is no host compositor to bridge a clipboard with and no headset to put two hands in. What is recorded below is what could be established without either, and what could not is under [Outstanding](#the-five-keyboard-seat-and-clipboard-gates).

The phase added 157 tests, and the compositor crate now carries 210 of the workspace's 780. All 210 pass with no Vulkan ICD visible, which is the check the crate boundary rests on: `cargo tree -p lunette-compositor` names no GPU crate, and the only entry in it that reads as one is `drm-fourcc`, which is a table of format codes and links nothing.

### Multi-seat

One `wl_seat` per hand, held in a `SeatRegistry`, with the pointer position, the hovered window, the keyboard focus, the modifier state, the cursor image, and the selection all per seat. The cursor image is the one WayVR got wrong under multi-seat — its `SeatHandler::cursor_image` ignores the `seat` argument and writes one field on the application — and it now lives in `Seat::user_data()`, which is where smithay keeps everything else that is per-seat. The `SerialCounter` moved the other way, out of the per-seat struct and onto the compositor state, because serials are global in smithay and duplicating them would have been the bug.

`tests/seats.rs` establishes the independence directly: a key sent to an unfocused seat reaches nobody, and a button is refused on a seat whose pointer is somewhere else. What has not happened is two hands in a headset, which is AC4.1.

### The reverse keymap lookup, which libxkbcommon does not offer

There is no libxkbcommon call for "which key and modifiers produce this keysym". The forward direction is `xkb_state_key_get_syms`, and the reverse is left to the caller.

`keymap.rs` builds the table once, when the keymap is compiled, by enumerating the modifier combinations that select a shift level, walking every keycode under each, and inverting the result. `LEVEL_MODIFIERS` is six combinations: nothing, shift, `Mod5`, shift with `Mod5`, `Mod3`, and shift with `Mod3`. Control, alt, and the logo key are absent because they do not select a level in any ordinary layout — they are what a client turns into a binding, and a binding is not a character. `NumLock` is absent because it would make the keypad's digits compete with the number row for the same keysyms, and the number row is what a caller asking for a digit means.

The combination loop is outermost, so the first entry written for a keysym is the cheapest way to type it. That is what makes an unshifted letter never report as needing shift, and a digit resolve to the number row.

### Typing text the layout cannot express

`typeText` is planned as a pure function from text and a keymap to a list of chunks, and executed by the seat. A chunk is one temporary keymap's worth: text needing more keysyms than one synthetic layout holds is split into runs that fit rather than refused, so a paragraph of emoji arrives as several keymap changes, which is legal.

Text the active layout can already type takes the ordinary path and uploads nothing. A `wl_keyboard.keymap` event makes every toolkit recompile a layout, and doing that to type `ls` would be absurd.

The second clause of AC4.3 — that the client's own keymap handling works afterwards — is verified directly rather than by inspection. `text_the_layout_cannot_express_arrives_and_the_keymap_is_restored` compares the keymap the client holds after typing against the one it held before, and `a_client_can_still_type_normally_after_text_was_entered_for_it` types under the restored layout. The restore runs even when a chunk fails, because a client left holding a synthetic layout has a keyboard on which every key types the wrong thing.

AC3.3, deferred out of phase 4, now has a Lua path. `sink:key` sets the keymap and then sends, which is what a `zwp_virtual_keyboard_v1` needs: a virtual keyboard is disconnected by its first key if no keymap preceded it. What remains of AC3.3 is hardware, and it is recorded as such under [the five monitor-mirroring gates](#the-five-monitor-mirroring-gates).

### Routing to popups and subsurfaces

`hit_test.rs` ports across without its two couplings. The `Arc<ImageView>` on `RenderedSurface` was read only for a size, so the size arrives as a value and the image stays with whoever draws it — which is what keeps this crate free of a graphics dependency. `PointerHit`, the UV transform, and the panel layer go entirely, because Lua performs the ray intersection and hands down pixel coordinates. All three `Rc<[…]>` sites became `Arc<[…]>`, because the hit-test result crosses to the compositor thread, and two upstream `unwrap` calls were dropped rather than carried.

AC4.4 is verified end to end by `a_click_over_a_popup_is_delivered_to_the_popup_in_surface_local_coordinates`: a real `wayland-client` opens a popup at `(100, 80)`, a click lands at `(110, 100)`, and the popup's own surface receives it at `(10, 20)`. The neighbouring cases are covered too — a click beside a popup still reaches the window, a click over a subsurface arrives in the subsurface's coordinates, and moving from the window onto a popup leaves one and enters the other.

### The clipboard bridge

All four selection protocols are served to lunette's own clients: `wl_data_device`, `zwp_primary_selection_v1`, `zwlr_data_control_v1`, and `ext_data_control_v1`. The bridge to the host runs over data control in the client direction, `ext_data_control_v1` preferred and `zwlr_data_control_v1` as the fallback, through one designated bridge seat.

lunette never reads or writes a selection pipe. Both directions are descriptor passing: a lunette client's read descriptor is handed to the host's offer, and a host read of lunette's selection is a descriptor handed to the lunette client that owns the data. So neither the compositor thread nor the frame thread can block on a peer that opened a pipe and did not write to it, which is the failure mode a copying bridge has.

A host without either data-control protocol is a warning rather than a failure: `HostStartError::NoDataControl` is logged as "the host clipboard will not be bridged this session" and the session continues. Which hosts take that path is unverified, and the two expectations recorded during the phase disagree with what is known of the implementations, so the disagreement is left standing rather than settled from memory. mutter has no data-control implementation, so GNOME is expected to warn and bridge nothing. KWin has carried `zwlr_data_control_v1` for several releases, which would make KDE bridge rather than warn. A gate on each is what decides it, and either way a clipboard that does not cross is a limitation to report rather than a defect to chase.

MIME matching is strict, with no substitution. A lunette client asking for `text/plain` when the host offers only `text/plain;charset=utf-8` gets an empty paste. That is deliberate — silently substituting one type for another is the kind of guess that corrupts a paste of something that is not text — but it is the rule most likely to look like a bug on a real desktop, and it is worth watching for once a gate is performed.

### Gaps this phase leaves

`selection/data_control.rs` is the only file in the crate that talks to a real host compositor, and it has never been run against one. Everything else in the phase is exercised by a real `wayland-client` against lunette's own compositor over a socket pair; this file's peer is a host that has not existed on this machine.

The echo suppression assumes an ordering the specification does not state. Publishing a selection to the host makes the host announce that selection back, because a data-control device sees every selection including its own, so a `selection` event arriving while lunette owns a live source for that kind is discarded. That is safe only if the host cancels a source before announcing the one replacing it. smithay's `set_clipboard_selection` does, and wlroots does, both established by reading the source rather than by observing a running compositor. A host that delivered `selection` before `cancelled` would make lunette miss one selection change.

wlr primary selection is gated at `zwlr_data_control_v1` version 2, which is the version that gained it. A version 1 host bridges the clipboard and not the primary selection, and says so at debug level.

`Command::CreateSeat` boxes its `keyboard` field. `KeyboardConfig` pushed `Command` past clippy's `result_large_err` threshold, and the box is the fix rather than an `allow`.

## The mullion standard library

This comes out of phase 6, which is Lua rather than Rust: `mullion` is policy written against the same public `lunette` API a user's configuration has, and one native task supports it. As with phases 4 and 5, every acceptance criterion the phase carries is a human gate and none has been performed, for the same reason: the machine runs at a bare TTY with `XDG_SESSION_TYPE=tty` and neither `DISPLAY` nor `WAYLAND_DISPLAY` set, so there is no headset to place a panel in and no hand to grab one with. What could be established without one is below, and what could not is under [Outstanding](#the-four-standard-library-gates).

The phase added 69 Rust tests and 314 Lua spec cases. The Lua cases run inside the real binary, driven by the single test in `crates/lunette/tests/mullion_spec.rs`, with the audio, graphics, and headset modules switched off and no window opened. That is deliberate rather than convenient: the tree the specs are required through is LÖVR's virtual filesystem rather than the process's, so a standalone interpreter would resolve a different set of paths than a session does, and the devshell ships no LuaJIT to be that interpreter anyway.

### What the specs establish, and what they cannot

The pure halves are covered thoroughly and the impure halves are covered through a seam. `mullion.interaction` decides what a pointer does and reads no device; `mullion.laser` is the shell that reads `lovr.headset`, owns the seat, and draws the beam, and it takes its input through `options.readInput` so a spec can drive a pointer through a grab with no headset in the room. The same split runs through the tier: `mullion.panel.raycast` is arithmetic over a matrix, `mullion.persist.format` is the file's text and its versions, and `mullion.layout.arc` is angles. None of those needs a fake at all.

What no spec reaches is `laser.headsetInput`, which is `lovr.headset` and nothing else, and the drawing. A pass is faked and the number of planes and lines it was asked for is counted, which establishes that a draw happened and nothing about what it looked like.

Three checks in the suite are about the suite rather than about a module. `mullion.coverage` reads the module tree from the mount and fails when a module has no spec and no recorded exemption, so an absence is deliberate rather than accidental; `mullion/init.lua` is the one exemption, because it holds no state and returns an empty table. `mullion.reload` requires every module twice against one registry and asserts that no teardown hook, and no global, accumulates — CONTRIBUTING.md makes that a defect class, and this is what makes it checkable. `spec.runner` covers discovery itself, which is the one failure in the tree no other spec can catch: a discovery that missed a directory would report every case it did find as passing and say nothing about the ones it never loaded.

### The standard library uses only the public API

The check is a grep against `docs/lua-api.md`. `mullion` reaches for `lunette.claimLayer` and `lunette.newSeat` and nothing else on the root, and for `claim.granted`, `claim.width`, `claim.height`, `claim.layer`, `claim:release`, `seat:setFocus`, `seat:strokeFor`, `seat:symbolFor`, `seat:characterFor`, `seat:destroy`, `seat.dead`, `sink:pointer`, `sink:button`, `sink:leave`, `sink:scroll`, `sink:key`, `sink:modifiers`, `sink:typeText`, `win:getTexture`, `win:getProperty`, `win:setProperty`, `win.width`, `win.height`, `win.opaque`, `win.title`, `win.appId`, `win.id`, `win.dead`, `win.sink`, `monitor.name`, and `monitor:mirror`. Every one of those is documented. No private path was used and none was wanted.

### The file-size check

One module exceeded the threshold and was split. `mullion.panel` reached 587 lines, and the seam was the one its specs already used: the ray-quad intersection is arithmetic over a matrix and reaches for nothing but `lovr.math`, while the rest is claims, layers, sources, and draw calls. It moved to `mullion.panel.raycast`, re-exported as `panel.rayQuadHit`, which is the name the documents give it, and a spec asserts the re-export so a later split cannot drop it silently. What is left is 511 lines, which is over the threshold by a rounding error and is one cohesive concern; splitting it further would be splitting at a line count rather than at a seam.

`mullion.interaction` is the other module over, at 512, and the answer is the same one: what a pointer picks, what it scrolls, and what it has grabbed are one concern, and the seam that exists in it — the arithmetic — is already `mullion.panel.raycast`. Every other module is under, the largest being `mullion.keyboard` at 458.

The largest spec file is `spec/mullion/panel/panel_spec.lua` at 520, which is the same rounding error again. `spec/mullion/persist` did pass the threshold and was split, along the seam `mullion.persist` itself has: `arrangement_spec.lua` is capture, restore, and the rules source, `file_spec.lua` is the path, the load, and the save, and the fakes they share are `spec/mullion/persist/fixture.lua`. The coverage table takes an array where a module's specs were split, so a module covered by two is still a module named once.

### The API gaps the standard library ran into

Four, each recorded by the task that hit it, and none worked around.

There is no per-monitor property store, and the sharp form of that is not "monitors have nowhere to write" but that the two source kinds have different reload semantics. A window's pose lives in the native store and survives a soft reload; a monitor panel's pose can only go in `mullion.persist`, which is a restart mechanism written to disk. No amount of Lua closes that, and until `lunette` grows a per-monitor store a hand-placed mirrored screen is remembered on a coarser lifetime than a hand-placed window.

`lunette.claimLayer` takes `window` and nothing else, so a monitor panel never gets a composition layer. That is the exact case native-resolution compositing exists for: a mirrored 4K screen resampled into lunette's own render target is what a layer would avoid.

Per-callback errors reached nothing but the log. `crates/lunette/src/events.rs` reported a `lun*` handler's error with Rust's `error!` and dropped it, while `docs/lua-api.md` promised that path logs, emits `lovr.lunerror`, and rate-limits. Closed under [reload, `lunctl`, and error handling](#reload-lunctl-and-error-handling).

Native handles are not identity-stable. Every read produces a fresh userdata, so two reads of the same window are two different Lua values, and identity is `win.id` rather than the handle. `docs/lua-api.md` says handles have "stable identity", which is true of the window and not of the value. `mullion.signal` holds its registry weakly and keys on the caller's own object for that reason, and the callers key by `win.id` where they have to.

Two smaller documentation gaps stand with them: `lunette.windows()` is used throughout the documents and has no entry in the Handles section of `docs/lua-api.md`, and the type of `win.id` is unstated.

### One policy call made rather than specified

`rules.place` creates a tag a rule names when nothing declared it, rather than refusing. The argument for it is that a rule saying "this application lives on 'web'" is describing a workspace, and losing the window over a declaration order would be worse. The argument against is that a misspelt tag name then silently produces a workspace nobody meant, which is the failure a strict version would have named. It is flagged for review rather than settled.

### Gaps this phase leaves

The shipped configuration is exercised as text, not as a session. `crates/lunette/tests/default_configuration.rs` compiles `etc/xdg/lunette/main.lua` and `conf.lua` under the LuaJIT the session runs them on and checks the chunk defines the callbacks the session calls, against a `require` and a `lovr` that answer with empty tables. Nothing runs its `lovr.load`, so what it does is entirely the human gates below.

Safe mode had never been triggered. Its chunk was run against a fake `lunette` on a state whose search path is empty, which establishes that it requires `lunette` and nothing else, that a frame runs with no headset and no graphics module, and that a hand aimed at its panel clicks it. What had not happened was a `main.lua` failing to load and safe mode appearing. Closed under [reload, `lunctl`, and error handling](#reload-lunctl-and-error-handling), except for the headset half, which is a gate.

`lunette.reload` did not exist, so the reload key in both configurations reported that it was not implemented. Closed by phase 7's first subcomponent; both call sites now call it.

Feel is untuned. Every constant that decides how interaction feels — the grab dead zone, the reach, the scroll scale, the haptic strength, the arc's radius and step — is a named value in one table per module, and every one of them is a first guess. `docs/stdlib.md` says this tier is tuning-heavy and that feel accounts for most of the work, and none of that work has been done.

## Reload, `lunctl`, and error handling

### What is established without a headset

Three things this phase built are exercised against the shipped binaries rather than against fakes, and each is worth naming because each was previously a promise the build did not keep.

An error raised in a `lovr.lun*` handler reaches `mullion.error`. `crates/lunette/src/callback_error.rs` splits mlua's joined message and traceback, finds the module in `package.loaded`, and calls `errors.handle`; a session with no standard library gets the log and a direct `lovr.lunerror` instead. The rate limiting is established by raising the same error through the production dispatcher for two hundred frames and counting one report, which is the shape of the failure the limiter exists for rather than a rehearsal of it.

Safe mode fires. `crates/lunette/tests/safe_mode.rs` hands the real binary a `main.lua` that does not compile, and a configuration directory with no `main.lua` at all, and asserts through the control socket that the resulting session has safe mode's callbacks installed, that the broken configuration's own callbacks are gone, and that the session evaluates a chunk and quits when told to. A third case points the standard-library mount at a directory that does not exist and gets the same result, which is the case safe mode was written for.

The check suite passes at 1013 Rust tests and 353 Lua spec cases.

### What a headless machine cannot reach

Two things this phase built have no headless coverage at all, and both are recorded under [Outstanding](#outstanding) rather than glossed.

The restart path has never destroyed a real device. The quiesce is covered against a real compositor thread and the re-import against a fake importer, so what is established is the protocol and not the ordering it exists to protect. The instrument for the numbers phase 7 asks for is in place — `Quiesced { took, discarded }` is logged — and the numbers are unmeasured.

No end-to-end test spawns a client. A headless fixture switches the graphics module off, the compositor thread starts only once there is a device to lend it, and so nothing can connect to the socket the session bound. That is why the end-to-end tests are the frame loop with no client, and the compositor crate's tests are a client with no frame loop.

## Outputs, scale, and pacing

### What is established without a headset

The whole of this phase's mechanism is exercised over the socketpair harness or over a real Lua state, and none of it needs a device. Per-client output filtering is checked by binding a real client and reading its registry; the fractional-scale preference, the `wl_output.scale` that accompanies it, and the toplevel configure are checked as the events a client receives; frame-callback throttling runs against a fake clock, so a surface at 10 Hz is checked by advancing time rather than by waiting for it.

The check suite passes at 1125 Rust tests, and the mullion spec suite passes as one `cargo test` case.

### Skipping the projection layer, and the flush nobody would have noticed

`setLayers{ main = false }` saves almost nothing on its own: it leaves the `XrCompositionLayerProjection` out of `XrFrameEndInfo::layers` (`headset.c:3055`), by which point the pass has been rendered and resolved. The colour swapchain is acquired lazily inside `lovrHeadsetGetTexture` and `lovrHeadsetGetPass` (`:2844`, `:2869`), so the saving is in not calling those — which is why lunette gates the two functions rather than the flag.

That gating uncovered something the plan did not anticipate. `boot.lua:218` reads `if headset or window then lovr.graphics.submit(headset, window) end`, and `lovrGraphicsSubmit` is the only thing that submits `state.stream` — `lovrGraphicsPresent` does not touch it. The frame's layer copies are recorded into that stream. So a frame with no desktop window open and no headset pass would leave every copy unsubmitted while `lovr.headset.submit` went on releasing each layer's swapchain image, and the runtime would composite from an image whose copy was still queued. lunette therefore submits the stream itself on a skipped frame that recorded copies. Nothing about this is visible without a device, which is what makes it worth recording: the failure it prevents would have looked like intermittently stale panels.

### The plan's claim about the run loop, which was wrong

`phase_08.md` states that "lunette owns its own run loop and must skip that call itself". It does not: `crates/lunette-lovr/build.rs` stages `vendor/lovr/etc/boot.lua` verbatim and `crates/lunette/src/boot.rs` runs it, so `lovr.run` is LÖVR's own — which is what `docs/lovr-integration.md` says lunette keeps. The wrap of `package.preload['lovr.headset']` is what replaces the loop change the plan assumed.

### The file-size check

Six files were over the 1000-line Rust threshold and each was split along a seam it already had. `state/compositor.rs` gave up its outputs, its processes, and its pacing to three siblings, which is the shape `state/commit.rs` already established; `test_client/mod.rs` gave up `Driver` and every `Dispatch` implementation, so the sending half and the recording half are separate files; `protocol.rs` became a folder with the input, keymap, and process types in their own modules; `frame/mod.rs` gave up mirroring and device teardown; `selection/data_control.rs` gave up the enums that stand for two protocols at once, along with their dispatch; and `lua/tests/mod.rs` gave up its window and spawn cases to submodules beside the ones that were already there.

Two of the splits needed visibility plumbing, both because the type stayed where it was and its methods moved to a sibling: `CompositorState`'s pacing, process, and clock fields became `pub(super)`, and `Driver`'s selection fields did the same. A move into a child module needs none, which is why `frame/mirroring.rs` and `frame/teardown.rs` cost nothing.

Nothing is over the threshold now. The largest are `crates/lunette/src/main.rs` at 986 and `crates/lunette/src/layers/blit.rs` at 985.

### Gaps this phase leaves

Every acceptance criterion of this phase is a human gate, and none was performed. `wp_fractional_scale_v1` and `wp_content_type_v1` are both client hints whose value is what real toolkits do with them, and this machine has no toolkit to ask. The pacing floor's whole purpose — that a throttled client keeps processing input rather than appearing hung — is a statement about client event loops, and lunette's test client is not one. And the cost of an idle frame with scene rendering skipped is a measurement, not an assertion.

## Outstanding

Group A, C1, E1, D13, and D3's recorded half have been taken; see [what the test plan has returned](#what-the-test-plan-has-returned) below. C2 was attempted and is void. The rest of groups B and D are untouched.

[The human test plan](test-plans/2026-08-05-lunette-v1.md) is the procedure for all of them, grouped by what each needs — a repository, a desktop session, a GPU, or the headset powered on. Results come back here.

### What the test plan has returned

Groups A and C were first run on 2026-08-07 with no XR session, and that run is void. The OpenXR loader reads `$XDG_CONFIG_HOME/openxr/1/active_runtime.json`, and pointing `XDG_CONFIG_HOME` at a fixture configuration directory moves it somewhere with no runtime in it. LÖVR then starts with no headset and reports no driver, no session, and a layer limit of zero, which is indistinguishable from a runtime that offers nothing. Every gate below was retaken with `XR_RUNTIME_JSON` naming the runtime explicitly, which the loader honours whatever `XDG_CONFIG_HOME` says.

The headset is a Bigscreen Beyond on Monado in service mode, 3561x3561 per eye at 74.7Hz.

| Step | Criterion | Outcome |
|---|---|---|
| A1 | AC9.2 | Pass. The tests pass in both feature configurations, with no formatting diff and no clippy warning. |
| A2 | AC9.4 | Pass. The compositor tests pass with no Vulkan ICD visible, and the crate's tree carries no `lunette-lovr` and no GPU crate. |
| A3 | AC9.3 | Pass, after one correction. The headerless files and `PROVENANCE.md` reconcile exactly. The LÖVR patches add no file and modify only existing MIT-licensed ones. `CREDITS.md` said LÖVR is linked statically, which it is not. |
| A4 | AC9.1 | Half. The offline build passes. The publication half cannot pass yet: see [the unpublished submodule commit](#the-unpublished-submodule-commit). |
| C1 | AC5.5 | Pass, after a fix. The restart segfaulted against a live session; see [the restart that faulted](#the-restart-that-faulted). Numbers below. |
| C2 | — | Void, not taken. It read a layer limit of zero as the null compositor refusing layers, and that zero was the absent session. It needs monado restarted with `XRT_COMPOSITOR_NULL=1`. |
| D3 | AC2.2 | Fails as written. The layer is not visibly sharper; see [D3](#d3-and-a-layer-that-is-not-visibly-sharper). The recorded facts are below. |
| D13 | AC7.1 | Pass. Mean frame time was 13.393ms over 448 frames before a client was stopped with `SIGSTOP` and 13.364ms over 449 after it. The difference is noise, the panel held its content, and 13.4ms is the display's own rate. |
| D9 | AC5.4 | Pass. Ten reloads of the shipped configuration left one window, a live session, no error, and a 5.2K log. |
| D12 | AC7.4 | Pass. Numbers below. |
| E1 | AC6.1 | Pass. A primary application held its session; lunette created an overlay session alongside it, spawned a client, and ran 2247 frames; the primary was still running afterwards. Session creation succeeding is not evidence that anything is composited, and E2 is what establishes that. |
| E2 | AC6.2 | Pass. With a primary application drawing fourteen cubes around the viewer, lunette's panel appeared over them, the terminal on it was legible, and the cubes stayed visible and untinted. LÖVR clears the overlay's projection layer transparent on its own once the extension is enabled, so no configuration has to ask for it. |
| D1 | AC2.1, AC5.1 | The first half. A spawned client's pixels reach the headset and are legible there. The panel drawn was a plain quad rather than `mullion.panel`, so the shipped policy layer's own appearance is still unjudged, as is D2's tuning. |

### What the layer path did with a real panel

D3's recorded half, and the first layer this project has granted to a real window.

| Question | Answer |
|---|---|
| The limit Monado reports | 128, which is `XRT_MAX_LAYERS`. `LayerBudget::from_runtime_limit` makes that 12 slots, the ceiling. |
| The ladder rung an 800x600 window takes | 832x640. The plan expected 1024x1024, so the ladder is finer than it assumed and the rung is a closer fit than the estimate. |
| Whether `lovrLayerCreate` stalled | No. The first grant arrived 26.5ms after the claim, which is two frames at this rate. The retry loop ending in `xrWaitSwapchainImage` with `XR_INFINITE_DURATION` was not reached. |
| The free list | It works and it is worth having. A release followed immediately by a claim of the same size was granted in 13.5ms, one frame, against 26.5ms for the first. |
| Whether format conversion was needed | Not observable. Nothing logs it, and the answer needs instrumentation the blit path does not have. The client committed `AR24`, so the conversion the plan predicts is likely, but this is not evidence of it. |

### The restart that faulted

`lunette.restart()` segfaulted against a live XR session, and passed without one, which is why nothing had caught it: no test has an XR session.

The validation layer named the cause. `xrDestroySession` frees the runtime's client-side swapchain command buffers while they are still pending, and destroys a timeline semaphore still in use by the queue. This file and `crate::restart` both recorded `gpu_destroy`'s `vkDeviceWaitIdle` as the wait that covers the teardown. It is real, and it runs inside LÖVR's own finalizer chain, after the XR session has already been destroyed. Nothing drained the device before that point.

`tear_down_device` now waits on the device first. The step is guarded on the graphics module being initialised, because `lovrGraphicsWait` submits before it waits and aborts when there is no device to submit to; the exit-status fixtures switch graphics off and caught that immediately.

### The restart measurements

Phase 7 asks for four numbers about a restart. C1 takes them, driven the way the test plan specifies: two clients connected, the restart arriving over `lunctl`, under the Khronos validation layer, against a live session.

| Number | Result |
|---|---|
| Whether the quiesce covered every GPU object | Yes, to the extent the recorded LÖVR limitation allows. `vkDestroyDevice` reported twelve leaked objects at the restart: six `VkImage` and six `VkDeviceMemory`, one pair per abandoned image. It reported four at the final exit, one pair per surviving client. Every one is under `VUID-vkDestroyDevice-device-05137`, and no other validation message appeared. |
| Whether re-import succeeded for every retained dmabuf | Yes. Both surviving clients re-imported. |
| Whether any client noticed | No. Both were present before and after, and the session generation moved from 1 to 2, so the XR session was genuinely replaced under them. |
| The end-to-end duration | The compositor released the graphics device in 127µs, discarding no events. |

The two expected leaks behave as [decisions.md](decisions.md) predicts: LÖVR's morgue is emptied only by `gpu_destroy`, so an imported image is forgotten rather than destroyed. Validation 1.4.350 folds the object list into the one `05137` message rather than emitting the separate `OBJTRACK` message the test plan anticipated. That is a layer-version difference.

The validation layer is not in the flake's devshell and had to be brought in for the run. Adding it is worth doing.

### A failed window fills the disk

A session that can reach neither a display nor an XR runtime writes an unbounded stream of `GLFW error 65537: The GLFW library is not initialized` to stdout. One observed run produced 112MB in roughly seventy seconds. The trigger is a misconfigured environment rather than ordinary use, but the consequence is a long-running session filling a disk, so it is recorded rather than dismissed.

The chain is `lovr.headset.getViewAngles`, which `boot.lua` calls every frame on the simulator path, reaching `lovrHeadsetGetDisplayDimensions`, which falls through to `lovrSystemGetWindowSize` and `os_window_get_size` when the headset driver is the desktop fallback. With no window that call raises `GLFW_NOT_INITIALIZED`, once per frame.

Nothing in lunette can intercept it. `os_glfw.h:144` writes the message with `printf`, so it bypasses the `lovrSetLogCallback` lunette installs, goes to stdout rather than stderr, and carries no level a filter could act on. The fix belongs upstream: an error callback in a library routes through the library's own log. That is a change to an existing path rather than an addition, so it is a pull request to open and discuss rather than a patch to carry.

Two conditions are needed together, and either alone is harmless. `GLFW_BUILD_WAYLAND` is `OFF` in `vendor/lovr/CMakeLists.txt:113`, so LÖVR's GLFW is X11-only and a Wayland session without `DISPLAY` reaches no display at all.

### The window texture carries the client, and this is now shown rather than argued

A window's texture was read back through `Texture:newReadback`, encoded, and looked at. It carries the client's pixels: the text the spawned shell printed, at 800x600, in the right orientation, with the right colours. The path from a client's dmabuf through the Vulkan import to a LÖVR texture is therefore end-to-end correct, which AC1.2 asked for and which nothing had previously demonstrated with pixels.

The texture's format is `bgra8`. That is the non-sRGB BGRA the layer chapter predicts a client commits, so the conversion described there applies and D3's open question about format conversion is answered in the affirmative for this client.

A readback is served when the graphics module next submits and polls. lunette's frame loop submits through its own path, so a configuration taking one calls `lovr.graphics.submit()` and waits on the readback rather than expecting a flush.

Reading `lovr.headset.getTexture()` the same way does not work and is recorded so it is not retried. Called from `lovr.update`, it returns the image for a frame whose draw pass has not run, and the readback is uniformly zero. A capture of what the headset is shown has to be taken after the frame is submitted, against the image that frame used.

### A truthy return from lovr.draw discards the frame

`vendor/lovr/etc/boot.lua:216` reads `if headset and lovr.draw and lovr.draw(headset) then headset = nil end`, and the discarded pass is never submitted. A configuration whose `lovr.draw` returns a truthy value therefore renders nothing at all, while the session stays active, visible, and focused, and the frame loop runs at the display's rate.

Four gate configurations written for this plan ended `lovr.draw` with `return true`. Every one of them presented an empty frame, and the symptoms read as a runtime that accepts an overlay session and never composites it: the extension reports enabled, `isVisible` and `isFocused` are true, thousands of frames run, and the headset shows nothing. Three separate explanations were pursued before the cause was found, and none of them was in lunette.

The shipped configuration does not do this, which is why it was the only one that ever drew anything.

### What the overlay needs from the runtime, and what it does not

Two things were established while chasing the above, and both are worth keeping.

An overlay session presents on an idle runtime with nothing else running. An earlier entry here said the opposite. That claim came from runs carrying the `lovr.draw` fault above, which presented nothing whatever else was true, and it did not survive a session without the fault.

The overlay's projection layer is cleared transparent by LÖVR itself once `XR_EXTX_overlay` is enabled, at `headset.c:3067-3071`. A configuration does not have to call `lovr.graphics.setBackgroundColor` with a zero alpha, and the shipped one does not. This was tested directly by removing the call and confirming the application underneath stayed visible.

### The API cannot say whether another application is present

A backdrop that is opaque when lunette is the only application and fades once another takes the primary session is policy, so it belongs in `mullion`. It cannot be written against the current API. `lovr.headset.isVisible` and `isFocused` describe lunette's own session and answer true whether or not anything else is running, and nothing else reports the runtime's other clients.

Without it a configuration has one background for both cases, and neither choice is right in the other: opaque blacks out an application underneath, and transparent leaves a user alone on an idle runtime with nothing behind their panels.

### What skipping the scene saves

D12, with three clients each holding a granted composition layer and a `lovr.draw` that draws nothing. That state is not reachable with the shipped configuration, which draws chrome around every panel and a laser for every hand.

| State | CPU per frame | Frames in 25s |
|---|---|---|
| Scene drawn, though it draws nothing | 0.312ms | 1890 |
| Scene skipped | 0.153ms | 1890 |

Skipping saves 0.159ms of CPU per frame, about half. The frame count is identical in both, which is the point: the session is paced by the display at 75.6Hz either way, so the saving does not appear as a frame rate and cannot be inferred from one. An empty `lovr.draw` still costs the full amount when the scene is not skipped, because the cost is in acquiring the headset texture and the pass rather than in anything Lua does.

Measured as process CPU time over a fixed wall-clock window, on a debug build. A release build will differ in magnitude. GPU time is not measured: `lovr.graphics.getTiming` returns a polled readback and needs timing enabled, which no configuration key appears to expose.

### D3, and a layer that is not visibly sharper

AC2.2 asks that a panel on a composition layer be visibly sharper than the same panel drawn in scene. It is not. The difference is imperceptible, and the observer reported being unable to tell the two apart without the marker naming which was showing.

The comparison was built to find a difference and had three faults corrected before it could. The panel faced away from the viewer, so the single-sided layer showed nothing and the quad showed its back. The terminal ran `ls` against a path with nothing in it, so the panel was nearly blank. The window was 800x600, which at the panel's angular size is coarser than the display resolves, so the source limited sharpness rather than either path's resampling.

What was finally measured: a 1600x1200 client on rung 1664x1280 with the viewport clipped to the window, shown 0.6m wide at 0.8m and facing the viewer, alternating every five seconds against an in-scene quad at the same pose and size. The panel subtends about 41 degrees and the display gives about 40 pixels per degree, so roughly 1630 display pixels carry a 1600 pixel texture. That is close to 1:1, which is where an extra resampling pass has the least headroom to hide. The content was generated rather than read from disk, in columns of single-stem glyphs and dense punctuation chosen because a soft resample turns a crisp vertical rule into a grey smear.

The result is consistent with the physics rather than surprising. One well-filtered resample of a roughly 1:1, axis-aligned, stationary image costs little. Where a layer should win is the cases this test does not cover: oblique angles, minification at distance, and reprojection when the compositor's frame rate and the session's diverge.

This does not settle whether the layer pool is worth having, and the case for it does not have to rest on sharpness. [What skipping the scene saves](#what-skipping-the-scene-saves) measures a halving of per-frame CPU once every panel is on a layer and the scene is skipped, which is an independent justification the sharpness claim never carried. Restating AC2.2 in terms of that, or in terms of reprojection stability, is a change to a recorded decision and belongs in [decisions.md](decisions.md) with its reasoning, not here.

One difference between the two paths is visible, and it is not sharpness. A panel on a layer cannot be seen from behind and a panel on a quad can, because a quad composition layer is single-sided. `mullion` chooses when a panel is on a layer, so a grant landing would make a panel that was readable from behind vanish. The API documentation states that the in-scene quad is the fallback rather than a degraded mode, and a panel disappearing when the pool happens to have a slot free is a way for the two to differ that nothing accounts for.

### The unpublished submodule commit

`vendor/lovr` is pinned to a commit on the local `lunette` branch, and that branch has never been pushed. A recursive clone from anywhere else fails on it: `upload-pack: not our ref 43715f87`. AC9.1 is unreachable by anyone but the machine holding the branch until the submodule is repointed at a lunette-owned fork, which is the pre-push task [CONTRIBUTING.md](../CONTRIBUTING.md) records. The offline-build half above had to be measured with the local checkout substituted for that one submodule.

### The documented `lunctl` examples

Every example in [the Lua API](lua-api.md#lunctl) failed against a real session. A chunk was evaluated against the bare globals, and the API is a module a configuration binds to a local, so `lunctl 'return #lunette.windows()'` indexed a nil.

Nothing caught it because the test helper at `crate::lua::tests` assigns `lunette = require 'lunette'` into the state before evaluating, so every `lunctl` test exercised an environment production never built. This is the same shape as the `rules.matches` defect this file already records: a fixture stands in for the thing under test and agrees with itself.

A chunk now runs in an environment that resolves a module by its own name, globals first. The regression test is `a_chunk_reaches_a_preloaded_module_by_its_bare_name` in `control/eval.rs`, which builds a state with a preloaded module and no global naming it — the shape a real session has — and fails against the unfixed code.

`mullion.layout.arc(mullion.tag.current())` was wrong for a second reason and was corrected in the documentation rather than in the code: the `mullion` root re-exports nothing, deliberately, so a submodule is required by its own path.

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
- Keystrokes reach whatever the host focuses (AC3.3). The Lua path exists as of phase 5: `sink:key`, `sink:modifiers`, and `sink:scroll` route to `send_key`, `set_modifiers`, and `wheel` for a host sink, and the seat's layout is uploaded through `set_keymap` before the first keystroke — which is what `wl_virtual` was waiting on, since a virtual keyboard is disconnected by its first key without a keymap. What remains is hardware: uinput has never issued `UI_DEV_CREATE` to a kernel from this tree, and no key has reached a real host compositor. The routing is covered by `crates/lunette/src/lua/tests/seats.rs` against a recording provider, which establishes that the calls are made and in what order, and nothing about whether a real desktop receives them.
- Monitors are selected once, in one dialog, in any order, and reattach correctly after a restart (AC3.4). The second run is the half that matters: whether the stored restore token avoided a second prompt is unanswered, and it is unanswerable without a first grant.
- Dismissing a mirror stops its stream, and re-adding it restarts capture without re-prompting (AC3.5). The decisions are tested against a fake portal; the stream actually stopping is not.

The four questions [phase 4](implementation-plans/2026-08-05-lunette-v1/phase_04.md) asks to be recorded are the same four, restated: which portal backend was tested and what it put in `mapping_id`, whether restore avoided a prompt on the second run, whether the uinput mapping was correct on a scaled or rotated display, and the GNOME result. All four are open. What is known about the backend without a grant is under [the portal on this machine](#the-portal-on-this-machine).

### The five keyboard, seat, and clipboard gates

None of the five has been performed, and none of them can be performed on the machine this document records. Two of them need a headset and a pair of hands, and three need a host desktop session, which a bare TTY does not have. They are phase 5's acceptance criteria, all five human gates.

- Two hands hover two different windows simultaneously, each with its own cursor (AC4.1). The seat independence is established by `tests/seats.rs` against a real client; what has not happened is a person putting two hands in a scene and watching two cursors move apart.
- Typing reaches the focused sink with the correct layout (AC4.2). The keymap arithmetic is unit-tested against the US and German layouts, and a synthetic keymap reaching a client is covered in `tests/type_text.rs`. No key has been pressed on real hardware and read out of a real terminal.
- `typeText` enters text the layout cannot express, and the client's keyboard works normally afterwards (AC4.3). The second clause is verified in tests, as recorded above. The first clause is verified in tests too, against lunette's own test client; what is untested is a real toolkit — GTK, Qt, a terminal — recompiling a synthetic layout twice in quick succession and behaving.
- A popup menu receives clicks at the right coordinates (AC4.4). This is the gate with the most direct automated evidence: `a_click_over_a_popup_is_delivered_to_the_popup_in_surface_local_coordinates` establishes the whole path through a real client. What remains is a person opening a real menu in a real application and clicking an item.
- Text copied on the host pastes into a lunette terminal, and text copied there pastes on the host, for both the clipboard and the primary selection (AC4.5). Nothing about this is established. `selection/data_control.rs` has never spoken to a host compositor, and the bridge's behaviour on any particular desktop is unknown. This gate also settles which hosts take the `NoDataControl` path, and it is where the strict MIME rule would first show itself.

### The four standard-library gates

None of the four has been performed, and none of them can be performed on the machine this document records: they need a headset, two hands, and an XR runtime, and this machine has a bare TTY. They are phase 6's acceptance criteria, all four human gates, and the first three are `lunette-v1.AC5.1`, `AC5.2`, and `AC5.3` in order.

- The default configuration spawns a terminal onto a panel at the pose and metre size it specifies (AC5.1). The parts have each been observed separately in earlier phases — a terminal appears in `lunette.windows()` with a matching texture, and a quad is drawn and screenshotted from the simulator — and the panel abstraction over them has been exercised only against fakes. What has not happened is a person looking at a panel and reading the terminal on it.
- Panels can be grabbed and moved, and the placement feels right. This is the tuning pass, and it is the one gate that is not a yes-or-no question: the constants under `interaction.TUNING`, `laser.STYLE`, and `arc.TUNING` are first guesses, and the point of the gate is to replace them with numbers somebody has used. Grab-to-resize was deferred until after it, for the reason `docs/stdlib.md` gives.
- A rule matching on `appId` places a named application without further scripting (AC5.2). The matching, the layering of two rules, the lazy evaluation of a function-valued property, and the composition of the rules table with the restore source are all covered by specs over synthetic window tables. What has not happened is a real application opening and landing where the rule said.
- An arrangement survives a restart (AC5.3). The file round-trips, a stale entry is skipped and reported while the rest restores, an absent file yields defaults, and a file from a later version is left alone rather than rewritten — all against a fake filesystem. What has not happened is a session being quit and started again with a real save directory under it. This gate is also the one that would show whether the shipped configuration writes at the right moments: it saves when a panel is dropped and when the session quits, and a session that is killed rather than quit keeps only what a drop wrote.

Two more things are worth watching for while these are performed, both recorded above rather than here: a monitor panel is drawn as an in-scene quad however sharp a layer would have been, and a monitor panel's hand-placed pose is remembered across a restart but not across a soft reload.

### The four reload, `lunctl`, and error-handling gates

None of the four has been performed, and none of them can be performed on the machine this document records: three need a headset and an XR runtime, and the fourth needs a session a person is looking at. They are phase 7's acceptance criteria.

- A soft reload applies a layout change without disconnecting any client, and a hand-placed panel keeps its pose (AC5.4). Both halves have automated evidence and neither is the gate. `tests/reload.rs` reloads ten times against the real binary and asserts nothing accumulates, and it reloads with a real Wayland client connected and asserts the client keeps its window and can still speak. The pose half is covered by `mullion.adopt`'s specs against a fake property store. What has not happened is a person editing a layout, pressing the key, and watching the room rearrange around a terminal that never blinked.
- `lunette.restart()` rebuilds the Lua state and the XR session while clients stay connected, with the expected visible hitch and brief blackness (AC5.5). The quiesce protocol is covered against a real compositor thread and the re-import against a fake importer, and no restart has ever destroyed a real `VkDevice` with a real client's images imported against it. **Watch for a Vulkan validation error at teardown**: this machine has no validation layer installed, so the one instrument that would catch a quiesce that missed something is absent, and a driver tolerating the miss would look like a pass. Installing the layers before performing this gate would make it worth much more.
- An error in a callback shows a panel and the session continues, and an error repeating every frame is rate-limited (AC8.3). Both halves are established without a headset: `lua::tests::events` raises the same error through the real dispatcher for two hundred frames and asserts one report, and `mullion.error.panel`'s specs assert what the panel says. What has not happened is a person seeing the panel in a scene and judging whether it is legible, whether it sits where it should, and whether the truncation cuts somewhere useful.
- A syntactically invalid `main.lua` produces safe mode with a laser, a panel, and a reload key, not a black headset (AC8.4). `tests/safe_mode.rs` breaks two configurations for real and asserts a running session that `lunctl` can talk to, and the laser, the panel, and the ray-plane solve are covered against fakes. What has not happened is a person putting the headset on with a broken configuration and finding something there.

### The four output, scale, and pacing gates

None of the four has been performed, and none of them can be performed on the machine this document records: two need a headset and an XR runtime, and all four need a real client with a real toolkit under it. They are phase 8's acceptance criteria.

- A client reports only its own output (AC2.5, first half). What the client sees in the registry is covered against lunette's own test client, which binds what it is told to bind and nothing else. What has not happened is `wayland-info` run inside a spawned client's environment, listing one `wl_output` and no others, and a toolkit behaving normally with only one monitor to lay out against.
- Approaching a panel raises its scale, the client re-renders sharper, and the layer samples the new buffer (AC2.5). The events are covered — the preferred scale as `round(scale * 120)`, the `wl_output.scale` that accompanies it, and the toplevel configure at the matching logical size — and every one of them is what lunette sends rather than what a client does with it. Record while performing this: **which clients honoured `wp_fractional_scale_v1` and which ignored it**, and **whether the scale ladder's steps were the right ones in practice** or whether the rungs are too far apart to be worth the re-render.
- A backgrounded panel's client stops redrawing at full rate while remaining responsive to input (AC7.3). The throttle is covered against a fake clock, and the half that matters is the second: click a throttled window and confirm it reacts. A rate of zero would pass the first half and fail this one, which is why the floor is approximately 1 Hz. Record while performing this: **whether any client set `wp_content_type_v1` at all**, which decides how much of the video exemption rests on the commit-rate heuristic instead.
- An idle lunette with only layers drawn issues no render pass (AC7.4). Confirm it with a GPU profiler or LÖVR's own timing rather than inferring it from a frame rate, because the flag and the skip are separable and only the skip saves anything. This gate needs a configuration whose scene is genuinely empty; the shipped one draws chrome around every panel and a laser for every hand, so it never is. Record while performing this: **the measured cost of an idle frame with scene rendering skipped**, against the same frame with it drawn.

### The socket, which is not a gate

Phase 7 asks for the socket's mode to be verified by inspection. It is verified by test instead, and by a stronger one: `the_socket_is_0600_inside_a_0700_directory_and_is_not_a_network_address` in `tests/lunctl.rs` reads the mode of the directory and of the socket a real session bound, and asserts the path is a Unix socket. There is nothing an `ls -ld` would add. `ss -lx` is likewise redundant: the type in the source is a `UnixListener` and nothing in the program accepts a host or a port, so there is no configuration under which a network address could appear.

### The end-to-end client

The `lunctl` end-to-end tests spawn no client, and cannot. A headless fixture switches the graphics module off; the compositor thread starts only once LÖVR has a device to lend it, so with no device the thread never starts and nothing can connect to the Wayland socket the session bound. Spawning a client, asserting it appears in `lunette.windows()`, asserting its properties, and tearing down therefore needs the GPU-headless tier [build and development](build-and-development.md#testing) describes as a nice-to-have.

Until that exists the client half is covered in two places that do not meet: `crates/lunette-compositor/tests/` drives a real client against the compositor with no frame loop under it, and `crates/lunette/tests/lunctl.rs` drives the frame loop with no client. The seam between them is what this gate is about.

### The GNOME pointer-mapping unknown

Unmeasured, and it decides whether AC3.2 is achievable on GNOME at all. It is not known whether mutter maps a bare absolute uinput device across the whole layout or binds it to a single monitor. If it maps across the layout, the phase's arithmetic is what it needs. If it binds to one monitor, no arrangement of absolute coordinates reaches the others, and the honest answer on GNOME is libei through `org.freedesktop.portal.RemoteDesktop`, which v1 does not implement — so the limitation would be recorded rather than worked around.

This machine registers the GNOME backend and runs no GNOME session, so it can name the path that would be exercised and measure nothing about it.

### The two `undefined` rows of the queue-family measurement

The two `undefined` rows under [the queue family for the acquire](#the-queue-family-for-the-acquire) are annotated as invalid rather than replaced, and re-running them is a task rather than a condition attached to citing them. It needs the census harness, a real GPU, and a client, which is why it was not done when the release barrier was fixed. Until it is done, the `undefined` half of the queue-family question and the `undefined` half of [the transition out of an undefined layout](#the-transition-out-of-an-undefined-layout) are unmeasured, not merely uncertain. The default rests on the `general` rows, which are unaffected, so nothing is blocked on this; it is recorded here so the hole stays visible.
