# lunette v1 Implementation Plan — Phase 2: Milestone 0, the vertical slice

**Goal:** A spawned Wayland client's window drawn on a quad and clickable, in the desktop simulator and as a Monado overlay.

**Architecture:** `lunette-compositor` runs smithay on its own thread, constructed inside the thread closure because `calloop::EventLoop` is not `Send`. It talks to the main thread through a bounded command channel, a bounded event channel, and an `ArcSwap` snapshot published per tick. Client dmabufs are imported with `ash` against LÖVR's existing `VkDevice`, and the resulting `VkImage` travels up the event channel to be wrapped as a LÖVR `Texture`. Three narrow, additive patches to LÖVR make foreign image import safe.

**Tech Stack:** smithay 0.7.0 (`default-features = false`), ash 0.38.0+1.3.281, arc-swap, calloop 0.14, smithay-client-toolkit 0.21.1 (dev only), xwayland-satellite.

**Scope:** Phase 2 of 8 from `docs/dev/design-plans/2026-08-05-lunette-v1.md`.

**Codebase verified:** 2026-08-05.

---

## Acceptance criteria coverage

### lunette-v1.AC1: Applications become sources of pixels and input
- **lunette-v1.AC1.1 Success:** A client launched by `lunette.spawn` connects to lunette's socket, and its toplevel appears in `lunette.windows()` on the frame after it maps.
- **lunette-v1.AC1.2 Success:** A committed dmabuf is imported, and `window:getTexture()` returns a texture whose dimensions match the surface.
- **lunette-v1.AC1.3 Success:** A process started outside lunette with `WAYLAND_DISPLAY` pointing at its socket is adopted, reported with `external = true`, and attributed to a process handle.
- **lunette-v1.AC1.4 Failure:** Spawning a non-existent executable reports the failure through an event and creates no window.
- **lunette-v1.AC1.5 Failure:** After a client exits, its handle reports `dead == true`, reads return last-known values, and every method returns `false` without raising.
- **lunette-v1.AC1.6 Edge:** A client using `wl_shm` rather than dmabuf still produces a usable texture.

### lunette-v1.AC2: Panels render, on layers where possible
- **lunette-v1.AC2.1 Success:** A window texture drawn on an in-scene quad appears at the pose Lua specified.

### lunette-v1.AC6: It is an overlay, not an application
- **lunette-v1.AC6.1 Success:** lunette runs with `XR_EXTX_overlay` under Monado while another OpenXR application holds the primary session.
- **lunette-v1.AC6.2 Success:** lunette's layers composite over the underlying application rather than replacing its view, and areas Lua did not draw remain transparent.

### lunette-v1.AC7: The overlay stays cheap
- **lunette-v1.AC7.1 Success:** A client stalled inside its own dispatch does not extend lunette's frame time, because compositor work runs off the frame thread.

### lunette-v1.AC9: Cross-cutting
- **lunette-v1.AC9.3 Success:** Every file ported from WayVR carries a provenance header, `vendor/lovr` patches are MIT, and `CREDITS.md` records provenance.
- **lunette-v1.AC9.4 Success:** The `lunette-compositor` test suite runs without a GPU, an XR runtime, or a headset.

---

## Facts established by investigation

These are the reasons the tasks below differ from the design's component list. Each was verified against the reference checkouts or upstream specification.

### The design's component list is incomplete

`comp.rs`, `client.rs`, `window.rs`, and `time.rs` are named for porting, but they do not compile alone.

- **`mod.rs` supplies types all four depend on** and is on no list: `WayVRTask` (`mod.rs:125`), `WaylandEnv` (`:95`), `ProcessWayVREnv` (`:111`), `ExternalProcessRequest` (`:117`), `MouseIndex` (`:154`), `WAYVR_SCREEN_RES` (`:172`), and `SurfaceBufWithImage` + `SurfaceBufWithImageContainer` (`:1351-1391`). Roughly 150 lines of additional port.
- **`process.rs` is a hard dependency** of both `client.rs` (`:150`) and `window.rs` (`:20`), and Phase 2 needs `lunette.spawn` and external attribution regardless.
- **Popup tracking is not deferrable to Phase 5.** `PopupManager` is a field of `Application` (`comp.rs:87`), `popups_commit` runs on every commit (`comp.rs:111,229`), and `constrain_popup`/`new_popup`/`popup_destroyed`/`grab`/`reposition_request` live at `comp.rs:193-522`. Phase 2 gets popup tracking whether it wants it or not; Phase 5 adds popup *routing*, which is the genuinely separable part.

The Phase 2/Phase 5 split is otherwise clean: `comp.rs`, `client.rs`, `window.rs`, and `time.rs` contain zero references to `hit_test.rs` or any of its types.

### Two thread-affine sites the design missed, and one it described wrongly

The design names four thread-affine structures. All four are real, but the account needs correcting and extending.

- `Rc<ToplevelSurface>` in `window.rs` — confirmed at `:1`, `:19`, `:27`, `:142`, constructed at `mod.rs:348`. Note `ToplevelSurface` is itself `Clone` and cheap, so dropping the wrapper entirely is as valid as `Arc`.
- `Rc<[_]>` in `hit_test.rs` — confirmed, but at **three** sites, not one: `:60` (`surfaces`), `:61` (`popup_roots`), `:229` (return type). Phase 5's problem, recorded here so it is not rediscovered.
- `SyncEventQueue` — confirmed `Rc<RefCell<Data<T>>>` in `wayvr/src/ipc/event_queue.rs`, neither `Send` nor `Sync`. The name is a lie.
- **The `insert_if_missing` account is wrong in a way that matters.** It returns `bool`, not `Option`. The `None` comes from `UserData::get` (`smithay-0.7.0/src/utils/user_data.rs:78-88`), which records a `ThreadId` at insert and returns `None` from any other thread. The consequence is worse than "textures vanish": `insert_if_missing` calls `get` first, receives `None` cross-thread, and **inserts a second entry**, so each thread silently sees its own copy. Divergent state, not absent state. Separately, `UserData::drop` (`:91-102`) only drops non-threadsafe payloads on the originating thread and **leaks otherwise** — a `WlSurface` destroyed off-thread leaks the retained `WlBuffer` and the image handle. The design's conclusion stands; its reasoning does not.

Two further sites inside the Phase 2 port set:

- **`with_fractional_scale` at `comp.rs:125` and `comp.rs:145`** is thread-affine. smithay's implementation (`src/wayland/fractional_scale/mod.rs:253-263`) is `data_map.get_or_insert(...)` — the non-threadsafe insert — holding a `RefCell`. These calls are currently no-ops, because `FractionalScaleManagerState` is never constructed anywhere in WayVR, so `wp_fractional_scale_v1` is never advertised. Phase 8 wants it for real; there is no WayVR precedent to port.
- **`SurfaceBufWithImageContainer` has a second field the design omits**: `retained_dmabuf_buffer: RefCell<Option<WlBuffer>>` (`mod.rs:1353`). This implements buffer release — `apply_to_surface` returns the previous buffer and `comp.rs:255-258` releases it. Moving images to the event channel does not remove the need for that ownership rule. Lose it and clients recycle buffers underneath lunette.

`insert_if_missing_threadsafe<T: Send + Sync + 'static>(&self, init: F) -> bool` (`user_data.rs:190`) exists, so a `Mutex`-wrapped payload is a real alternative to the event channel. The event channel is still preferred, because it keeps GPU types out of the compositor crate.

### The `UNDEFINED` transition — the highest-risk finding

`lovrTextureCreate` takes the `else if (!gpu_texture_upload(texture->gpu, &(gpu_upload_info) { 0 }))` branch at `graphics.c:2635` for any texture with `imageCount == 0`, which includes every imported dmabuf. That queues an upload with `copyCount == 0`, and at the next `gpu_submit` the `copyCount == 0` branch (`gpu_vk.c:3779-3793`) records a barrier with:

```c
3789:          .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
3790:          .newLayout = upload->layout
```

over `VK_REMAINING_MIP_LEVELS` and `VK_REMAINING_ARRAY_LAYERS`. `VK_IMAGE_LAYOUT_UNDEFINED` as `oldLayout` **permits the driver to discard the image contents**. So wrapping a client's already-rendered dmabuf in a LÖVR `Texture` is not side-effect-free.

With the per-dmabuf import cache this fires once per buffer rather than once per frame, and the client redraws, so it may be survivable in practice. It is patched anyway (Task 3), because relying on a client to repaint after a discard is not a property this design should depend on.

### What LÖVR assumes about a foreign image

`gpu_texture_init`'s handle branch is small (`gpu_vk.c:687-695`): no `vkCreateImage`, no allocation, no bind. Everything before line 687 still runs. The assumptions that follow:

- **Layout.** `texture->layout = getNaturalLayout(info->usage)` (`gpu_vk.c:673`, definition `:4286-4295`) is set at creation and treated as ground truth forever. LÖVR never queries the image's real layout. Declaring `TEXTURE_SAMPLE | TEXTURE_TRANSFER` makes `getNaturalLayout` return `VK_IMAGE_LAYOUT_GENERAL`, which is the easiest layout to hand LÖVR and is required for `lovrTextureCopy` anyway.
- **Queue family.** LÖVR assumes the image is already owned by `state.queueFamilyIndex`. It performs no acquire from `VK_QUEUE_FAMILY_FOREIGN_EXT`.
- **Usage flags.** Never validated. LÖVR builds a `VkImageViewUsageCreateInfo` from the caller-declared `info->usage` (`gpu_vk.c:838-846`). If the imported image lacks `SAMPLED_BIT`, view creation fails. The importer must create the `VkImage` with usage matching the `TextureInfo.usage` it later declares.
- **Format.** LÖVR assumes `convertFormat(info->format, info->srgb)` equals the image's real `VkFormat`. A mismatch is undetectable by LÖVR.
- **Memory ownership.** LÖVR believes it owns nothing: `texture->memory = NULL`, `texture->imported = true` (`gpu_vk.c:688-689`).
- **Destroy.** `gpu_texture_destroy` (`gpu_vk.c:879-885`) destroys only the view, through the deferred morgue, and returns before touching the image. **lunette owns `vkDestroyImage` and `vkFreeMemory`**, and must not free until the morgue has retired the view — that is, not before the tick that created it has completed.
- **Sync tracking.** If `usage == TEXTURE_SAMPLE` exactly, `graphics.c:2647-2657` exempts the texture from per-resource sync tracking. `TEXTURE_SAMPLE | TEXTURE_TRANSFER` gets a real `Sync` object and participates in `syncStream`, which is what a blit target needs.
- **No precedent.** The only in-tree users of the `handle` path are the OpenXR swapchain (`headset.c:3493-3503`) and the FB foveation texture (`:3514-3520`), both images owned by the XR runtime on LÖVR's own device. **No existing user is an externally-imported, cross-process, DRM-modifier image.** The path is genuinely unexercised for this case.
- `handle` is not reachable from Lua — no binding in `l_graphics.c` sets it. It is a C-only entry point, so lunette calls `lovrTextureCreate` from Rust.

### The blit path needs no patch

`lovrTextureCopy` (`graphics.h:258`, impl `graphics.c:2960-2984`), `lovrTextureBlit` (`:259`, impl `:2986-3022`), and `lovrTextureClear` (`:260`) are already public, already take `state.lock`, already record into `state.stream`, and already emit correct `syncStream` barriers. `l_headset.c:958-961` uses exactly that path to push a Texture into a Layer swapchain. Both source and destination must declare `TEXTURE_TRANSFER` (`graphics.c:2967-2968`).

So the only genuinely new export is a `graphics.c`-level wrapper that takes `state.lock` and passes `state.stream` to the new barrier functions. That shape matches how `gpu_xr_acquire` is already used at `graphics.c:1753`.

### Queue families in the existing barriers

`gpu_xr_acquire` (`gpu_vk.c:2900-2918`) and `gpu_xr_release` (`:2921-2939`) set neither `srcQueueFamilyIndex` nor `dstQueueFamilyIndex`. Because these are C designated initialisers on compound literals, both are **implicitly 0** — not `VK_QUEUE_FAMILY_IGNORED`, which is `~0U`. This is benign only because src equals dst, and the specification then ignores both values.

It is not benign for an imported dmabuf. A correct acquire uses `srcQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT` and `dstQueueFamilyIndex = LÖVR's family`; `IGNORED`/`IGNORED` skips ownership acquisition entirely. WayVR gets away with the latter on Mesa. Which of the two actually works is something only measurement answers, and measuring it is part of this phase's purpose.

### ash against a foreign device

- `ash::Instance::load(entry.static_fn(), raw_instance)` (`src/instance.rs:23`), then `ash::Device::load(instance.fp_v1_0(), raw_device)` (`src/device.rs:22`).
- **`load` cannot fail.** A missing entry point becomes a stub that panics on call (`extensions_generated.rs:12032`). If LÖVR created a Vulkan 1.1 device, `Device::load` still "succeeds" and the 1.2/1.3 tables are panicking stubs. lunette must verify `apiVersion` and the enabled extension list itself and raise a structured error.
- `ash::Device` has no `Drop`. Never call `destroy_device` or `destroy_instance`.
- `ash::khr::external_memory_fd::Device` and `ash::ext::image_drm_format_modifier::Device` are the two extension loaders. There is no `ash::khr::external_memory::Device` — that extension and `VK_EXT_external_memory_dma_buf` have structs but no entry points, and must still be in the device's enabled list, which only LÖVR can do.
- **`memoryTypeIndex` must come from `vkGetMemoryFdPropertiesKHR`.** VUID-VkMemoryAllocateInfo-memoryTypeIndex-00648 requires it whenever the fd was created outside Vulkan, which a client dmabuf is. Intersect `memory_requirements.memory_type_bits` with `MemoryFdPropertiesKHR::memory_type_bits`. WayVR's vulkano path does not do this.
- **fds are consumed on success.** `VkImportMemoryFdInfoKHR` transfers ownership to the implementation on `VK_SUCCESS` (Vulkan-Docs `chapters/memory.adoc:2637`). The specification never states the failure case explicitly; the transfer is conditioned on success, so on error the caller still owns the fd and must close it.
- **`Dmabuf::handles()` yields `BorrowedFd`** (`smithay-0.7.0/src/backend/allocator/dmabuf.rs:235`) while the `Dmabuf` retains ownership and closes on drop. Import without `try_clone_to_owned()` first is a double-close.
- **Six extensions, not four.** The design's four plus `VK_EXT_queue_family_foreign` and `VK_KHR_image_format_list`. The latter is already enabled at `gpu_vk.c:3116` as `formatList`.
- **Disjoint dmabufs are out of scope.** Planes backed by different buffer objects need `VK_IMAGE_CREATE_DISJOINT_BIT`, one allocation per plane, and `vkBindImageMemory2` with `VkBindImagePlaneMemoryInfo`. Detect and reject with a clear error rather than importing incorrectly.

### smithay configuration

- `default-features = false` is **mandatory**, not hygiene. The default set pulls libseat, libinput, udev, gbm, winit, and a GL renderer.
- Take `wayland_frontend` and `desktop`. `desktop` is what provides `Window` and `PopupManager`; `Space` comes with it and is largely dead weight for a 3D placement model.
- Leave **`backend_vulkan` off** — it exists to create and own a device, which is exactly what lunette must not do. Read `src/backend/vulkan/mod.rs:546-586` as a reference instead.
- Leave **`xwayland` off** — satellite replaces it, and the feature pulls `x11rb` and `encoding_rs`.
- smithay uses **`rustix`**, not `nix`, and re-exports it at `smithay::reexports::rustix`. Use the re-export. Likewise reach `Fourcc`/`Modifier`/`Format` through `smithay::backend::allocator` rather than depending on `drm-fourcc` directly, since it is not in `smithay::reexports` and a direct dependency can version-skew.
- **`xkbcommon` must be pinned `=0.8.0`**, not the current 0.9.0. smithay 0.7 has a non-optional `^0.8.0` dependency, and 0.9.0 would duplicate the crate and split the xkb types.
- **`calloop::EventLoop` is not `Send`.** Construct the entire compositor inside the spawned thread's closure. Do not build it on the main thread and move it.
- `Display` is `Send` but not `Sync`, and `flush_clients` needs `&mut Display`. Only the compositor thread may touch it. Route cross-thread requests through the command channel, never through a shared `DisplayHandle`, and keep the handoff one-directional and non-blocking — `DisplayHandle` operations take an internal mutex and can deadlock against a dispatch callback waiting on the render thread.
- `ImportNotifier` is `Send` and `#[must_use]`, one-shot. Exactly one of `successful`, `incomplete`, `invalid_dimensions`, `invalid_format`, or `failed` must be called; dropping it logs "Compositor bug: Server ignored ImportNotifier". Being `Send` is what allows the Vulkan import to answer asynchronously.

### Globals

WayVR advertises fourteen. The design's Phase 2 list names six. The correct list for this phase is eight, for three reasons.

- **`wl_subcompositor` cannot be omitted.** `CompositorState::new` creates it unconditionally (`smithay-0.7.0/src/wayland/compositor/mod.rs:685-710`).
- **`wp_viewporter` is a hard requirement of xwayland-satellite.** Without it satellite refuses to start.
- **Both decoration managers are added** by decision on 2026-08-05. WayVR forces `ServerSide` in all three `XdgDecorationHandler` methods (`comp.rs:638-663`) and `Mode::Server` in the KDE handler (`:670-677`). Without them, GTK and Qt clients draw their own titlebars inside every panel.

Not ported: `wp_single_pixel_buffer_manager_v1` handling. `SinglePixelBufferState` is never constructed anywhere in WayVR, so `comp.rs:285-304`, `delegate_single_pixel_buffer!` at `comp.rs:693`, and `import_spb` (`image_importer.rs:33-48`) are dead code.

### Provenance

**WayVR carries no licence or copyright headers.** A recursive grep for `Copyright` and `SPDX` across every `.rs` file returns zero hits. There is nothing to preserve; headers are authored.

Facts for them: licence GPL-3.0-only (`wayvr/Cargo.toml:5`); `authors = ["galister", "oo8dev"]` (`:6`) is the only attribution the project states, and there is no canonical `Copyright (c) …` string anywhere. The README links `wayvr-org/wayvr` while `Cargo.toml:8` says `wlx-team/wayvr` — resolve which is canonical before writing it into every header. The project was formerly WlxOverlay-S (`README.md:3`), which matters for `CREDITS.md`.

### Defects in WayVR not to reproduce

- `/proc/<pid>/environ` is read with `read_to_string` (`client.rs:70`, `process.rs:102`), which **fails on non-UTF-8 environments**. Read bytes.
- The auth key is a v4 UUID (`mod.rs:1346-1349`) compared with `String` equality — not a CSPRNG token, and not a constant-time compare.
- `time.rs:7` uses `.unwrap()`.
- Only the direct child is signalled (`process.rs:132`, `:166`). Grep for `setsid`, `PDEATHSIG`, `process_group`, `pre_exec`, and `killpg` across `wayvr/src` returns **zero hits**, confirming the design's claim. A shell-wrapper grandchild survives.
- `fourcc_to_vk` (`dmabuf.rs:406-413`) maps the X-variants to *alpha* Vulkan formats, so `Xrgb8888` and `Xbgr8888` content renders with whatever is in the alpha byte. Force alpha to 1 when the fourcc is an X variant.
- The debug asserts on extension availability at `dmabuf.rs:80-82` are `debug_assert!` only, so they vanish in release.

---

<!-- START_TASK_1 -->
### Task 1: Provenance and credits

**Verifies:** `lunette-v1.AC9.3`.

**Files:**
- Create: `CREDITS.md`
- Create: `crates/lunette-compositor/PROVENANCE.md`

**Step 1: Resolve the upstream URL**

`wayvr/Cargo.toml:8` says `https://github.com/wlx-team/wayvr`; `README.md` links `wayvr-org/wayvr`. Check which resolves and which is a redirect, and use the canonical one. Every provenance header repeats it, so getting it wrong is expensive to correct.

**Step 2: Define the header form**

WayVR has no headers to copy, so this is authored. Every ported file begins with:

```rust
//! Ported from WayVR (<canonical URL>), <upstream path>, at commit <sha>.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
```

Record the upstream commit per file. WayVR has no release tags in this checkout, and the files will drift.

**Step 3: Write `CREDITS.md`**

Record WayVR (GPL-3.0-only, compositor ported, formerly WlxOverlay-S), LÖVR (MIT, linked and patched), and wlx-capture (GPL-3.0-only, git-pinned dependency, arriving in Phase 4). `docs/dev/decisions.md` already carries the licensing table and the paragraph on why WayVR's contribution is not incidental; `CREDITS.md` is the user-facing form of the same facts and must not contradict it.

State that patches under `vendor/lovr` are MIT, matching upstream, so they remain upstreamable.

**Step 4: Verify**

Run: `rg -c 'Ported from WayVR' crates/lunette-compositor/src/`
Expected: one match per ported file, once Tasks 5 and 6 land. This task establishes the form; the count is checked in Task 16.

**Step 5: Commit**

```bash
git add CREDITS.md crates/lunette-compositor/PROVENANCE.md
git commit -m "docs: record provenance and credits"
```
<!-- END_TASK_1 -->

<!-- START_SUBCOMPONENT_A (tasks 2-3) -->
<!-- START_TASK_2 -->
### Task 2: LÖVR patch — Vulkan device extensions

**Verifies:** None directly; enables `lunette-v1.AC1.2`.

**Files:**
- Modify: `vendor/lovr/src/core/gpu_vk.c`

**Step 1: Add the extension flags**

Add six `bool` fields to the `gpu_extensions` struct at `gpu_vk.c:216-247`: `externalMemory`, `externalMemoryFd`, `externalMemoryDmaBuf`, `imageDrmFormatModifier`, `queueFamilyForeign`. `formatList` already exists at `:3116` and needs no addition — but confirm it, since `VK_EXT_image_drm_format_modifier` depends on it.

**Step 2: Add the extension entries**

Append to the local array at `gpu_vk.c:3128`, matching the existing `{ name, shouldEnable, flag }` shape:

```c
{ "VK_KHR_external_memory", true, &state.extensions.externalMemory },
{ "VK_KHR_external_memory_fd", true, &state.extensions.externalMemoryFd },
{ "VK_EXT_external_memory_dma_buf", true, &state.extensions.externalMemoryDmaBuf },
{ "VK_EXT_image_drm_format_modifier", true, &state.extensions.imageDrmFormatModifier },
{ "VK_EXT_queue_family_foreign", true, &state.extensions.queueFamilyForeign },
```

Nothing else changes. The availability check (`gpu_vk.c:3140`), the flag recording (`:3142`), the `enabledExtensions` sizing (`COUNTOF(extensions)` at `:3138`), and the consumption at `:3408-3409` all follow automatically. The array is function-local to `gpu_init`, so the patch is confined to that body.

Do **not** add these to the `ASSERT` block at `gpu_vk.c:3146-3148`. Those are hard requirements that abort startup; these five are optional, and a machine without them should still run lunette with the `wl_shm` path.

**Step 3: Export the flags**

Add the five booleans next to the existing feature exports at `gpu_vk.c:3323-3328`, so Rust can query what was actually enabled rather than assuming. Task 8 depends on this: `ash::Device::load` cannot fail, so the only way to know an extension is present is to ask.

**Step 4: Check the Vulkan apiVersion**

Read the `VkApplicationInfo` near `gpu_vk.c:3025` and record which `apiVersion` LÖVR requests. This determines whether `vkBindImageMemory2` and `vkGetPhysicalDeviceFormatProperties2` are core or need explicit handling, and it is a two-line check that Task 8 depends on. Record the answer in a comment in the Rust import module.

**Step 5: Verify operationally**

Rebuild and run with LÖVR's Vulkan logging enabled. Expected: the five extensions appear in the enabled device extension list on a Mesa system. On a driver lacking them, expected: startup still succeeds and the flags read false.

**Step 6: Commit**

```bash
git -C vendor/lovr add src/core/gpu_vk.c
git -C vendor/lovr commit -m "gpu/vk: enable external memory and DRM format modifier extensions when available"
git add vendor/lovr
git commit -m "build: bump vendor/lovr for external memory extensions"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: LÖVR patch — foreign textures and the import barrier

**Verifies:** None directly; enables `lunette-v1.AC1.2`.

**Files:**
- Modify: `vendor/lovr/src/modules/graphics/graphics.h`
- Modify: `vendor/lovr/src/modules/graphics/graphics.c`
- Modify: `vendor/lovr/src/core/gpu.h`
- Modify: `vendor/lovr/src/core/gpu_vk.c`

This is the patch that makes foreign image import safe, and it is the one carrying the most unknowns. Keep it additive: a new field and two new functions, with no behavioural change to any existing path.

**Step 1: Add the `foreign` flag**

Add `bool foreign;` to `TextureInfo` (`graphics.h:223-238`), and the matching field to `gpu_texture_info` in `gpu.h`. Copy it through alongside `.handle = info->handle` at `graphics.c:2603`.

**Step 2: Suppress the discarding transition**

At `graphics.c:2635`, guard the `gpu_texture_upload` call so it is skipped when `info->foreign` is set. That call is what queues the zero-copy upload whose `copyCount == 0` branch (`gpu_vk.c:3779-3793`) records `oldLayout = VK_IMAGE_LAYOUT_UNDEFINED` over the whole image, permitting the driver to discard a client's rendered content.

The guard must key on `foreign`, not on `handle`. XR swapchain textures also use `handle` (`headset.c:3493-3503`), and they *want* that initial transition, since the runtime hands them back in an undefined layout each acquire. Keying on `handle` would break the headset path.

**Step 3: Add `gpu_import_acquire` and `gpu_import_release`**

Model them on `gpu_xr_acquire`/`gpu_xr_release` (`gpu_vk.c:2900-2939`) — a single `vkCmdPipelineBarrier2KHR` with one `VkImageMemoryBarrier2KHR` over `VK_REMAINING_MIP_LEVELS` and `VK_REMAINING_ARRAY_LAYERS`.

Two differences from the XR versions, both deliberate:

- Take the old layout as an explicit parameter rather than assuming `VK_IMAGE_LAYOUT_ATTACHMENT_OPTIMAL_KHR`. An imported dmabuf's layout is whatever the importer created it with.
- Set `srcQueueFamilyIndex` and `dstQueueFamilyIndex` **explicitly**. The XR functions leave both implicitly 0 through C designated-initialiser zeroing, which is benign only because source equals destination. Acquire takes an explicit source family, so the caller can pass either `VK_QUEUE_FAMILY_FOREIGN_EXT` or `VK_QUEUE_FAMILY_IGNORED`; release takes the destination family symmetrically.

Making the family a parameter rather than hard-coding one is what lets Task 16 measure which value actually works, which is the point of the milestone.

**Step 4: Add the `graphics.c` wrapper**

`gpu_import_acquire` needs a `gpu_stream*`, and `state.stream` is not exported — there is no `lovrGraphicsGetStream`. Add a wrapper in `graphics.c` that takes `state.lock` and passes `state.stream`, mirroring how `lovrTextureCopy` does it at `graphics.c:2972-2981`. Declare it in `graphics.h`.

This wrapper is the only genuinely new export. The blit itself needs no patch: `lovrTextureCopy` (`graphics.h:258`) and `lovrTextureBlit` (`:259`) are already public, already lock, already record into `state.stream`, and already emit `syncStream` barriers. Both require `TEXTURE_TRANSFER` on source and destination (`graphics.c:2967-2968`).

**Step 5: Verify operationally**

Build LÖVR and run an existing LÖVR sample, including one using composition layers. Expected: unchanged behaviour, confirming the patch is additive. The `foreign` path has no exercise until Task 10.

**Step 6: Commit**

Two commits in `vendor/lovr`, each shaped as an upstream pull request per the fork discipline: one adding `TextureInfo.foreign`, one adding the import barrier functions and their wrapper.

```bash
git add vendor/lovr
git commit -m "build: bump vendor/lovr for foreign texture import"
```
<!-- END_TASK_3 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_TASK_4 -->
### Task 4: The compositor thread and its protocol

**Verifies:** `lunette-v1.AC7.1`.

**Files:**
- Create: `crates/lunette-compositor/src/protocol.rs`
- Create: `crates/lunette-compositor/src/thread.rs`
- Modify: `crates/lunette-compositor/src/lib.rs`, `Cargo.toml`

**Step 1: Declare the protocol types**

`Command`, `Event`, and `Snapshot` as the design specifies. Newtypes for every identifier — `WindowId`, `SurfaceId`, `SeatId`, `SinkId`, `OutputId` — never bare integers. `ToplevelStates`, `ModifierState`, and `Stream` are enums, not strings.

Phase 2 handles `Spawn`, `CloseWindow`, `ConfigureWindow`, `Pointer`, and `Button` on the command side, and `WindowOpened`, `WindowClosed`, `TitleChanged`, `SurfaceDamaged`, `BufferImported`, `ProcessExited`, and `ProcessOutput` on the event side. Declare the full set now — the variants cost nothing and the shape is settled — but note in the module documentation which are unhandled until later phases, so a reader is not misled into thinking they work.

Task 12 dispatches the events to Lua and Task 13 handles the two window-control commands. A declared variant with no handler is a promise the API does not keep, so anything left unhandled here must be named as such.

`ImportedImage` is declared here but carries no `ash` or Vulkan type. `lunette-compositor` must not gain a GPU dependency; the raw handle crosses as an opaque integer with its dimensions and format, and the main thread reconstitutes it.

**Step 2: Write the thread entry point**

`calloop::EventLoop` is not `Send`, so the compositor is constructed **inside** the spawned closure. The function takes the Vulkan handles, the channel endpoints, and the `ArcSwap`, and returns a join handle.

Structure per smithay's own documented shape (`smithay-0.7.0/src/wayland/socket.rs:9-44`): a loop-data struct owning both `Display` and the compositor state, because the dispatch callback needs both and cannot borrow them separately. `ListeningSocketSource` for client accept, a `calloop::generic::Generic` over `display.backend().poll_fd()` for protocol traffic, and a `calloop::channel` for commands. `flush_clients()` after every dispatch batch.

The compositor thread never touches the GPU queue and never submits work. It creates images and hands them up.

**Step 3: Publish snapshots**

One `ArcSwap` store per tick, with a monotonically increasing `generation`. Lua reads the latest at frame start. No lock is held across a frame.

**Step 4: Panic policy**

A compositor-thread panic aborts the process. A half-dead compositor holding a Wayland socket is worse than a clean exit, and the design records this in its Additional Considerations. Without it the thread dies silently and the main thread reads a frozen snapshot for ever.

**Install the hook from the binary, not from this crate.** `std::panic::set_hook` is process-global, and a library that installs one hijacks the behaviour of every consumer, including the test harness. This crate exposes the policy — an abort-on-panic wrapper around the thread body, or a hook function the binary installs — and `crates/lunette/src/main.rs` decides to use it.

Same boundary as the environment variable in Task 7: the policy belongs here, the process-global mutation belongs in the entry point.

**Step 5: Test**

Unit tests for the snapshot protocol: generation increases monotonically; a command sent while the channel is full applies backpressure rather than being dropped. No socket, no client, no GPU.

**Verification:** `cargo test -p lunette-compositor`

**Step 6: Commit**

```bash
git add crates/lunette-compositor/
git commit -m "feat(compositor): add the thread protocol and event loop"
```
<!-- END_TASK_4 -->

<!-- START_SUBCOMPONENT_B (tasks 5-7) -->
<!-- START_TASK_5 -->
### Task 5: Port `comp.rs` and the required `mod.rs` fragments

**Verifies:** `lunette-v1.AC9.3` (provenance headers).

**Files:**
- Create: `crates/lunette-compositor/src/state.rs` (from `comp.rs`)
- Create: `crates/lunette-compositor/src/surface.rs` (from the `mod.rs` surface fragments)

**Step 1: Port the `mod.rs` fragments first**

`comp.rs` does not compile without them. Port `WaylandEnv` (`mod.rs:95`), `ProcessWayVREnv` (`:111`), `ExternalProcessRequest` (`:117`), `MouseIndex` (`:154`), and the surface-buffer types (`:1351-1391`).

`WayVRTask` (`mod.rs:125`) becomes an `Event` variant on the real channel from Task 4, replacing `SyncEventQueue` entirely. `WAYVR_SCREEN_RES` (`:172`) is a fixed constant in WayVR; lunette's outputs are configurable from Phase 8, so make it a field with a default rather than a constant.

**Step 2: Preserve the buffer-release rule**

`SurfaceBufWithImageContainer` carries `retained_dmabuf_buffer: RefCell<Option<WlBuffer>>` (`mod.rs:1353`). The rule is: hold the current dmabuf's `WlBuffer`, and release the previous one — `apply_to_surface` returns the previous buffer, and `comp.rs:255-258` releases it.

Images move to the event channel, but this ownership rule must survive the move. Without it, clients recycle buffers underneath lunette and render tearing or garbage. Keep the retention in compositor state, keyed by surface, with the `RefCell` replaced by ordinary ownership since the compositor thread is the only writer.

**Step 3: Port `comp.rs`**

The `Application` state struct (`comp.rs:68-94`) and its handler impls. `CompositorHandler`'s commit path (`:229-322`) is the important one.

Port popup tracking as it stands: `PopupManager` is a field (`comp.rs:87`), `popups_commit` runs on every commit (`:111`, `:229`), and `constrain_popup`/`new_popup`/`popup_destroyed`/`grab`/`reposition_request` (`:193-522`) come with it. Popup *routing* is Phase 5; tracking is not separable.

**Do not port** the single-pixel-buffer path — `comp.rs:285-304`, `delegate_single_pixel_buffer!` at `:693`, and the corresponding importer function. `SinglePixelBufferState` is never constructed anywhere in WayVR, so this is dead code.

**Do not port** the `with_fractional_scale` calls at `comp.rs:125` and `:145`. They are thread-affine, they write to surface user data no client can read (WayVR never advertises `wp_fractional_scale_v1`), and Phase 8 implements fractional scale properly. Leave a comment recording that Phase 8 owns it.

**Step 4: Create the globals**

Eight: `wl_compositor`, `wl_subcompositor` (created unconditionally by `CompositorState::new`, not optional), `xdg_wm_base`, `wl_shm`, `zwp_linux_dmabuf_v1`, `wl_seat`, `wl_output`, `wp_viewporter` (a hard requirement of xwayland-satellite), plus `zxdg_decoration_manager_v1` and `org_kde_kwin_server_decoration_manager` with server-side forced, as WayVR does at `comp.rs:638-677`.

Use the feedback variant of the dmabuf global (`create_global_with_default_feedback`) so clients get version 4 and can negotiate modifiers. `DmabufFeedbackBuilder::new` takes a `libc::dev_t`, so the DRM render node's `st_rdev` is required — there is no way to build feedback without it. WayVR obtains it from `VkPhysicalDeviceDrmPropertiesEXT` (`graphics/mod.rs:132-140`, `mod.rs:228-231`); lunette queries the same property through `ash` in Task 8 and passes it in.

**Step 5: Provenance headers**

Every file carries the header form from Task 1, naming the upstream path and commit.

**Step 6: Test**

Socketpair harness: `UnixStream::pair()`, one end to `DisplayHandle::insert_client`, the other to the test client. No listening socket, no filesystem, no environment.

Cover: a client connects and sees the expected globals; a toplevel commit produces a `WindowOpened` event; a title change produces `TitleChanged`.

**Verification:** `cargo test -p lunette-compositor`

**Step 7: Commit**

```bash
git add crates/lunette-compositor/src/
git commit -m "feat(compositor): port the smithay state and handlers from WayVR"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: Port `window.rs`, `time.rs`, and `process.rs`

**Verifies:** `lunette-v1.AC1.3`, `lunette-v1.AC1.4`.

**Files:**
- Create: `crates/lunette-compositor/src/window.rs`
- Create: `crates/lunette-compositor/src/process.rs`

**Step 1: Port `window.rs`**

Geometry bookkeeping: `Window`, `MouseState`, `WindowManager`, `WindowHandle`. Drop the `wayvr_ipc` packet conversions at `window.rs:164-174` — lunette's control surface is `lunctl` in Phase 7, not that protocol.

The `Rc<ToplevelSurface>` at `window.rs:19` becomes plain `ToplevelSurface`. `ToplevelSurface` is itself `Clone` and cheap, so the wrapper buys nothing; `Arc` would work equally but adds an indirection for no reason.

**Step 2: Fold in `time.rs`**

Nine lines and one function. `time.rs:7` uses `.unwrap()`, which is banned in production code. Use a monotonic `Instant` baseline captured at compositor start rather than a fallible wall-clock conversion — this is also more correct, since Wayland frame timestamps must be monotonic.

Do not create a `time.rs`; a single function does not earn a file. Put it next to its only caller.

**Step 3: Port `process.rs`, with the lifetime fixes**

WayVR signals only the direct child (`process.rs:132`, `:166`). Grep across `wayvr/src` for `setsid`, `PDEATHSIG`, `process_group`, `pre_exec`, and `killpg` returns zero hits, confirming it. A shell wrapper's grandchildren survive.

lunette spawns with `setsid`, signals by process group, and sets `PR_SET_PDEATHSIG` as a backstop, all through `pre_exec`. Since `pre_exec` runs between fork and exec, only async-signal-safe calls are permitted there — `setsid` and `prctl` qualify.

**Step 4: Client attribution**

Copy WayVR's mechanism (`mod.rs:1346-1349` generates, `:1334` exports, `client.rs:67-90` and `process.rs:182-217` match), with three corrections:

- Generate a CSPRNG token, not a v4 UUID.
- Read `/proc/<pid>/environ` as **bytes**. WayVR's `read_to_string` (`client.rs:70`, `process.rs:102`) fails outright on a non-UTF-8 environment, which is legal on Linux.
- Compare in constant time. The key is what attributes a window to a process.

The two-stage lookup is right and should be kept: match the connecting pid first, then fall back to the auth key from `/proc/<pid>/environ`. Under flatpak or a shell wrapper the connecting pid is usually not the spawned child, which is the whole reason the mechanism exists.

Copy WayVR's toolkit-hint environment set wholesale (`mod.rs:1334-1340`): `GDK_BACKEND`, `QT_QPA_PLATFORM`, `SDL_VIDEODRIVER`, `CLUTTER_BACKEND`, `MOZ_ENABLE_WAYLAND`, `ELECTRON_OZONE_PLATFORM_HINT`. Also copy the flatpak detection at `mod.rs:1252-1253`, which passes environment through `--env=` flags after `run` rather than as process environment.

**Step 5: Test**

`ProcessSpawner` as a seam trait with a production implementation and a test fake, per the house rule that subprocesses are routed through a seam. Tests use the fake and assert on what would have been spawned. Cover: spawning a non-existent executable produces a failure event and no window (AC1.4); a connection whose auth key matches an unknown key is reported external (AC1.3).

**Verification:** `cargo test -p lunette-compositor`

**Step 6: Commit**

```bash
git add crates/lunette-compositor/src/
git commit -m "feat(compositor): port window and process management from WayVR"
```
<!-- END_TASK_6 -->

<!-- START_TASK_7 -->
### Task 7: Port `client.rs` and spawn xwayland-satellite

**Verifies:** `lunette-v1.AC1.1`.

**Files:**
- Create: `crates/lunette-compositor/src/client.rs`

**Step 1: Port the socket and accept path**

`create_wayland_listener` (`client.rs:423`) and `accept_connection` (`:147`). lunette uses `ListeningSocketSource` under calloop rather than WayVR's per-tick non-blocking poll, since the compositor has its own thread and can block.

**Step 2: Return the display name; do not export it here**

WayVR does not export it — it only writes the display number to `$XDG_RUNTIME_DIR/wayvr.disp` (`client.rs:415-421`) for external tooling. The design requires lunette to export `WAYLAND_DISPLAY` into its own environment, so a process started outside lunette can find the socket (AC1.3).

**That export does not happen in this crate.** Two reasons, and the second is the hard one:

- `CONTRIBUTING.md:110` reserves environment access to the application entry point. A library that writes the environment cannot be tested without manipulating it.
- In Rust 2024 `std::env::set_var` is `unsafe`, and it is **unsound once any other thread exists**. By the time the compositor thread starts, LÖVR and GLFW have already booted and spawned threads — Phase 2's own startup ordering requires it, since the compositor needs the `VkDevice`. So "before any other thread could be reading" is not a condition lunette can satisfy here.

The socket setup returns the display name. The binary exports it, from `main` before any thread is spawned, and passes it to the compositor thread as a parameter. Task 4's thread entry point takes it alongside the Vulkan handles.

Record the reasoning at both sites. Setting an environment variable next to the code that creates the socket is the obvious thing to do, and it is wrong here for a reason that is invisible locally.

**Step 3: Spawn xwayland-satellite**

Best-effort, once at startup, matching `client.rs:101-108`: positional X display number, `WAYLAND_DISPLAY` in its environment, failure logged as a warning and construction continues. Kill and reap on drop, as `client.rs:55-65` does.

Satellite requires `wp_viewporter` from the compositor, which Task 5 advertises. It also needs `wl_compositor`, `wl_surface`, `wl_output`, and `xdg_shell`, all present.

Resolve the executable as WayVR does (`client.rs:472-478`): `$APPDIR/usr/bin/<name>` when `APPDIR` is set, else from `PATH`.

**Step 4: Test**

Socketpair harness again. Cover AC1.1: a client connects and its toplevel appears in the snapshot on the tick after it maps. Satellite is behind the `ProcessSpawner` seam, so tests assert it was requested without spawning anything.

**Verification:** `cargo test -p lunette-compositor`

**Step 5: Commit**

```bash
git add crates/lunette-compositor/src/client.rs
git commit -m "feat(compositor): port the client socket and spawn xwayland-satellite"
```
<!-- END_TASK_7 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_SUBCOMPONENT_C (tasks 8-10) -->
<!-- START_TASK_8 -->
### Task 8: dmabuf import with `ash`

**Verifies:** `lunette-v1.AC1.2`.

**Files:**
- Create: `crates/lunette/src/import/mod.rs`, `device.rs`, `dmabuf.rs`, `formats.rs`

This lives in `crates/lunette`, not `crates/lunette-compositor`. The compositor crate must not gain a GPU dependency — that separation is what keeps the test suite runnable without a GPU (AC9.4), and it is stated in `docs/dev/architecture.md:77` and `CONTRIBUTING.md:32`.

**Step 1: Wrap LÖVR's handles**

`ash::Instance::load(entry.static_fn(), raw_instance)` then `ash::Device::load(instance.fp_v1_0(), raw_device)`.

**`load` cannot fail.** A missing entry point becomes a stub that panics when called. So before anything else, query LÖVR's `apiVersion` and the extension flags exported in Task 2, and return a structured error naming exactly which extension is missing. Discovering the mismatch as a panic mid-frame is not acceptable, and there is no `load_checked` for `Device` or `Instance`.

`ash::Device` and `ash::Instance` have no `Drop`. Never call `destroy_device` or `destroy_instance` — lunette borrows both.

Load `ash::khr::external_memory_fd::Device` and `ash::ext::image_drm_format_modifier::Device`. There is no loader for `VK_KHR_external_memory` or `VK_EXT_external_memory_dma_buf`; they contribute structs only, and their presence in the enabled list is Task 2's job.

**Step 2: Query supported formats and modifiers**

Two-call idiom on `vkGetPhysicalDeviceFormatProperties2` chained with `VkDrmFormatModifierPropertiesListEXT`: query the count with a default list, allocate, then fill. Construct the list struct literally on the second call rather than using the `.drm_format_modifier_properties(...)` builder — the builder derives the count from the slice length, and an empty `Vec` reports zero. smithay does exactly this at `src/backend/vulkan/mod.rs:546-586`; read it as a reference without enabling `backend_vulkan`.

Filter to `drm_format_modifier_plane_count == 1`, matching WayVR (`dmabuf.rs:384`). Then filter again with `vkGetPhysicalDeviceImageFormatProperties2` chained with `VkPhysicalDeviceImageDrmFormatModifierInfoEXT` per candidate — the format-properties list says a modifier exists, not that it works with the intended usage and tiling.

Add an unconditional `DrmModifier::Invalid` entry per format for implicit modifiers, as WayVR does at `dmabuf.rs:393-397`. That entry is load-bearing and easy to miss.

Cover the six fourccs WayVR covers, verified verbatim at `dmabuf.rs:406-413`: `Abgr8888` and `Xbgr8888` to `R8G8B8A8_UNORM`; `Argb8888` and `Xrgb8888` to `B8G8R8A8_UNORM`; `Abgr2101010` and `Xbgr2101010` to `A2B10G10R10_UNORM_PACK32`. Record the X-variant caveat where the mapping is defined: the X formats map to alpha Vulkan formats, so alpha must be forced to 1 downstream or the content renders with whatever is in that byte. Multi-plane YUV is a known gap, recorded in the design.

Also query `VkPhysicalDeviceDrmPropertiesEXT` here for the render node's major and minor, and turn it into a `dev_t` for Task 5's dmabuf feedback.

**Step 3: Import**

For each dmabuf:

1. **Reject disjoint buffers.** If the plane fds refer to different buffer objects, return a clear error. Handling them needs `VK_IMAGE_CREATE_DISJOINT_BIT`, one allocation per plane, and `vkBindImageMemory2` with `VkBindImagePlaneMemoryInfo`, and it is out of scope for v1.
2. **Duplicate the fd.** `Dmabuf::handles()` yields `BorrowedFd` while the `Dmabuf` retains ownership and closes on drop. `try_clone_to_owned()` first, which also sets `CLOEXEC`. Skipping this is a double-close, and it is the single most likely bug in this task.
3. `vkCreateImage` with `tiling = DRM_FORMAT_MODIFIER_EXT`, `initial_layout = UNDEFINED`, `usage = SAMPLED | TRANSFER_SRC | TRANSFER_DST`, chaining `VkExternalMemoryImageCreateInfo`, `VkImageDrmFormatModifierExplicitCreateInfoEXT`, and `VkImageFormatListCreateInfo`. Use the explicit variant, not the list variant — the client's modifier is known, and the list variant makes the driver choose and then requires reading it back. In `SubresourceLayout`, only `offset` and `row_pitch` are read; `size`, `array_pitch`, and `depth_pitch` must be zero. smithay's offsets and strides are `u32`, so widen them.
4. `vkGetImageMemoryRequirements2` with `VkMemoryDedicatedRequirements` chained.
5. **`vkGetMemoryFdPropertiesKHR`**, and intersect its `memory_type_bits` with the requirements'. VUID-VkMemoryAllocateInfo-memoryTypeIndex-00648 requires the index come from this call for any fd created outside Vulkan, which a client dmabuf is. WayVR's vulkano path omits it. This call takes a borrowed fd and does not consume it, so make it before the duplication is handed over.
6. `vkAllocateMemory` chaining `VkMemoryDedicatedAllocateInfo` and `VkImportMemoryFdInfoKHR`.
7. `vkBindImageMemory2` at offset 0.

**fd ownership.** On `VK_SUCCESS` the implementation owns the fd and it must not be closed. On any error the caller still owns it and must close it. Encode this so it cannot be got wrong: hold an `OwnedFd`, call `into_raw_fd()` only when building the import struct, and on the error branch reconstruct with `OwnedFd::from_raw_fd` and drop. The specification states the success transfer explicitly (`chapters/memory.adoc:2637`) and leaves the failure case to inference, so the conservative encoding is the correct one.

**Step 4: Cache**

Key on the dmabuf, so a surface rotating among its buffers imports each once rather than per frame. This is also what makes the `UNDEFINED` transition in Task 3 a once-per-buffer concern rather than a per-frame one.

**Step 5: Test**

The Vulkan calls need a device, so they are not unit-testable without a GPU. What is testable without one, and must be: the fourcc-to-format mapping, the modifier filtering, disjoint detection, and the fd ownership state machine. Structure the module so those are pure functions over plain data, with the Vulkan calls in a thin shell — that is the functional-core rule, and here it is also the only way to get coverage.

**Verification:** `cargo test -p lunette`

**Step 6: Commit**

```bash
git add crates/lunette/src/import/
git commit -m "feat: import client dmabufs as vulkan images"
```
<!-- END_TASK_8 -->

<!-- START_TASK_9 -->
### Task 9: The `wl_shm` fallback

**Verifies:** `lunette-v1.AC1.6`.

**Files:**
- Create: `crates/lunette/src/import/shm.rs`

**Step 1: Port the path**

Model on `image_importer.rs:50-100`. Validate `stride >= width * bpp` and `size >= stride * height`, then copy row by row into a tightly packed buffer to strip stride padding, and upload into a LÖVR-owned texture.

WayVR restricts this path to 4-byte RGBA and BGRA, `UNORM` and `SRGB` (`image_importer.rs:66-72`), rejecting the 10-bit formats it accepts for dmabuf. Keep that restriction and say why in a comment: `wl_shm`'s mandatory formats are `Argb8888` and `Xrgb8888`, and anything beyond that is a client opting in.

WayVR's version does a synchronous blocking submit (`image_importer.rs:96-97`, with its own `//TODO: async`). lunette must not block the frame thread this way. Upload through LÖVR's existing texture-upload path instead, which is already batched into `state.stream`.

The `wl_buffer` is released immediately after the copy, so no retention is needed — unlike the dmabuf path.

`ShmState::new` takes an extra-formats list; pass an empty one, as WayVR does at `mod.rs:185`, so only the mandatory formats are advertised.

**Step 2: Test**

Stride handling, padding removal, and the validation rejections are pure functions over byte slices. Test them directly, including the degenerate cases: zero-size, one-pixel, and a stride exactly equal to the row width.

**Verification:** `cargo test -p lunette`

**Step 3: Commit**

```bash
git add crates/lunette/src/import/shm.rs
git commit -m "feat: add the wl_shm import fallback"
```
<!-- END_TASK_9 -->

<!-- START_TASK_10 -->
### Task 10: Texture handoff

**Verifies:** `lunette-v1.AC1.2`, `lunette-v1.AC1.5`.

**Files:**
- Create: `crates/lunette/src/texture.rs`

**Step 1: Wrap the image**

The `VkImage` travels up the event channel as `Event::BufferImported`. On the main thread, call `lovrTextureCreate` with:

- `type = TEXTURE_2D`, `layers = 1`, `mipmaps = 1`, `samples = 1`
- `format` from the fourcc mapping, `srgb = false`
- `usage = TEXTURE_SAMPLE | TEXTURE_TRANSFER` — this makes `getNaturalLayout` return `VK_IMAGE_LAYOUT_GENERAL` (the easiest layout to hand LÖVR), gives the texture a real `Sync` object rather than the global-barrier exemption at `graphics.c:2647-2657`, and is required for `lovrTextureCopy` in Phase 3
- `xr = false`
- `foreign = true` — the Task 3 flag, suppressing the discarding transition
- `handle` = the imported `VkImage`

The imported image must have been created with usage matching this declaration, or `vkCreateImageView` fails inside `gpu_texture_init_view`. Task 8 creates it with `SAMPLED | TRANSFER_SRC | TRANSFER_DST`, which matches.

**Step 2: Own the teardown**

`gpu_texture_destroy` (`gpu_vk.c:879-885`) destroys only the view and returns early because `imported` is set. lunette calls `vkDestroyImage` and `vkFreeMemory`, and must not do so until LÖVR's morgue has retired the view — that is, not before the tick that created the texture has completed. Defer destruction by at least one full tick and record why.

**Step 3: Barrier placement**

Call the Task 3 acquire wrapper before any read of the imported texture in a frame, and the release wrapper after. Pass the source queue family as a parameter so Task 16 can measure `VK_QUEUE_FAMILY_FOREIGN_EXT` against `VK_QUEUE_FAMILY_IGNORED` without a rebuild — a runtime switch is appropriate here precisely because the correct answer is unknown.

**Step 4: Per-frame texture rule**

`window:getTexture()` returns the texture for the current frame only. Textures rotate as the client cycles its buffers, so a cached handle goes stale. Enforce it rather than documenting it: return a handle that checks the frame generation and errors if used from a later frame. The same rule applies to `Layer:getTexture()` in Phase 3, for the same reason — `lovrLayerGetTexture` (`headset.c:3323-3325`) calls `lovrSwapchainAcquire`, which rotates.

**Step 5: Dead handles**

After a client exits, the handle reports `dead == true`, reads return last-known values, and every method returns `false` without raising. This is a recorded decision in `docs/dev/decisions.md` — inert rather than raising, because a race taking down the session is worse.

**Step 6: Test**

The frame-generation check and the dead-handle semantics are pure logic and are tested without a GPU. The wrapping itself is not.

**Verification:** `cargo test -p lunette`

**Step 7: Commit**

```bash
git add crates/lunette/src/texture.rs
git commit -m "feat: wrap imported images as lovr textures"
```
<!-- END_TASK_10 -->
<!-- END_SUBCOMPONENT_C -->

<!-- START_TASK_11 -->
### Task 11: The Lua module

**Verifies:** `lunette-v1.AC1.1`, `lunette-v1.AC1.5`.

**Files:**
- Create: `crates/lunette/src/lua/mod.rs`, `window.rs`, `sink.rs`

**Step 1: Register the module**

Install through mlua's `Lua::get_or_init_from_ptr` on LÖVR's state, before `boot.lua` runs, so `require('lunette')` resolves. This is `lunette`, the native mechanism root; `mullion` is Phase 6 and is policy in Lua.

**Step 2: The surface**

Phase 2 exposes `lunette.spawn`, `lunette.windows`, `Window:getTexture`, `Sink:pointer`, and `Sink:button`. `lunette.windows()` reads the latest snapshot; mutations queue during Lua callbacks and flush once at frame end.

A window handle also exposes its **pixel dimensions**, `win.width` and `win.height`. These are not in the design's component list and are not currently documented anywhere in `docs/dev/`, but Phase 6's panels cannot convert a ray hit to pixel coordinates without them, and `CONTRIBUTING.md:62` forbids mullion reaching past the public API. Document them in `docs/dev/lua-api.md` alongside `win.title` and `win.appId` in this task, since that file is normative.

Rust holds no long-lived reference into Lua. That is a design prohibition, and it is what makes the soft reload in Phase 7 possible.

**Step 3: Errors**

Raise normally. Callbacks run under `xpcall` and the handler reports. Do not swallow errors to keep a frame alive.

**Step 4: Test**

The snapshot-to-Lua conversion is testable with a Lua state and no GPU: a snapshot containing two windows produces two entries with the expected fields; a dead handle's methods return `false` and do not raise.

**Verification:** `cargo test -p lunette`

**Step 5: Commit**

```bash
git add crates/lunette/src/lua/
git commit -m "feat: expose the lunette lua module"
```
<!-- END_TASK_11 -->

<!-- START_TASK_12 -->
### Task 12: Dispatch compositor events to Lua

**Verifies:** `lunette-v1.AC1.1`, `lunette-v1.AC1.4`, `lunette-v1.AC1.5`.

**Files:**
- Create: `crates/lunette/src/events.rs`
- Modify: `crates/lunette/src/lua/mod.rs`

Task 4 declares the `Event` variants and Task 11 exposes the handles, but nothing yet turns a compositor event into a Lua callback. Without this, `docs/dev/lua-api.md:29-34` specifies nine `lun*` events and lunette delivers none of them — and Phase 6's rules, which hook window-opened to place a newly spawned application (AC5.2), have nothing to hook.

**Step 1: The events this phase owns**

Six of the nine, all normatively specified at `docs/dev/lua-api.md:29-34`:

- `lunwindowopened`, `lunwindowclosed`, `luntitlechanged` — from the compositor's window lifecycle.
- `lunprocessexited`, `lunprocessoutput` — from Task 6's process management. `lunprocessexited` is how a spawn failure reaches Lua (AC1.4).
- `lunmonitoradded` — declared here so the shape is uniform, fired for real once Phase 4 has monitors to add.

The remaining three arrive later: `lunlayergranted` and `lunlayerrevoked` in Phase 3 Task 6, and `lunerror` in Phase 7 Task 9.

**Step 2: The delivery mechanism**

Build a `CustomEvent` and call `lovrEventPush`, as `l_event.c:162-179` does from Lua. `lovrEventPush` is thread-safe, so the compositor thread could push directly — but do not. Events are drained from the event channel at frame start alongside the snapshot, so an event and the snapshot a handler reads describe the same frame. Pushing out of band would let a handler observe an event for a window not yet in the snapshot.

`boot.lua:345` sets `lovr.handlers = setmetatable({}, { __index = lovr })`, so pushing `'lunwindowopened'` calls `lovr.lunwindowopened` with no new machinery and no patch.

**Step 3: Two limits on every `lun*` event**

- **Names cap at 31 characters plus a NUL** — `CustomEvent.name` is `char name[32]` (`event.h:102-106`). Every name planned fits; the limit is recorded here because it applies to all nine and a longer name would be silently truncated.
- **Only four payload arguments reach the handler** (`boot.lua:193`, dispatched at `:198`). `docs/dev/lua-api.md:42` states the consequence: richer payloads travel as a single table. Use a table for every `lun*` event, even one-argument ones, so the shape is uniform across phases and adding a field later is not a breaking change.

`'quit'` and `'restart'` are intercepted before dispatch and are reserved.

**Step 4: Errors in handlers**

Handlers run under `xpcall`, and an error is reported without preventing delivery of the remaining events for that frame. The full error machinery is Phase 7 Task 9; this task must not let one bad handler swallow a frame's worth of events.

**Step 5: Test**

Cover: a window opening delivers `lunwindowopened` with the window in the payload table; the window is present in the snapshot the handler reads; a title change delivers `luntitlechanged`; a client disconnecting delivers `lunwindowclosed` and the handle is dead by the time the handler runs; a failed spawn delivers `lunprocessexited` and creates no window (AC1.4); an event name at the 31-character limit round-trips; a handler raising does not prevent later events in the same frame.

**Verification:** `cargo test -p lunette`

**Step 6: Commit**

```bash
git add crates/lunette/src/events.rs crates/lunette/src/lua/mod.rs
git commit -m "feat: deliver compositor events to lua"
```
<!-- END_TASK_12 -->

<!-- START_TASK_13 -->
### Task 13: Window control and stable textures

**Verifies:** `lunette-v1.AC1.5`.

**Files:**
- Modify: `crates/lunette/src/lua/window.rs`, `src/texture.rs`

Three pieces of documented surface that Task 4 declares in the protocol or that `docs/dev/` specifies, and that nothing else in the plan builds.

**Step 1: `win:close()` and `win:resize(w, h)`**

Both are specified at `docs/dev/lua-api.md:54-55`. Task 4 declares the matching `Command::CloseWindow` and `Command::ConfigureWindow` variants and notes them as unhandled — this is where they become handled.

`win:close()` sends the xdg-toplevel close request. It is a request, not a kill: a client may ignore it or show a save prompt. Say so, because a Lua author will expect the window to disappear.

`win:resize(w, h)` configures the toplevel. The client resizes at its own pace and the change is visible when it commits, so nothing here waits.

Both follow the dead-handle rule: after the client exits they return `false` without raising.

**Step 2: `surface:stabilize()`**

`docs/dev/rendering.md:23` gives it a section and `CONTRIBUTING.md:67` instructs its use — "Use `surface:stabilize()` when a persistent texture is genuinely wanted" — so a Lua author following the house rules will call it. Phase 6's panel implementation does.

It allocates a lunette-owned texture and copies the imported buffer into it each frame the source is damaged, returning a texture whose identity is stable across frames. That is the opt-in against the zero-copy default, which `docs/dev/decisions.md` records as a deliberate trade: zero-copy is cheaper and matches what other compositors do, with the stabilising copy available when a caller genuinely needs a persistent handle.

Use `lovrTextureCopy` (`graphics.h:258`) — already public, already taking `state.lock`, already emitting `syncStream` barriers. Phase 3 Task 7 reuses the same call for its layer blits, so there is one copy mechanism in the codebase rather than two.

Charge the cost honestly in the documentation: a stabilised surface pays a full copy per damaged frame, which is exactly why it is not the default.

**Step 3: Test**

Cover: `win:close()` sends the close request and does not remove the window itself; `win:resize` configures and the snapshot reflects the client's committed size, not the requested one; a stabilised texture keeps the same identity across frames while the underlying buffer rotates; stabilising twice returns the same texture rather than allocating again; every method returns `false` on a dead handle without raising.

**Verification:** `cargo test -p lunette`

**Step 4: Commit**

```bash
git add crates/lunette/src/lua/window.rs crates/lunette/src/texture.rs
git commit -m "feat: add window control and stable textures"
```
<!-- END_TASK_13 -->

<!-- START_TASK_14 -->
### Task 14: Overlay session

**Verifies:** `lunette-v1.AC6.1`, `lunette-v1.AC6.2`, `lunette-v1.AC2.1`.

**Files:**
- Modify: `etc/xdg/lunette/conf.lua`
- Modify: `etc/xdg/lunette/main.lua`

**Step 1: Request the overlay session**

Set `t.headset.overlay` in `lovr.conf`. `headset.c:509` requests `XR_EXTX_overlay` when it is set, and `headset.c:1032-1041` chains `XrSessionCreateInfoOverlayEXTX` into session creation. `t.headset.overlayOrder` maps to `sessionLayersPlacement` and is available if ordering needs control.

No patch is required for either.

**Step 2: Transparency**

`headset.c:3067-3071` sets `XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT` on the projection layer whenever `state.extensions.overlay` is true — the extension being *enabled*, not the session actually being an overlay. So requesting overlay is sufficient for AC6.2, and areas Lua does not draw stay transparent.

**Step 3: Draw a window on a quad**

`main.lua` takes the first window from `lunette.windows()`, gets its texture, and draws it on a quad at a fixed pose. This is AC2.1, and it is also the visible proof that the whole import path works.

**Step 4: Verify**

These require a headset and an XR runtime, so they are human-verified, not automated. Recorded as such in `test-requirements.md`, which sits alongside these phase files in `docs/dev/implementation-plans/2026-08-05-lunette-v1/` and is produced by the planning process, not by any phase.

- Run under Monado with another OpenXR application holding the primary session. Expected: lunette runs alongside it rather than failing to create a session.
- Expected: lunette's content composites over the other application, and undrawn areas are transparent.

**Step 5: Commit**

```bash
git add etc/xdg/lunette/
git commit -m "feat: run as an openxr overlay"
```
<!-- END_TASK_14 -->

<!-- START_TASK_15 -->
### Task 15: Logic-headless tests

**Verifies:** `lunette-v1.AC9.4`.

**Files:**
- Create: `crates/lunette-compositor/tests/harness/mod.rs`
- Create: `crates/lunette-compositor/tests/client_lifecycle.rs`
- Create: `crates/lunette-compositor/tests/pointer_routing.rs`
- Modify: `crates/lunette-compositor/Cargo.toml` (`[dev-dependencies]`)

**Step 1: The harness**

`UnixStream::pair()`; one end to `DisplayHandle::insert_client(stream, Arc::new(ClientState::default()))`, the other to `wayland_client::Connection::from_socket(stream)`. No listening socket, no filesystem path, no `XDG_RUNTIME_DIR`, no environment access. This is what makes the tests hermetic and keeps them inside `CONTRIBUTING.md:299` as amended in Phase 1 Task 10.

**`Connection::connect_to_env()` must never be used.** It calls `env::remove_var("WAYLAND_SOCKET")` at `conn.rs:52`, mutating the process environment, which is unsound in a multithreaded test binary. `from_socket` is the only form.

Drive with `event_queue.blocking_dispatch(&mut state)` in a loop with a deadline. Poll for the expected state; never sleep. A fixed sleep passes locally and fails in CI, and nothing here is a timing test.

**Step 2: The test client**

smithay-client-toolkit 0.21.1 with `default-features = false`, which drops `calloop`, `xkbcommon`, and `bytemuck`. Bind `wl_compositor`, `xdg_wm_base`, and `wl_shm`; create a toplevel; then **commit with no buffer first**, wait for `xdg_surface.configure`, and only then attach a buffer and commit. Attaching before the first configure is a protocol error, and getting this order wrong is the usual way these tests fail confusingly.

Required impls: `CompositorHandler`, `OutputHandler`, `WindowHandler`, `ShmHandler`, `ProvidesRegistryState`, each with its `delegate_*!`.

**Step 3: The tests**

- A client connects and sees the eight globals.
- A toplevel appears in the snapshot on the tick after it maps (AC1.1).
- A title change produces `TitleChanged`.
- A client disconnect produces `WindowClosed` and the handle goes dead (AC1.5).
- A pointer event at a given position routes to the expected surface in surface-local coordinates.
- A `wl_shm` commit produces a usable buffer through the validation path (AC1.6, to the extent testable without a GPU).

Import is stubbed behind a trait, per the design's own phrasing for this gate. That stub is the seam that keeps the suite GPU-free.

**Step 4: Verify**

Run: `cargo test -p lunette-compositor`
Expected: passes with no GPU, no XR runtime, and no headset attached (AC9.4).

Confirm it explicitly by running with no Vulkan ICD visible. If any test needs a GPU, it is in the wrong crate.

**Step 5: Commit**

```bash
git add crates/lunette-compositor/tests/
git commit -m "test: add logic-headless compositor tests"
```
<!-- END_TASK_15 -->

<!-- START_TASK_16 -->
### Task 16: Check suite and the milestone gate

**Verifies:** All Phase 2 criteria, observationally.

**Files:**
- Create: `docs/dev/2026-08-06-milestone-0-findings.md`

**Step 1: Run the check suite**

All five commands from `CONTRIBUTING.md:171-175`, inside `nix develop`.

**Step 2: Confirm provenance**

Run: `rg -L 'Ported from WayVR' crates/lunette-compositor/src/`
Expected: no output. Every file in that crate is either ported and headed, or original.

Confirm `vendor/lovr` patches carry MIT headers matching upstream, and that `CREDITS.md` agrees with `docs/dev/decisions.md`'s licensing table.

**Step 3: The human gates**

Neither is automatable, and both are the actual point of the milestone.

- A terminal spawned by lunette appears on a quad in the desktop simulator and responds to a click.
- The same build runs as an overlay under Monado alongside another OpenXR application.

**Step 4: Record the findings**

This is milestone 0's real output, and phases 4 to 8 are detailed against it. Record, with evidence:

- Whether the `UNDEFINED` transition at `gpu_vk.c:3789` actually discarded content on the target driver, and whether the `foreign` flag was necessary or merely prudent.
- Whether `VK_QUEUE_FAMILY_FOREIGN_EXT` or `VK_QUEUE_FAMILY_IGNORED` worked for the acquire, and whether behaviour differed by driver.
- Whether implicit sync sufficed in practice, as the design assumes on the strength of WayVR's experience.
- Whether the snapshot model was workable in use — the second of the two unknowns this phase exists to resolve.
- Which formats and modifiers the target hardware actually advertised after both filtering passes.
- Whether any client sent a disjoint dmabuf, and how often.

An honest negative finding here is worth more than a passing gate. If the approach does not work, this is the phase that is supposed to say so.

**Step 5: Commit**

```bash
git add docs/dev/2026-08-06-milestone-0-findings.md
git commit -m "docs: record milestone 0 findings"
```
<!-- END_TASK_16 -->

---

## Done when

- Logic-headless tests in `lunette-compositor` cover client connection, toplevel creation, and pointer routing, using a smithay-client-toolkit test client over a socketpair with import stubbed, and pass with no GPU attached.
- A terminal spawned by lunette appears on a quad in the desktop simulator and responds to a click.
- The same build runs as an overlay under Monado alongside another OpenXR application, compositing over it with undrawn areas transparent.
- Every ported file carries a provenance header, `CREDITS.md` exists, and `vendor/lovr` patches are MIT.
- All five check commands pass.
- `docs/dev/2026-08-06-milestone-0-findings.md` records what the three Vulkan unknowns actually did.

## Deliberately not in this phase

- `hit_test.rs` and popup input routing — Phase 5. Popup *tracking* is unavoidable here.
- Keyboard, multi-seat, and clipboard — Phase 5.
- Composition layers and the layer pool — Phase 3.
- `wp_fractional_scale_v1`, per-client output filtering, and frame-callback throttling — Phase 8.
- Multi-plane YUV and disjoint dmabufs — recorded gaps, rejected explicitly rather than mishandled.
- Explicit sync — deferred in the design; implicit sync works on Mesa in practice.
