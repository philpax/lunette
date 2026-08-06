# Milestone 0 findings

Milestone 0 exists to de-risk two unknowns before a standard library is written on top of them: the LÖVR Vulkan patch, and the compositor-thread split with the snapshot model it forces on Lua. [Roadmap](roadmap.md) states both. This document records what the two actually did, so phases 4 to 8 are detailed against measurement rather than against the design's expectations.

Two of the milestone's acceptance criteria are human gates and are not recorded here as passed. They are listed under [Outstanding](#outstanding), together with the one measurement that has to be taken again.

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
| `cargo test --workspace` | 266 passed, 0 failed, 0 ignored |
| `cargo test --workspace --no-default-features` | 266 passed, 0 failed, 0 ignored |

The 266 are 146 in `lunette`, 11 in its binary target, 3 in `tests/exit_status.rs`, 96 in `lunette-compositor`, 6 in `tests/client_lifecycle.rs`, and 4 in `tests/pointer_routing.rs`. The compositor's 106 run with no graphics device and no XR runtime, which is the separation [CONTRIBUTING.md](../CONTRIBUTING.md) requires of `lunette-compositor`.

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

## Outstanding

Three items are unfinished: two human gates, and one measurement that has to be taken again.

### The two human gates

Neither gate has been performed. Both are in [phase 2](implementation-plans/2026-08-05-lunette-v1/phase_02.md) as acceptance criteria, and neither is automatable.

The first gate is that a terminal spawned by lunette appears on a quad in the desktop simulator and responds to a click. Its constituent parts have each been observed: the terminal appears in `lunette.windows()` at 800x600 with a matching texture, it is drawn on a quad and screenshotted from the simulator, and a Lua-issued click is reported by the child at the right coordinates. What has not happened is a person looking at the quad and clicking it. The parts passing separately is not the gate.

The second gate is that the same build runs as an overlay under Monado alongside another OpenXR application, compositing over it with undrawn areas transparent. Nothing in this document bears on it. It requires a running Monado, a second OpenXR application, and a person to judge the compositing.

Both gates should be performed before phase 3 begins, because phase 3 is the composition-layer work and it is detailed against the assumption that the overlay session behaves as designed.

### The two `undefined` rows of the queue-family measurement

The two `undefined` rows under [the queue family for the acquire](#the-queue-family-for-the-acquire) are annotated as invalid rather than replaced, and re-running them is a task rather than a condition attached to citing them. It needs the census harness, a real GPU, and a client, which is why it was not done when the release barrier was fixed. Until it is done, the `undefined` half of the queue-family question and the `undefined` half of [the transition out of an undefined layout](#the-transition-out-of-an-undefined-layout) are unmeasured, not merely uncertain. The default rests on the `general` rows, which are unaffected, so nothing is blocked on this; it is recorded here so the hole stays visible.
