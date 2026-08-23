# lunette v1 Implementation Plan — Phase 3: Composition layers

**Goal:** Panels rendered as OpenXR quad layers at native resolution, degrading to in-scene quads under contention.

**Architecture:** Rust owns a pool of LÖVR `Layer` objects. The recycling unit is the whole `Layer`, not its swapchain, because LÖVR embeds the swapchain by value and destroys it inline. Revoked layers return to a free list keyed by their immutable properties; claims pop a match or create one. Lua supplies a scalar priority and Rust assigns the top N deterministically. Blits are issued through LÖVR's existing public copy API and skipped for surfaces whose commit counter has not moved.

**Tech Stack:** LÖVR layer API, OpenXR quad composition layers, smithay's `RendererSurfaceState` damage tracking.

**Scope:** Phase 3 of 8 from `docs/design-plans/2026-08-05-lunette-v1.md`.

**Codebase verified:** 2026-08-05.

---

## Acceptance criteria coverage

### lunette-v1.AC2: Panels render, on layers where possible
- **lunette-v1.AC2.2 Success:** A granted claim yields a real LÖVR `Layer`, and the panel renders through the runtime's compositor at the surface's native resolution.
- **lunette-v1.AC2.3 Failure:** When the pool is exhausted, the lowest-priority claim is revoked, `lovr.lunlayerrevoked` fires, and the panel continues rendering as an in-scene quad.
- **lunette-v1.AC2.4 Success:** A revoked swapchain is reused by the next claim of identical width, height, and format, with no new allocation.

### lunette-v1.AC7: The overlay stays cheap
- **lunette-v1.AC7.2 Success:** A surface undamaged since its last blit is not copied again.

---

## Facts established by investigation

### Swapchain recycling is impossible; Layer recycling is trivial

The design says the pool recycles swapchains by `(width, height, format)`. Against stock LÖVR it cannot.

`struct Layer` embeds its swapchain **by value** (`headset.c:182-185`):

```c
struct Layer {
  atomic_uint ref;
  LayerInfo info;
  Swapchain swapchain;
```

`lovrLayerDestroy` (`headset.c:3184-3189`) calls `lovrSwapchainDestroy`, which calls `xrDestroySwapchain` inline and unconditionally (`:3533-3542`). `lovrSwapchainInit`/`Destroy`/`Acquire`/`Release` are all `static` (declared `headset.c:335-338`), nothing in `headset.h:244-259` exposes a swapchain, and there is no setter for `quad.subImage.swapchain`. Detaching a swapchain from one Layer and attaching it to another would require splitting `Swapchain` out into a refcounted object and rewriting `subImage` on both the quad and the cylinder structs — `lovrLayerSetCurve` (`headset.c:3253-3305`) copies `subImage` between them, so a stale handle in the inactive one resurfaces on a curve change.

**The recycling unit is wrong, not the idea.** A `Layer`'s immutable state is only what `LayerInfo` carries (`headset.h:235-242`):

```c
typedef struct {
  uint32_t width;
  uint32_t height;
  bool stereo;
  bool immutable;
  bool transparent;
  bool filter;
} LayerInfo;
```

Everything a panel actually varies — pose, metre dimensions, curve, colour, viewport, origin — has a setter and lives outside `LayerInfo`. So a `Layer` of a given size is fully reusable by any panel wanting that size. Keeping the whole `Layer` alive keeps its swapchain alive, with no patch and no surgery on `struct Layer`.

`format` is not a real axis. `lovrSwapchainInit` hard-codes `info.format = VK_FORMAT_R8G8B8A8_SRGB` (`headset.c:3470`), and session start aborts with "This VR runtime does not support sRGB rgba8 textures" if the runtime refuses it (`:1125-1143`) — there is no negotiation and no fallback. The Lua boundary enforces the same at `l_headset.c:720`, `:728`, and `:900`. AC2.4's "identical width, height, and format" therefore reduces to width and height, plus the three other `LayerInfo` booleans.

### Layer creation blocks, and can block for ever

`lovrLayerCreate` (`headset.c:3122-3182`) does, synchronously on the calling thread: `xrCreateSwapchain` → `xrEnumerateSwapchainImages` → up to `MAX_IMAGES` (4, `headset.c:59`) × `lovrTextureCreate` → `xrAcquireSwapchainImage` → `xrWaitSwapchainImage` with **`XR_INFINITE_DURATION`**. There is no lazy path.

Worse, the wait loop (`headset.c:3543-3574`) is unbounded — on repeated failure it spins for ever logging warnings, with no escape:

```c
    for (;;) {
      XrResult result = xrWaitSwapchainImage(swapchain->handle, &waitInfo);
      if (XR_FAILED(result)) {
        lovrLog(LOG_WARN, "XR", "OpenXR failed to wait on swapchain image (%d)", result);
      } else {
        swapchain->acquired = true;
        break;
      }
    }
```

Creating a Layer mid-frame is therefore a frame-time hazard, and this is the main argument for a free list: a hit costs nothing, and misses are the only thing that can stall.

Note `lovrLayerCreate` deliberately acquires once at the end, with the comment "Avoid submission of un-acquired swapchain". That is not incidental — see the `XR_ERROR_LAYER_INVALID` rule below.

### The submit path already gives damage skipping

`lovrHeadsetSubmit` (`headset.c:3079-3101`) walks the whole layer array every frame and pushes every layer into `xrEndFrame` unconditionally. There is no dirty bit anywhere in the layer path; a grep for `dirty` in `headset.c` finds only `visibilityMaskDirty`, unrelated.

That is the right primitive. Resubmitting an unchanged composition layer is the normal cheap OpenXR case — roughly 100 bytes of struct, and the runtime re-composites from the already-released image with no GPU work on LÖVR's side. Every expensive operation is gated behind `lovrLayerGetTexture`/`lovrLayerGetPass` being called:

- Acquire is pull-driven, reached only from `lovrLayerGetTexture` (`headset.c:3357-3359`) and `lovrLayerGetPass`. The `acquired` flag makes it idempotent within a frame.
- Release happens only in `lovrHeadsetSubmit`, inside `if (state.frameState.shouldRender)`, and `lovrSwapchainRelease` is a no-op when nothing was acquired.

**So a panel not drawn this frame costs one struct in the array and nothing else.** Damage-driven rendering falls out of simply not calling `getPass`.

The OpenXR specification sanctions this explicitly. Acquire and release need **not** balance within a frame: "An application may call `xrEndFrame` without having called `xrReleaseSwapchainImage` since the previous call to `xrEndFrame` for any swapchain passed to `xrEndFrame`", and "`xrEndFrame` will use the most recently released swapchain image". The pairing must balance over time, not per frame.

The one hard constraint: **`XR_ERROR_LAYER_INVALID` if a layer references a swapchain with no released image.** Every swapchain must be written and released at least once before its Layer first appears in a submitted list.

### Monado does not bounds-check `layerCount`

The specification requires `XR_ERROR_LAYER_LIMIT_EXCEEDED` from `xrEndFrame` when `layerCount` exceeds `maxLayerCount`. **Monado does not implement it.** A grep for `LAYER_LIMIT` across `oxr_session_frame_end.c`, `oxr_session.c`, `oxr_system.c`, `comp_layer_accum.c`, and `comp_multi_*.c` returns nothing. The per-layer verify loop validates type, swapchain, and pose, but never compares the count.

Downstream, both accumulators write into fixed arrays with no guard. `comp_layer_accum.h:93` declares `struct comp_layer layers[XRT_MAX_LAYERS]`, and `push_single_swapchain_layer` (`comp_layer_accum.c:19-32`) does `layer_id = cla->layer_count; ... cla->layer_count++;`. `comp_multi_private.h:90` and `multi_compositor_layer_quad` do the same. The result of overflow is an out-of-bounds write, not an error and not a silent drop.

**And the budget is shared.** Under `XR_EXTX_overlay`, `comp_multi_system.c:352-372` concatenates layers from every client session into one `comp_layer_accum` with no aggregate cap. lunette can overflow it while individually under its own limit, because it cannot see how many layers the primary application is submitting.

`XrSystemGraphicsProperties::maxLayerCount` is queryable and Monado populates it from `info->max_layers`, or `XRT_MAX_LAYERS` (128 on Linux, 32 on Android) when headless. **LÖVR never consults it** — a grep for `maxLayerCount` finds no reference. lunette must query it and budget well below it.

### `lovrHeadsetSetLayers` releases before it retains

`headset.c:2759-2781`:

```c
  for (uint32_t i = 0; i < state.layerCount; i++) {
    lovrRelease(state.layers[i], lovrLayerDestroy);
  }

  state.layerCount = count;
  for (uint32_t i = 0; i < count; i++) {
    lovrRetain(layers[i]);
    state.layers[i] = layers[i];
  }
```

A Layer held only by `state.layers` and by nothing else is destroyed during this call — and destruction calls `xrDestroySwapchain` inline. The pool must hold an independent Rust-side reference to every pooled Layer, or a revoke-then-regrant of the same Layer within one call destroys it.

Two further points on this function. The list **persists across frames**; it does not need setting every frame, and `lovrHeadsetGetLayers` reads it back. The budget check counts a stereo layer as **2** (`:2760-2766`), while the Lua wrapper checks the object count instead (`l_headset.c:806`, `:817`) — the two disagree, and the native check is the binding one.

Submit order is fixed (`headset.c:3031-3101`): passthrough, background, main projection, then quad layers in array order, which is back-to-front. A stereo layer's right-eye copy is inserted immediately after its left-eye entry. `main = false` skips only the projection layer (`:3047-3076`); the main colour and depth swapchains are still released unconditionally. Note that the projection layer gains `BLEND_TEXTURE_SOURCE_ALPHA_BIT` whenever `state.layerCount > 0`, so adding any quad layer changes how it blends.

### Session loss destroys the pool

`lovrHeadsetStop` releases every layer and zeroes `layerCount` (`headset.c:1242-1246`) before `xrDestroySession`. The pool must observe session loss and rebuild from nothing. This is what makes `lunette.restart()` survivable in Phase 7, and it is why the pool's state must be reconstructible rather than assumed permanent.

### The damage predicate

smithay tracks damage-since-a-point for you, but only at the renderer layer. `RendererSurfaceState` (`src/backend/renderer/utils/wayland.rs`) is populated by `on_commit_buffer_handler::<D>(&WlSurface)` (`:369`), **which must be the first thing `CompositorHandler::commit` calls** — a Phase 2 amendment. It exposes `current_commit() -> CommitCounter` (`:267`), `damage_since(Option<CommitCounter>) -> DamageSet` (`:275`), and `damage() -> DamageSnapshot` (`:285`), the last being a cheap `Arc` clone holdable outside the lock.

The raw protocol layer (`SurfaceAttributes::damage`, `src/wayland/compositor/mod.rs:226`) accumulates rather than replaces — `merge_into` does `into.damage.extend(...)` — so at that layer the compositor must drain and clear. Use the renderer layer instead.

**The correct predicate is `current_commit()` changing, not `damage_since(...).is_empty()`.** `DamageSnapshot::add` (`src/backend/renderer/utils/mod.rs:221-238`) filters empty rectangles and **returns early without incrementing the counter** when the result is empty, so a new-buffer commit posting no damage leaves the counter untouched. Store the last-blitted `CommitCounter` per surface, exactly as smithay's own `import_surface` does with `renderer_seen: HashMap<ContextId, CommitCounter>` (`wayland.rs:503`, `:518`).

Two edge cases to handle explicitly. `MAX_DAMAGE_AGE` is 4 (`mod.rs:144`), so `damage_since` on a counter more than 4 commits old returns full damage — blit unconditionally when the counter jumps that far. And `reset()` (`wayland.rs:346-354`) fires on buffer removal or an unparseable buffer, clearing the bag so the next query yields full damage.

Damage is recorded only when a new buffer is attached, and is normalised to buffer coordinates, with `Damage::Surface` rectangles converted through the `SurfaceView` and clipped.

### Frame callbacks do not conflict with Phase 8

Recorded here so Phase 3 does not paint Phase 8 into a corner. Damage lives in `RendererSurfaceState::damage`; frame callbacks live in `SurfaceAttributes::frame_callbacks`. They are different structures, so Phase 3 can send callbacks unconditionally and Phase 8 can replace the send-time policy without touching the damage path.

Callbacks accumulate across commits rather than being replaced, so simply not draining them is a safe way to throttle — nothing is lost and no callback is dropped un-`done()`. Note that smithay's `send_frames_surface_tree` (`src/desktop/wayland/utils.rs:217`) keys its throttle on `Output` and primary-scanout state, and `SurfaceFrameThrottlingState` is private. lunette's outputs are XR quads, not scanout planes, so Phase 8 will want its own send routine over `with_surface_tree_downward` rather than adopting those semantics.

### Overlay behaviour under Monado

Relevant to the pool's budget and to Phase 7.

`sessionLayersPlacement` orders overlay sessions relative to each other; the main session is always composited first and therefore always at the back. Monado implements this: `oxr_session.c:1565-1571` chains the create-info into `xrt_session_info`, and `comp_multi_system.c:305` sorts clients ascending by `z_order`.

Three limitations, verified in source. **Overlays work in service mode only** — `multi_compositor_create` never initialises `mc->state.z_order` from `xsi->z_order`, so it stays 0 unless the IPC server calls `set_z_order`, and in monolithic mode there is no IPC server. **Overlays are always visible and focused** — `ipc_server_process.c:430-460` sets `visible = true; focused = true` for any overlay client, so lunette composites even with no foreground application and always shares input focus. And `set_z_order`/`set_state` both carry `//! @todo Locking?` comments (`comp_multi_system.c:648`, `:672`).

`XR_EXTX_overlay` is at Khronos' experimental tier, last revised 2021-01-13 at revision 5, with no successor and no ratified equivalent. It works; it is not a stability guarantee.

---

<!-- START_TASK_1 -->
### Task 1: LÖVR patch — raise `MAX_LAYERS` and expose the runtime limit

**Verifies:** None directly; enables `lunette-v1.AC2.2`.

**Files:**
- Modify: `vendor/lovr/src/modules/headset/headset.h`
- Modify: `vendor/lovr/src/modules/headset/headset.c`

**Step 1: Raise the constant**

`headset.h:9` reads `#define MAX_LAYERS 10`. Raise it to 64.

That is the whole change. It grows one static array (`headset.c:249`, 8 bytes a slot) and three stack arrays: `headset.c:3010` (8 bytes a slot, sized `MAX_LAYERS + 3` for passthrough, background, and main), `headset.c:3015` (`stereoLayers`, a union of `XrCompositionLayerQuad` and `XrCompositionLayerCylinderKHR`, roughly 100 bytes a slot), and `l_headset.c:801` (8 bytes a slot). At 64 that is about 6.5KB of frame stack in `lovrHeadsetSubmit` and half a kilobyte of static state.

The two error messages at `l_headset.c:806` and `:817` interpolate `MAX_LAYERS`, so their text updates automatically.

True runtime configurability was considered and rejected. It would require heap-allocating the static array and all three stack arrays and adding a getter for the Lua-side checks, touching the OpenXR submit hot path, and it buys nothing: the pool's budget is a policy number that lives in Rust, and LÖVR's constant only needs to be a ceiling above it.

**Step 2: Expose the runtime's real limit**

LÖVR never reads `XrSystemGraphicsProperties::maxLayerCount` — a grep finds no reference. Add an accessor returning it, populated from the `xrGetSystemProperties` call LÖVR already makes at session start.

This is not cosmetic. Monado does not enforce the limit and overflows a fixed array instead (see the investigation notes above), so lunette knowing the real ceiling is what prevents an out-of-bounds write in the runtime. Note `stereoLayers` is indexed by source-layer index, so it needs one slot per `Layer` object, while the budget check at `headset.c:2766` counts stereo layers as two — keep the raised constant comfortably above both interpretations.

**Step 3: Note the disagreeing checks**

`headset.c:2766` checks the stereo-doubled total; `l_headset.c:806` and `:817` check the object count. They disagree, and the native check binds. Record this in a comment rather than fixing it — reconciling them is a behavioural change to an existing path, which the fork discipline forbids.

**Step 4: Verify operationally**

Rebuild and run an existing LÖVR sample that uses layers. Expected: unchanged behaviour. Log the value of `maxLayerCount` at session start under Monado and record it.

**Step 5: Commit**

Two commits in `vendor/lovr`, each shaped as an upstream pull request: one raising the constant, one adding the accessor. "Raise the layer limit" is a plausible standalone upstream change.

```bash
git add vendor/lovr
git commit -m "build: bump vendor/lovr for a higher layer limit"
```
<!-- END_TASK_1 -->

<!-- START_SUBCOMPONENT_A (tasks 2-4) -->
<!-- START_TASK_2 -->
### Task 2: The layer pool

**Verifies:** `lunette-v1.AC2.4`.

**Files:**
- Create: `crates/lunette/src/layers/mod.rs`, `pool.rs`, `key.rs`

**Step 1: The key**

The free list is keyed by everything `LayerInfo` makes immutable: `(width, height, stereo, immutable, transparent, filter)`. A newtype, not a tuple — it is a domain type and appears in several signatures.

`format` is deliberately absent. `lovrSwapchainInit` hard-codes `VK_FORMAT_R8G8B8A8_SRGB` (`headset.c:3470`) and session start aborts if the runtime refuses it, so there is exactly one and a field for it would imply a choice that does not exist. Say so in a comment, because AC2.4's wording mentions format and the omission would otherwise read as an oversight.

**Step 2: The size ladder**

Quantise requested panel sizes to a ladder before building the key. A ladder turns most claims into free-list hits; without one, a panel resized continuously by a drag allocates a new `Layer` per frame, and each allocation can block (Step 4).

Use the same ladder Phase 8 uses for `wp_fractional_scale_v1` discrete scale steps. One ladder, one place to tune it, and the two features stay consistent by construction.

**Step 3: Recycle whole Layers, not swapchains**

The design says the pool recycles swapchains. It recycles `Layer` objects instead, for the reason recorded above: LÖVR embeds the swapchain by value and destroys it inline, with no reattach surface. Since everything a panel varies has a setter and lives outside `LayerInfo`, keeping the `Layer` alive keeps its swapchain alive and meets AC2.4 exactly.

On revoke, return the `Layer` to the free list. On claim, pop a match or create. Never call `lovrLayerDestroy` on revoke.

**Step 4: Bound creation cost**

`lovrLayerCreate` (`headset.c:3122-3182`) is synchronous and ends in `xrWaitSwapchainImage` with `XR_INFINITE_DURATION`, inside a retry loop that has no escape (`:3543-3574`). A free-list miss can therefore stall the frame indefinitely.

Cap creations per frame — one is a reasonable starting number — and issue them at a frame boundary rather than from inside a Lua callback. A claim that cannot be satisfied this frame is not granted this frame; the panel renders as an in-scene quad and the grant lands on a later boundary. That is the same degradation path AC2.3 already requires, so it needs no new mechanism.

**Step 5: Hold independent references**

`lovrHeadsetSetLayers` releases the old list before retaining the new one (`headset.c:2769-2777`), so a `Layer` reachable only through `state.layers` is destroyed mid-call, and destruction calls `xrDestroySwapchain` inline. The pool holds its own reference to every pooled `Layer`, granted or free. Comment the reason at the point the reference is taken; it looks redundant otherwise and someone will remove it.

**Step 6: Budget below the runtime limit**

Query the accessor from Task 1 and budget well below it. Monado does not enforce `maxLayerCount` and writes past the end of a fixed array instead, and under `XR_EXTX_overlay` that array is shared with the primary application, whose layer count lunette cannot observe. Treat the queried value as an upper bound on a conservative fixed cap, not as the cap itself.

Also count as `lovrHeadsetSetLayers` does: a stereo layer costs two.

**Step 7: Garbage collection**

Sweep the free list, destroying entries idle beyond a threshold. Count in frames rather than wall-clock, so the policy is deterministic and testable.

Destroying is the one place `lovrLayerDestroy` is called, and it must not happen while the `Layer` is in the list most recently passed to `lovrHeadsetSetLayers`. Sweep after the submit that no longer references it.

**Step 8: Never submit an unreleased swapchain**

`XR_ERROR_LAYER_INVALID` is returned for a layer whose swapchain has no released image. A newly created `Layer` must be blitted and released before it first appears in a submitted list. `lovrLayerCreate` already acquires once at `:3178` for exactly this reason — its comment says "Avoid submission of un-acquired swapchain" — but acquiring is not releasing, and release happens only in `lovrHeadsetSubmit`. Grant a newly created `Layer` only after its first blit has been issued.

**Step 9: Test**

All of this is pure logic over plain data and needs no GPU. Cover: a revoked layer returns to the free list; the next claim with an identical key allocates nothing (AC2.4); a claim with a different key allocates; the ladder maps a range of requested sizes onto the expected keys; the sweep destroys only past the threshold; the budget never exceeds the cap, counting stereo as two; creations never exceed the per-frame cap.

Keep the LÖVR calls behind a trait with a test fake that counts creations and destructions, per the seam rule. The pool's decisions are the thing under test.

**Verification:** `cargo test -p lunette`

**Step 10: Commit**

```bash
git add crates/lunette/src/layers/
git commit -m "feat: add the composition layer pool"
```
<!-- END_TASK_2 -->

<!-- START_TASK_3 -->
### Task 3: Restate AC2.4 and correct the rendering documentation

**Verifies:** `lunette-v1.AC2.4` (by correcting the documents that describe it).

**Files:**
- Modify: `docs/rendering.md`
- Modify: `docs/design-plans/2026-08-05-lunette-v1.md`
- Modify: `docs/decisions.md`

Task 2 recycles whole `Layer` objects on a key that deliberately excludes format. `docs/rendering.md` still says something else, and `docs/` is normative — a change that alters behaviour described there updates the document in the same change.

**Step 1: Correct `docs/rendering.md:43`**

It currently states: "Rust owns the pool instead, and recycles swapchains by `(width, height, format)`."

Neither half of the mechanism survives investigation. `struct Layer` embeds its `Swapchain` by value (`headset.c:182-185`), `lovrLayerDestroy` calls `xrDestroySwapchain` inline (`:3184-3189`, `:3533-3542`), the swapchain functions are all `static`, and there is no setter for `quad.subImage.swapchain`. And format is not an axis at all: `lovrSwapchainInit` hard-codes `VK_FORMAT_R8G8B8A8_SRGB` (`headset.c:3470`) and session start aborts if the runtime refuses it (`:1125-1143`).

Rewrite it for what Task 2 builds: Rust owns the pool and recycles whole `Layer` objects, keyed on the properties `LayerInfo` makes immutable — width, height, stereo, immutable, transparent, filter. Say that format is absent because there is exactly one, so a reader does not take the omission for an oversight.

**Step 2: Correct `docs/rendering.md:41`**

It describes the layer list as "per-frame, global, last-call-wins". The first is wrong: `lovrHeadsetSetLayers` retains the list in `state.layers` and it **persists across frames** (`headset.c:2759-2781`, read back by `lovrHeadsetGetLayers`). It does not need setting every frame.

The correction matters beyond accuracy. Because the list persists and per-layer GPU cost is gated behind `getPass`, an undrawn panel costs one struct in the submit array and nothing else — which is the mechanism Task 7's damage skipping relies on. A reader who believes the list is rebuilt per frame will not see why skipping a blit is safe.

**Step 3: Restate AC2.4 in the design plan**

It currently reads: "A revoked swapchain is reused by the next claim of identical width, height, and format, with no new allocation."

Restate in terms of what is reused — a revoked **layer** — and drop format from the key. The outcome the criterion asks for is unchanged and is met exactly: no allocation on a matching claim.

**Step 4: Record the decision**

Add a paragraph to `docs/decisions.md` under "Recorded decisions", in the surrounding style. Record that the recycling unit is the `Layer`, not the swapchain, with the reason — LÖVR gives no way to detach one from the other, and patching `struct Layer` to allow it would mean splitting `Swapchain` into a refcounted object and rewriting `subImage` on both the quad and cylinder structs, since `lovrLayerSetCurve` copies between them (`headset.c:3253-3305`).

This belongs in the record because "recycle the swapchain" is the obvious framing and someone will propose it again. It is also worth recording that the design's original framing was not wrong about the goal, only about the unit.

**Step 5: Verify**

Run: `rg -n 'recycles swapchains|per-frame, global' docs/`
Expected: no matches.

Run: `rg -n 'width, height, and format' docs/design-plans/`
Expected: no matches.

**Step 6: Commit**

```bash
git add docs/
git commit -m "docs: restate layer recycling in terms of layers, not swapchains"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Rebuild the pool on session loss

**Verifies:** None directly; required by `lunette-v1.AC5.5` in Phase 7.

**Files:**
- Modify: `crates/lunette/src/layers/pool.rs`

**Step 1: Observe session loss**

`lovrHeadsetStop` releases every layer and zeroes `layerCount` (`headset.c:1242-1246`) before `xrDestroySession`. Every `Layer` the pool holds becomes invalid, granted or free.

The pool observes the session lifecycle and discards its entire state — free list, grants, and references — rather than attempting to reuse anything across it. Outstanding claims are re-evaluated against the new session on the first frame after it comes up.

**Step 2: Make grants survivable**

A `Claim` is Lua-visible, and a claim that survives a session rebuild must not hand Lua a dangling `Layer`. On session loss every granted claim is revoked and `lovr.lunlayerrevoked` fires, so Lua falls back to in-scene quads by the path AC2.3 already defines. Grants are re-issued as the pool refills.

**Step 3: Test**

Simulated session loss against the fake: every pooled layer is dropped, every grant is revoked with an event, and the first frame after recovery re-grants from an empty pool without reusing a stale handle.

**Verification:** `cargo test -p lunette`

**Step 4: Commit**

```bash
git add crates/lunette/src/layers/pool.rs
git commit -m "feat: rebuild the layer pool on session loss"
```
<!-- END_TASK_4 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (tasks 5-6) -->
<!-- START_TASK_5 -->
### Task 5: `lunette.claimLayer` and the `Claim` handle

**Verifies:** `lunette-v1.AC2.2`, `lunette-v1.AC2.3`.

**Files:**
- Create: `crates/lunette/src/lua/claim.rs`
- Modify: `crates/lunette/src/lua/mod.rs`
- Modify: `docs/lua-api.md`

**Step 1: The API**

`lunette.claimLayer` takes a source, a requested size, and a scalar priority, and returns a `Claim` handle. A granted claim exposes a real LÖVR `Layer` userdata — not a wrapper, so Lua uses the documented `Layer` methods directly. `claim:setPriority(n)` adjusts the ranking without recreating the claim.

`docs/rendering.md:47-50` describes claim semantics but names no function, so nothing in `docs/` currently tells a configuration author how to obtain a claim. Document `lunette.claimLayer`, `claim:setPriority`, and the `Claim` handle's fields in `docs/lua-api.md` in this task. Phase 6's panels choose between a layer and an in-scene quad, and by `CONTRIBUTING.md:62` mullion may use only the public API — an undocumented constructor makes tier 1 unwritable.

**Step 2: Ranking**

Rust sorts by the Lua-supplied priority and assigns the top N deterministically. It does not invent the ranking; ranking is application knowledge and belongs to Lua. This split is a recorded decision in `docs/decisions.md` and was revisited once during design, so do not re-litigate it in code.

Sort stably, so equal priorities do not reorder between frames and cause grants to churn.

**Step 3: Frame boundaries**

Grants and revocations land on frame boundaries, never mid-frame. A claim made during a Lua callback queues and is resolved at frame end with the other mutations.

Mid-frame changes would mean a panel's realisation changing between its `lovr.update` and its `lovr.draw`, which is exactly the class of inconsistency the snapshot model exists to prevent.

**Step 4: Exhaustion**

When the pool is exhausted, revoke the lowest-priority granted claim in favour of a higher-priority one. The revoked panel continues rendering as an in-scene quad — Lua does that, having received the event; Rust only stops providing the `Layer`.

**Step 5: Dead handles**

A `Claim` follows the same rule as every other handle: after revocation or session loss it reports `dead == true`, reads return last-known values, and methods return `false` without raising.

**Step 6: Test**

Claims granted in priority order; a higher-priority claim arriving at capacity revokes the lowest; grants observed only at frame boundaries; a dead claim's methods return `false` without raising.

**Verification:** `cargo test -p lunette`

**Step 7: Commit**

```bash
git add crates/lunette/src/lua/claim.rs
git commit -m "feat: expose layer claims to lua"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: Grant and revoke events

**Verifies:** `lunette-v1.AC2.3`.

**Files:**
- Modify: `crates/lunette/src/lua/claim.rs`

**Step 1: Push the events**

`lovr.lunlayergranted` and `lovr.lunlayerrevoked` go through `lovr.event.push`, which dispatches through `lovr.handlers`. That table `__index`es `lovr` (`etc/boot.lua:345`), so pushing `'lunlayergranted'` calls `lovr.lunlayergranted` with no new machinery and no patch.

The poll loop unpacks four arguments, so the payload travels as a single table rather than as positional values. Follow that convention for every `lun*` event, so the shape is uniform across phases.

**Step 2: Ordering**

Both events fire at the frame boundary where the grant or revocation actually lands, before `lovr.update`, so a handler observing the event and a handler reading the claim's state in the same frame agree.

**Step 3: Errors in handlers**

Handlers run under `xpcall` like every other user callback. An error is reported and the session continues; it does not prevent the grant or revocation, which has already happened in Rust.

**Step 4: Test**

Revoking under contention fires exactly one `lunlayerrevoked` for the displaced claim and one `lunlayergranted` for the winner, both at the same boundary, and an error raised in a handler does not prevent either.

**Verification:** `cargo test -p lunette`

**Step 5: Commit**

```bash
git add crates/lunette/src/lua/claim.rs
git commit -m "feat: fire layer grant and revoke events"
```
<!-- END_TASK_6 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_TASK_7 -->
### Task 7: The damage-gated blit path

**Verifies:** `lunette-v1.AC7.2`.

**Files:**
- Create: `crates/lunette/src/layers/blit.rs`
- Modify: `crates/lunette-compositor/src/state.rs`

**Step 1: Amend Phase 2's commit handler**

`on_commit_buffer_handler::<D>(&surface)` must be **the first call** in `CompositorHandler::commit`. It is what populates `RendererSurfaceState`, and nothing below works without it. This is an amendment to the handler written in Phase 2 Task 5.

**Step 2: Track the last-blitted commit**

Keep a `CommitCounter` per surface, recording what was last blitted. This mirrors smithay's own `import_surface`, which keeps `renderer_seen: HashMap<ContextId, CommitCounter>` (`wayland.rs:503`, `:518`).

**Step 3: Decide whether to blit**

The predicate is **`current_commit()` differing from the last blitted value**, not `damage_since(...).is_empty()`.

`DamageSnapshot::add` (`src/backend/renderer/utils/mod.rs:221-238`) filters empty rectangles and returns early **without incrementing the counter** when the result is empty. So a commit that attaches a new buffer but posts no damage rectangles leaves the counter unchanged — and asking about damage would report none while the buffer really did change. Comparing counters is both simpler and correct.

Three cases need explicit handling:

- The counter has not moved: skip the blit entirely. Do not call `getPass` or `getTexture` on the layer. This is the whole optimisation.
- The counter has moved by more than `MAX_DAMAGE_AGE` (4, `mod.rs:144`): blit the full surface, because older history is gone and `damage_since` would report full damage anyway.
- `reset()` has fired — buffer removal or an unparseable buffer (`wayland.rs:346-354`): treat as full damage.

If a client is observed attaching genuinely new buffers without moving the counter, compare buffer identity as well. Note that as a known edge rather than pre-emptively coding for it.

**Step 4: Issue the blit**

No LÖVR patch is needed. `lovrTextureCopy` (`graphics.h:258`) and `lovrTextureBlit` (`:259`) are already public, already take `state.lock`, already record into `state.stream`, and already emit `syncStream` barriers. Both require `TEXTURE_TRANSFER` on source and destination (`graphics.c:2967-2968`); Phase 2 Task 10 declares it on imported textures, and layer swapchain textures carry `TEXTURE_RENDER | TEXTURE_TRANSFER | TEXTURE_SAMPLE` (`headset.c:3496-3506`).

**Format conversion.** Layer swapchains are `FORMAT_RGBA8` with `srgb = true`, backed by `VK_FORMAT_R8G8B8A8_SRGB`. A window arriving as `Argb8888` or `Xrgb8888` imports as `FORMAT_BGRA8`, so source and destination formats differ. `lovrTextureCopy` degrades to `lovrTextureBlit` in that case (`graphics.c:2961`), which requires `GPU_FEATURE_BLIT` on both formats — check for it and fall back to an in-scene quad with a logged reason if it is absent, rather than failing the frame.

The X-variant alpha caveat from Phase 2 applies here: `Xrgb8888` and `Xbgr8888` map to alpha Vulkan formats, so alpha must be forced to 1 or the layer composites against whatever was in that byte. Since layers are `transparent` by default this is visible, not theoretical.

**Step 5: Acquire and release around the imported texture**

Call the Phase 2 Task 3 import-acquire wrapper before reading the imported texture and the release wrapper after, on the frames where a blit actually happens. On skipped frames neither is called, because the texture is not read.

**Step 6: Submit unconditionally**

Every granted layer goes into `lovrHeadsetSetLayers` every frame, blitted or not. Skipping the blit does not mean skipping the submit — the runtime re-composites from the most recently released image, which is exactly what the specification says `xrEndFrame` does. Omitting the layer would make the panel disappear.

**Step 7: Test**

Synthetic `CommitCounter` sequences against a fake blitter that counts calls: an unchanged counter produces no blit (AC7.2); a moved counter produces one; a jump beyond 4 produces a full blit; a reset produces a full blit; a skipped frame still submits the layer. No GPU.

**Verification:** `cargo test -p lunette` and `cargo test -p lunette-compositor`

**Step 8: Commit**

```bash
git add crates/lunette/src/layers/blit.rs crates/lunette-compositor/src/state.rs
git commit -m "feat: blit into layers, skipping undamaged surfaces"
```
<!-- END_TASK_7 -->

<!-- START_TASK_8 -->
### Task 8: Layer textures rotate

**Verifies:** None directly; prevents a defect in `lunette-v1.AC2.2`.

**Files:**
- Modify: `crates/lunette/src/layers/blit.rs`

**Step 1: Enforce the rule**

`lovrLayerGetTexture` calls `lovrSwapchainAcquire` (`headset.c:3323-3325`), and `lovrSwapchainRelease` resets `textureIndex` to `~0u` after every submit (`:3568`). So a call in a later frame genuinely re-acquires, and may return a different image.

This is the same hazard as `window:getTexture()`, and it gets the same treatment: the returned handle carries the frame generation and errors if used from a later frame. Enforce it rather than documenting it — a stale layer texture produces intermittent wrong-frame content, which is among the hardest things to diagnose from a headset.

**Step 2: Immutable layers**

A layer created `immutable` errors with "Static Layers can only be updated once" on the second acquire (`headset.c:3547-3550`). The pool never creates immutable layers, since a pooled layer is by definition reused. Assert it at the point of creation so the constraint is checked rather than assumed.

**Step 3: Test**

A texture handle used in a later frame raises rather than returning stale content.

**Verification:** `cargo test -p lunette`

**Step 4: Commit**

```bash
git add crates/lunette/src/layers/blit.rs
git commit -m "fix: prevent layer textures being cached across frames"
```
<!-- END_TASK_8 -->

<!-- START_TASK_9 -->
### Task 9: Check suite and the sharpness gate

**Verifies:** `lunette-v1.AC2.2`, `lunette-v1.AC2.3`, `lunette-v1.AC2.4`, `lunette-v1.AC7.2`.

**Step 1: Run the check suite**

All five commands from `CONTRIBUTING.md:171-175`, inside `nix develop`.

**Step 2: Confirm the automated criteria**

- Claims are granted in priority order, and exhaustion revokes the lowest with an event (AC2.3).
- A revoked layer is reused by the next claim with an identical key, with no allocation (AC2.4).
- An undamaged surface is not blitted (AC7.2).

**Step 3: The human gate**

A text-heavy terminal is visibly sharper rendered on a layer than the same terminal in-scene (AC2.2). This needs a headset and is recorded in `test-requirements.md` as human verification.

Check it under Monado in service mode. Overlay sessions do not work in monolithic mode: `multi_compositor_create` never initialises `z_order` from the session create-info, and only the IPC server calls `set_z_order`.

**Step 4: Record the layer findings**

Append to `docs/2026-08-06-milestone-0-findings.md`:

- The value of `maxLayerCount` Monado reported, and the conservative cap chosen against it.
- Free-list hit rate in ordinary use, and whether the size ladder's steps were the right ones.
- Whether format conversion was needed in practice, meaning whether real clients delivered `Argb8888`/`Xrgb8888`, and whether `GPU_FEATURE_BLIT` was present.
- Whether the per-frame creation cap was ever hit, and whether a stall from `lovrLayerCreate` was observed.

**Step 5: Commit**

```bash
git add docs/2026-08-06-milestone-0-findings.md
git commit -m "docs: record layer pool findings"
```
<!-- END_TASK_9 -->

---

## Done when

- Tests verify claims are granted in priority order, revocation frees a layer for reuse without reallocation, and an undamaged surface is not blitted.
- A text-heavy terminal is visibly sharper on a layer than in-scene.
- All five check commands pass.

## Deliberately not in this phase

- Cylinder layers. `lovrLayerSetCurve` exists and the pool could serve them, but nothing needs them until mullion has an opinion about curved panels.
- Stereo layers. The key admits them and the budget counts them as two, but no source produces stereo content in v1.
- Per-panel output scale, which changes the requested size and therefore the pool key — Phase 8.
- Frame-callback throttling. Recorded above as non-conflicting: damage lives in `RendererSurfaceState`, callbacks in `SurfaceAttributes`, and Phase 8 replaces the send policy without touching this phase's damage path.
