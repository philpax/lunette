# lunette v1 Implementation Plan — Phase 8: Outputs, scale, and pacing

**Goal:** Per-panel resolution and frame rate.

**Architecture:** Lua creates virtual outputs and assigns them to clients at spawn; a hand-written `can_view` makes each output global visible only to its assigned clients. Fractional scale is advertised natively and chosen in Lua from a discrete ladder with hysteresis. Frame-callback throttling extends the compositor's own per-surface callback map rather than smithay's private throttle state. Scene rendering is skipped by not acquiring the swapchain, not merely by omitting the projection layer.

**Tech Stack:** smithay 0.7 `GlobalDispatch::can_view`, `wp_fractional_scale_v1`, `wp_content_type_v1`, LÖVR's `setLayers`.

**Scope:** Phase 8 of 8. Specified at intent level in the design; task detail derives from investigation.

**Codebase verified:** 2026-08-06.

---

## Acceptance criteria coverage

### lunette-v1.AC2: Panels render, on layers where possible
- **lunette-v1.AC2.5 Success:** Raising a panel's output scale causes the client to re-render at the higher resolution, and the layer samples the new buffer.

### lunette-v1.AC7: The overlay stays cheap
- **lunette-v1.AC7.3 Success:** A panel outside the view is throttled toward the floor, and its client continues to process input rather than appearing hung.
- **lunette-v1.AC7.4 Success:** With only layers drawn and no Lua scene content, the projection layer is skipped.

---

## Facts established by investigation

### `Output::create_global` cannot filter

`Output::create_global` (`src/wayland/output/mod.rs:201-211`) calls `display.create_global::<D, WlOutput, _>(4, WlOutputData { .. })` with no filter hook.

Filtering happens through `GlobalDispatch::can_view(client: Client, global_data: &U) -> bool` (`wayland-server-0.31.13/src/global.rs:119-121`, defaulting to `true`). The backend consults it in three places:

- registry advertisement, `send_all_globals_to` (`wayland-backend-0.3.15/src/rs/server_impl/registry.rs:199`)
- late advertisement of a newly created global, `send_global_to_all` (`registry.rs:224`)
- **at bind time** (`registry.rs:120`), returning `None` so the bind fails

That third one matters: a client that guesses a global name it was never advertised still cannot bind it.

**The obstacle is `delegate_output!`.** It routes `GlobalDispatch<WlOutput, WlOutputData>` to `OutputManagerState` (`src/wayland/output/mod.rs:332-339`), whose implementation (`src/wayland/output/handlers.rs:22-60`) never overrides `can_view`. So lunette hand-writes that one implementation for its own state, with its own `can_view`, delegating `bind` to `<OutputManagerState as GlobalDispatch<..>>::bind`, and drops that single line from the `delegate_output!` expansion while keeping the xdg-output and `Dispatch` lines.

`WlOutputData` is public and holds `output: Output` (`mod.rs:207`), so the filter can identify which output it is being asked about via `global_data.output.name()`.

**`can_view` has no access to `&mut D`.** So the assigned-output set cannot live in compositor state looked up by `ClientId`. It lives in the per-client `ClientState`, which WayVR already has (`comp.rs:395-400`, used at `comp.rs:225` and `client.rs:131`), reachable through `Client::get_data::<ClientState>()` (`wayland-server/src/client.rs:31`).

**`can_view` is only re-evaluated at advertisement and bind.** Once a client has bound a `wl_output`, changing its assigned set retracts nothing. Retraction needs `DisplayHandle::disable_global` then `remove_global` (`display.rs:143`, `:159`), and re-advertisement needs a fresh `create_global`.

Decided on 2026-08-06: assign at spawn, which is the common case and what `docs/dev/compositor.md:65`'s `lunette.spawn{ output = out }` already implies. Reassigning a running client destroys and recreates the global, which the client experiences as a monitor unplug and replug. Document that, because a toolkit may move windows in response and the user should know why.

Note also that `Output::create_global` stores a single handle on the output (`mod.rs:206`), so there is one `Output` per global — a filtered design still creates one global per output, not one per client.

### `wp_fractional_scale_v1`

All in `src/wayland/fractional_scale/mod.rs`.

- `FractionalScaleManagerState::new::<D>(&DisplayHandle)` (`:80-93`) creates the version 1 global, requiring `D: FractionalScaleHandler` and `Dispatch<WpFractionalScaleV1, Weak<WlSurface>>`.
- `FractionalScaleHandler::new_fractional_scale(&mut self, surface)` (`:210-214`) fires at `:172` after the client's `get_fractional_scale`.
- `with_fractional_scale(states, f)` (`:253-263`) uses `data_map.get_or_insert(...)` — the **non-threadsafe** insert, holding a `RefCell`. Compositor thread only, exactly as Phase 2 recorded when it declined to port WayVR's calls.
- `FractionalScaleState::set_preferred_scale(&mut self, scale: f64)` (`:233-241`) sends `preferred_scale(round(scale * 120))`, and only when the value changed and an object exists. A value set before the client creates the object is **replayed at creation** (`:160-166`), so pre-setting is safe and avoids a first-frame at the wrong scale.

WayVR's calls at `comp.rs:125` and `:145` are confirmed dead: `grep -rn "FractionalScaleManagerState\|delegate_fractional"` over its compositor returns nothing, so the global is never created and no client can ever hold a `WpFractionalScaleV1`. Those calls only write surface user data nobody reads.

**The client is owed more than the preferred scale.** It renders at that scale and uses `wp_viewport.set_destination` plus an integer `wl_surface.set_buffer_scale` to land the buffer at the right logical size. The compositor still owes it a correct `wl_output.scale` — the ceiling of the integer scale — and an xdg-toplevel configure at the matching logical size. Sending only the fractional preference produces sharp content at the wrong size.

`wp_viewporter` is already advertised from Phase 2, where xwayland-satellite required it.

### Frame-callback throttling: do not use `send_frames_surface_tree`

`send_frames_surface_tree` (`src/desktop/wayland/utils.rs:217-266`) looks like the answer and is not.

Per surface it computes `on_primary_scanout_output` and `frame_overdue = state.update(time, throttle)`, then sends **if either is true** (`:245-249`). So the primary-scan-out branch bypasses the throttle entirely, and using this function for real rate limiting means passing a `primary_scan_out_output` closure that deliberately returns a non-matching output — disabling half the function to reach the other half.

`SurfaceFrameThrottlingState` (`:484-503`) is declared without `pub`. It cannot be named, reset, or inspected from lunette; it is reachable only as a side effect of calling that function. There is nowhere to hang a video exemption or a per-surface override.

WayVR's own mechanism is better suited. It intercepts frame callbacks at commit into `pending_frame_callbacks: HashMap<ObjectId, Vec<WlCallback>>` (`comp.rs:92`), drains at `comp.rs:312-318`, and fires from `send_frame_callbacks_for_surface_id` (`comp.rs:151-160`). That map is already a per-surface withhold point. Adding a last-sent timestamp and an interval beside it gives the same throttle in a type lunette owns, with a natural home for the exemption.

Phase 3 already recorded that this does not conflict with damage skipping: damage lives in `RendererSurfaceState`, callbacks in `SurfaceAttributes`, and callbacks accumulate across commits rather than being replaced — so withholding them is safe and loses nothing.

**The floor is approximately 1 Hz, not zero** (`docs/dev/rendering.md:72`). A client that never receives a frame callback stops pumping its event loop and stops responding to input, which looks like a hang. AC7.3 requires the client to keep processing input, so the floor is the mechanism that satisfies it.

### Video exemption

smithay 0.7 supports `wp_content_type_v1` at `src/wayland/content_type/mod.rs`: `ContentTypeState::new::<D>(&DisplayHandle)` (`:159`), `delegate_content_type!`, and a per-surface double-buffered `ContentTypeSurfaceCachedState` read at commit through `states.cached_state.get::<ContentTypeSurfaceCachedState>().current().content_type()` (`:85-94`). Variants are `None`, `Photo`, `Video`, and `Game`, defaulting to `None` (`:96-102`). There is no handler trait and no events — it is purely a client hint.

Adoption is thin and inconsistent, so the hint alone is not a reliable video detector. Expose it to Lua as an enum and let Lua combine it with a commit-rate heuristic. `docs/dev/rendering.md:73` says video is exempt by default; the native layer supplies the signal, Lua decides what counts.

### Skipping the projection layer costs nothing unless `getPass` is skipped

`l_headset.c:800-825`: `setLayers` reads a `main` field defaulting to `true` (`:812-814`), and `lovrHeadsetSetLayers` stores it as `state.showMainLayer` (`headset.c:2778`).

At submit (`headset.c:3047-3077`), a false value simply means the `XrCompositionLayerProjection` is not appended to `XrFrameEndInfo::layers`. Quad and cylinder layers (`:3079-3089`), passthrough (`:3036`), and background (`:3041`) are unaffected.

**The saving does not come from that.** The colour swapchain is acquired lazily, only inside `lovrHeadsetGetTexture` and `GetPass` (`headset.c:2836`, `:2861`). If nothing calls `getPass`, the acquire, the wait, the render pass, and the MSAA resolve are all genuinely skipped. If something does call it, `setLayers{main = false}` still pays for the acquire and `xrWaitSwapchainImage` and then throws the result away.

Stock `etc/boot.lua:215` calls `lovr.headset.getPass()` **unconditionally**, before checking whether `lovr.draw` exists. lunette owns its own run loop and must skip that call itself. `lovrSwapchainRelease` is a no-op when nothing was acquired (`headset.c:3567`), so the release at `:3031-3032` costs nothing either way.

Remaining per-frame cost with everything skipped: the three OpenXR frame calls, pose prediction and update, and the quad-layer blits. `docs/dev/rendering.md:75` is explicit that lunette always submits an XR frame — only its own scene rendering stops.

### WayVR precedent: none

No output filtering — one unfiltered global (`mod.rs:209-224`) with `delegate_output!` and the default `can_view` (`comp.rs:687`). No `FractionalScaleManagerState`. No `ContentTypeState`. No throttling — callbacks are queued per surface and fired when that surface is rendered.

This phase is greenfield on every count, with the per-surface callback map as the only reusable scaffolding.

---

<!-- START_SUBCOMPONENT_A (tasks 1-2) -->
<!-- START_TASK_1 -->
### Task 1: `lunette.newOutput`

**Verifies:** None directly; enables `lunette-v1.AC2.5`.

**Files:**
- Create: `crates/lunette-compositor/src/output.rs`
- Modify: `crates/lunette/src/lua/mod.rs`, `docs/dev/lua-api.md`

**Step 1: The signature**

`docs/dev/compositor.md:18-22` gives it exactly: `lunette.newOutput{ width = 1920, height = 1080, scale = 1.5, refresh = 90 }`. Four named fields, no name, no physical size, no transform.

**Refresh is in hertz in Lua and millihertz in smithay.** Convert at the boundary and nowhere else. A field that is hertz in one layer and millihertz in another is the kind of thing that produces a 90000 Hz output and a very confused client.

**Step 2: Replace the shared output**

`docs/dev/compositor.md:24` rejects WayVR's single shared output (`mod.rs:209`) explicitly. Phase 2 created one output to get clients running; this replaces it with Lua-created ones.

**Step 3: One `Output` per global**

`Output::create_global` stores a single handle on the output (`src/wayland/output/mod.rs:206`). Filtering does not change that — there is one global per output, made selectively visible, not one global per client.

**Step 4: Document it**

`docs/dev/lua-api.md` gains `lunette.newOutput` and the output handle. `docs/dev/compositor.md:18-22` already describes it; the API reference should not be the one place it is missing.

**Step 5: Test**

Cover: an output is created with the requested dimensions; refresh converts to millihertz once; a client bound to an output sees the expected mode; two outputs with different scales coexist.

**Verification:** `cargo test -p lunette-compositor`

**Step 6: Commit**

```bash
git add crates/lunette-compositor/src/output.rs crates/lunette/src/lua/mod.rs docs/dev/
git commit -m "feat(compositor): create virtual outputs from lua"
```
<!-- END_TASK_1 -->

<!-- START_TASK_2 -->
### Task 2: Per-client output filtering

**Verifies:** `lunette-v1.AC2.5`.

**Files:**
- Modify: `crates/lunette-compositor/src/output.rs`, `src/state.rs`

**Step 1: Hand-write the `GlobalDispatch` impl**

`Output::create_global` has no filter hook, and `delegate_output!` routes `GlobalDispatch<WlOutput, WlOutputData>` to `OutputManagerState`, which never overrides `can_view` (`src/wayland/output/handlers.rs:22-60`).

So: write `impl GlobalDispatch<WlOutput, WlOutputData> for State` with lunette's own `can_view`, delegating `bind` to `<OutputManagerState as GlobalDispatch<WlOutput, WlOutputData>>::bind`. Then remove that single line from the `delegate_output!` expansion, keeping the xdg-output and `Dispatch` lines.

Comment why the macro is partially expanded. A hand-written impl next to a macro that appears to cover it reads as a mistake otherwise, and someone will "fix" it by restoring the macro.

**Step 2: Store the assignment on the client**

`can_view(client: Client, global_data: &WlOutputData) -> bool` receives no `&mut D`, so it cannot consult compositor state.

Put the assigned-output set in the per-client `ClientState` — Phase 2 already ported it (`comp.rs:395-400`) — and reach it with `Client::get_data::<ClientState>()`. `WlOutputData.output` (`mod.rs:207`) identifies which output is being asked about.

**Step 3: Assign at spawn**

`docs/dev/compositor.md:65` already spells it: `lunette.spawn{ output = out }`. The assignment is made before the client connects, so the set is populated by the time the client's first registry advertisement runs.

`docs/dev/compositor.md:26` states the default policy: one output per spawned application, with the standard library choosing. The rationale is at the same line — a client enumerating other windows' monitors confuses toolkits.

**Step 4: Reassignment recreates the global**

`can_view` is consulted at registry advertisement (`registry.rs:199`, `:224`) and at bind (`:120`), and nowhere else. Changing the set after a client has bound retracts nothing.

Reassignment therefore does `disable_global` then `remove_global` (`display.rs:143`, `:159`) and a fresh `create_global`. The client sees a monitor unplug and replug.

Document that in `docs/dev/compositor.md`. A toolkit may move or resize windows in response, and a user who reassigns an output and watches their windows jump should be able to find out why.

**Step 5: Bind-time enforcement is the real boundary**

Advertisement filtering alone would be advisory — a client can bind a global name it was never told about. The bind check at `registry.rs:120` is what makes the filter enforceable, and it comes free with `can_view`. Note it, so nobody optimises the check away as redundant.

**Step 6: Test**

Over the socketpair harness, and pure where possible. Cover: a client assigned one output sees exactly that one in the registry; a client assigned none sees none; a bind attempt for an unassigned output fails; two clients with different assignments each see only theirs; reassignment removes and recreates, and the client observes the new set.

**Verification:** `cargo test -p lunette-compositor`

**Step 7: Commit**

```bash
git add crates/lunette-compositor/src/
git commit -m "feat(compositor): show each client only its assigned outputs"
```
<!-- END_TASK_2 -->
<!-- END_SUBCOMPONENT_A -->

<!-- START_SUBCOMPONENT_B (tasks 3-4) -->
<!-- START_TASK_3 -->
### Task 3: `wp_fractional_scale_v1`

**Verifies:** `lunette-v1.AC2.5`.

**Files:**
- Modify: `crates/lunette-compositor/src/state.rs`, `src/output.rs`

**Step 1: Create the global**

`FractionalScaleManagerState::new::<D>(&DisplayHandle)` (`fractional_scale/mod.rs:80-93`), with `FractionalScaleHandler` and the required `Dispatch`, plus `delegate_fractional_scale!`.

This is the step WayVR omits, which is why its `with_fractional_scale` calls at `comp.rs:125` and `:145` are dead — no global, so no client can ever hold a `WpFractionalScaleV1`, so `set_preferred_scale` writes user data nobody reads. Phase 2 declined to port those calls for this reason.

`wp_viewporter` is already advertised from Phase 2, and clients need it to apply a fractional scale.

**Step 2: Set the preferred scale**

`FractionalScaleState::set_preferred_scale(scale)` (`:233-241`) sends `round(scale * 120)`, and only when the value changed. Setting it before the client creates its object is safe — the value is replayed at creation (`:160-166`) — and avoids a first frame at the wrong scale.

**Compositor thread only.** `with_fractional_scale` (`:253-263`) uses the non-threadsafe `get_or_insert` holding a `RefCell`, which returns divergent state when touched from another thread. Phase 2 recorded this hazard; here it becomes live.

**Step 3: Send the rest of what the client needs**

A fractional scale alone is not enough. The client renders at that scale and uses `wp_viewport.set_destination` with an integer `wl_surface.set_buffer_scale` to land at the right logical size — but it needs a correct `wl_output.scale`, the ceiling of the integer scale, and an xdg-toplevel configure at the matching logical size.

Omit either and the client renders sharp content at the wrong size, which looks like a scaling bug in the client rather than a missing configure in the compositor.

**Step 4: Test**

Cover: creating the global lets a client obtain a `WpFractionalScaleV1`; the preferred scale is sent as `round(scale * 120)`; an unchanged value sends nothing; a value set before the object exists is replayed on creation; `wl_output.scale` and the toplevel configure accompany the change.

**Verification:** `cargo test -p lunette-compositor`

**Step 5: Commit**

```bash
git add crates/lunette-compositor/src/
git commit -m "feat(compositor): advertise fractional scale to clients"
```
<!-- END_TASK_3 -->

<!-- START_TASK_4 -->
### Task 4: Discrete scale steps with hysteresis

**Verifies:** `lunette-v1.AC2.5`.

**Files:**
- Create: `lua/mullion/scale.lua`

**Step 1: Policy in Lua**

`docs/dev/compositor.md:34`: "The standard library uses discrete scale steps with hysteresis rather than continuous adjustment. This is Lua policy, and it is tunable."

Rust advertises; Lua decides. Continuous adjustment would make a client re-render on every centimetre of head movement.

**Step 2: Share Phase 3's ladder**

Use the same size ladder the layer pool keys on (Phase 3 Task 2). Raising a panel's scale changes its requested pixel size, and a size the pool has never seen forces an allocation — with a `lovrLayerCreate` that blocks on `XR_INFINITE_DURATION`.

Sharing the ladder makes a scale change land on a pool size that already exists. One ladder, one place to tune it.

**Step 3: Hysteresis**

Different thresholds for raising and lowering, so a panel at a boundary does not oscillate. A client re-rendering its whole surface twice a second because the user is breathing is worse than being slightly the wrong sharpness.

**Step 4: Tuning table**

Steps and thresholds in one table, as with Phase 6's interaction constants. A tuning pass should be a diff to one place.

**Step 5: Test**

Pure. Cover: a distance maps to the expected step; approaching a threshold does not change step until it is crossed; crossing back requires passing the lower threshold, not the upper; the emitted sizes are all on the ladder; a panel at the extreme clamps rather than running off the end.

**Step 6: Commit**

```bash
git add lua/mullion/scale.lua
git commit -m "feat(mullion): choose scale from discrete steps with hysteresis"
```
<!-- END_TASK_4 -->
<!-- END_SUBCOMPONENT_B -->

<!-- START_SUBCOMPONENT_C (tasks 5-6) -->
<!-- START_TASK_5 -->
### Task 5: Frame-callback throttling

**Verifies:** `lunette-v1.AC7.3`.

**Files:**
- Modify: `crates/lunette-compositor/src/state.rs`
- Create: `crates/lunette-compositor/src/pacing.rs`

**Step 1: Extend the callback map, not smithay's throttle**

Phase 2 ported WayVR's per-surface `pending_frame_callbacks` map (`comp.rs:92`, drained `:312-318`, fired from `send_frame_callbacks_for_surface_id` `:151-160`). Add a last-sent timestamp and an interval beside each entry.

Do **not** use `send_frames_surface_tree` (`desktop/wayland/utils.rs:217-266`). Two reasons, both concrete:

- It sends if the surface is on the primary scan-out output **or** the frame is overdue (`:245-249`), so the scan-out branch bypasses the throttle. Using it for real rate limiting means passing a closure that deliberately returns a non-matching output, to disable half the function.
- `SurfaceFrameThrottlingState` (`:484-503`) has no `pub`. It cannot be named, reset, or inspected, and there is nowhere to hang a video exemption or a per-surface override.

Owning the type is worth more than reusing forty lines.

**Step 2: `surface:setFrameRate(hz)`**

The native mechanism, per `docs/dev/rendering.md:63`. Rate policy — visibility, gaze, distance, focus, whether a game is running — is Lua's (`:68`).

**Step 3: The floor is 1 Hz, not zero**

`docs/dev/rendering.md:72`: "The floor is approximately 1 Hz, not zero."

A client receiving no frame callbacks stops pumping its event loop and stops responding to input, which is indistinguishable from a hang. AC7.3 requires the client to keep processing input while throttled, and the floor is what delivers that. A zero rate would satisfy the first half of AC7.3 and fail the second.

**Step 4: Withholding is safe**

Callbacks accumulate across commits rather than being replaced — `merge_into` extends. So a withheld callback is not lost and no `WlCallback` is dropped un-`done()`. Phase 3 recorded this when confirming damage skipping would not conflict with this task.

**Step 5: Test**

Pure over a fake clock — no sleeps, per `CONTRIBUTING.md:140`. Cover: a surface at 10 Hz receives a callback roughly every 100 ms of virtual time; at the floor it still receives one per second; callbacks withheld across several commits are all delivered when the next send fires; changing the rate takes effect at the next interval; a surface with no rate set is unthrottled.

**Verification:** `cargo test -p lunette-compositor`

**Step 6: Commit**

```bash
git add crates/lunette-compositor/src/pacing.rs crates/lunette-compositor/src/state.rs
git commit -m "feat(compositor): throttle frame callbacks per surface"
```
<!-- END_TASK_5 -->

<!-- START_TASK_6 -->
### Task 6: Video exemption

**Verifies:** `lunette-v1.AC7.3`.

**Files:**
- Modify: `crates/lunette-compositor/src/state.rs`, `lua/mullion/scale.lua`

**Step 1: Advertise `wp_content_type_v1`**

`ContentTypeState::new::<D>(&DisplayHandle)` (`content_type/mod.rs:159`) and `delegate_content_type!`. Read the per-surface value at commit through `ContentTypeSurfaceCachedState` (`:85-94`): `None`, `Photo`, `Video`, or `Game`, defaulting to `None` (`:96-102`).

There is no handler trait and no events. It is a client hint, nothing more.

**Step 2: Expose it as an enum**

Surface it to Lua as a closed set of values, not a string. A recognised closed set rides as an enum.

**Step 3: Let Lua decide what counts as video**

Adoption of `wp_content_type_v1` is thin and inconsistent — a client playing video may set nothing at all. So the hint is a strong signal, not a detector.

`docs/dev/rendering.md:73` says video is exempt by default. The native layer supplies the hint; Lua combines it with a commit-rate heuristic and decides. Putting the heuristic in Rust would be policy in the mechanism layer, which `CONTRIBUTING.md:63` forbids.

**Step 4: Test**

Cover: a surface setting `Video` reports it to Lua; a surface setting nothing reports `None`; the value is double-buffered and takes effect at commit, not before; the exemption policy in Lua is driven by both the hint and the commit rate.

**Verification:** `cargo test -p lunette-compositor`

**Step 5: Commit**

```bash
git add crates/lunette-compositor/src/state.rs lua/mullion/scale.lua
git commit -m "feat: exempt video surfaces from throttling"
```
<!-- END_TASK_6 -->
<!-- END_SUBCOMPONENT_C -->

<!-- START_TASK_7 -->
### Task 7: Damage-driven layer submission

**Verifies:** `lunette-v1.AC7.2` (extends), supports `lunette-v1.AC7.4`.

**Files:**
- Modify: `crates/lunette/src/layers/blit.rs`

**Step 1: Extend the predicate to stale claims**

Phase 3 Task 7 established the `CommitCounter` comparison. `docs/dev/rendering.md:55` extends it: "Stale claims skip their blit."

A claim whose source has not committed since its last blit does not re-blit, and the layer is still submitted — the runtime re-composites from the most recently released swapchain image, which the OpenXR specification guarantees.

**Step 2: The three cases still apply**

Unchanged counter skips; a jump beyond `MAX_DAMAGE_AGE` (4) forces a full blit; a `reset()` forces a full blit. Nothing here changes those, and re-deriving them would risk diverging.

**Step 3: Test**

Cover: a stale claim is not blitted but is still submitted; a claim whose source commits is blitted; the counter jump and reset cases behave as in Phase 3.

**Verification:** `cargo test -p lunette`

**Step 4: Commit**

```bash
git add crates/lunette/src/layers/blit.rs
git commit -m "feat: skip blits for stale layer claims"
```
<!-- END_TASK_7 -->

<!-- START_TASK_8 -->
### Task 8: Skip the projection layer

**Verifies:** `lunette-v1.AC7.4`.

**Files:**
- Modify: `crates/lunette/src/boot.rs`, `src/layers/mod.rs`

**Step 1: Skipping `getPass` is what saves the work**

`setLayers{ main = false }` only omits the `XrCompositionLayerProjection` from `XrFrameEndInfo::layers` (`headset.c:3047-3077`). By itself it saves almost nothing.

The colour swapchain is acquired **lazily**, inside `lovrHeadsetGetTexture` and `GetPass` (`headset.c:2836`, `:2861`). If nothing calls `getPass`, the acquire, the wait, the render pass, and the MSAA resolve are all genuinely skipped. If something does call it, `main = false` still pays for the acquire and `xrWaitSwapchainImage` and discards the result.

**Stock `etc/boot.lua:215` calls `lovr.headset.getPass()` unconditionally**, before checking whether `lovr.draw` exists. lunette owns its own run loop and must skip that call itself when Lua drew nothing. Comment this at the call site: the connection between "skip the projection layer" and "do not call `getPass`" is not obvious, and the cost of missing it is invisible.

`lovrSwapchainRelease` is a no-op when nothing was acquired (`headset.c:3567`), so the release at `:3031-3032` costs nothing either way.

**Step 2: Decide "Lua drew nothing"**

Lua drew nothing when no draw call was issued this frame. Panels realised on layers do not draw into the scene; only in-scene quads and mullion's own geometry do.

So the common steady state — every panel on a layer, nothing else in the scene — skips scene rendering entirely, which is exactly the case AC7.4 names.

**Step 3: Still submit a frame**

`docs/dev/rendering.md:75`: lunette always submits an XR frame; only its own scene rendering is skipped. `xrWaitFrame`, `xrBeginFrame`, and `xrEndFrame` run every cycle regardless.

Not submitting would drop lunette out of the runtime's frame loop and lose the layers along with the scene.

**Step 4: What remains**

Three OpenXR frame calls, pose prediction and update, and the quad-layer blits — themselves damage-gated by Task 7. Record this in `docs/dev/rendering.md` so "skips scene rendering" is not read as "costs nothing".

**Step 5: Test**

Cover: a frame with only layers and no draw calls does not call `getPass` and sets `main = false`; a frame with in-scene content does both; the XR frame is submitted in both cases; the transition between the two does not drop a frame.

**Verification:** `cargo test -p lunette`

**Step 6: Commit**

```bash
git add crates/lunette/src/boot.rs crates/lunette/src/layers/mod.rs
git commit -m "feat: skip scene rendering when lua draws nothing"
```
<!-- END_TASK_8 -->

<!-- START_TASK_9 -->
### Task 9: Check suite and gates

**Verifies:** All Phase 8 criteria.

**Step 1: Run the check suite**

All five commands from `CONTRIBUTING.md:171-175`, inside `nix develop`.

**Step 2: Confirm the crate boundary one last time**

Run: `cargo tree -p lunette-compositor`
Expected: no `lunette-lovr`, no GPU crate.

Run: `cargo test -p lunette-compositor` with no Vulkan ICD visible.
Expected: passes. This is the final check on AC9.4, and this phase added output, scale, and pacing code to that crate.

**Step 2B: Check the Rust file-size threshold**

`CONTRIBUTING.md` sets it at roughly 1000 lines. No earlier phase checks it, and by now several files have accumulated across phases — `crates/lunette-compositor/src/state.rs` most of all, which starts as a port of WayVR's 710-line `comp.rs` and is then amended by Phases 3, 5, 6, and 8.

Find anything over the threshold and split it along a natural seam, re-exporting from `mod.rs` so consumers see a stable API. Methods on one type can spread across several `impl` blocks in different files of the same module, so there is no visibility plumbing to do. A large inline `#[cfg(test)] mod tests` counts toward the total, and extracting it to a sibling `tests.rs` is often the whole fix.

Split on a seam, not at the line count. A cohesive single-concern file slightly over the threshold beats a fragmented one.

**Step 3: The human gates**

- A client reports only its own output — check with `wayland-info` or an equivalent inside the client's environment (AC2.5, first half).
- Approaching a panel raises its scale and the client re-renders sharper, with the layer sampling the new buffer (AC2.5).
- A backgrounded panel's client stops redrawing at full rate while remaining responsive — click it while throttled and confirm it reacts (AC7.3). Responsiveness is the half of AC7.3 that a throttle set to zero would fail.
- An idle lunette with only layers drawn skips scene rendering (AC7.4). Confirm with a GPU profiler or LÖVR's own timing that no render pass is issued, rather than inferring it from frame rate.

**Step 4: Record the findings**

Append to `docs/dev/2026-08-06-milestone-0-findings.md`: which clients honoured `wp_fractional_scale_v1` and which ignored it; whether any client set `wp_content_type_v1`; whether the scale ladder's steps were the right ones in practice; and the measured cost of an idle frame with scene rendering skipped.

**Step 5: Commit**

```bash
git add docs/dev/2026-08-06-milestone-0-findings.md
git commit -m "docs: record output, scale, and pacing findings"
```
<!-- END_TASK_9 -->

---

## Done when

- A client reports only its own output.
- Approaching a panel raises its scale, the client re-renders sharper, and the layer samples the new buffer.
- A backgrounded panel's client stops redrawing at full rate while remaining responsive to input.
- An idle lunette with only layers drawn issues no render pass.
- `lunette-compositor` still has no GPU dependency and its tests pass without one.
- All five check commands pass.

## Deliberately not in this phase

- Output transform and physical size. `docs/dev/compositor.md:18-22` specifies four fields; adding more is a design change, not an implementation detail.
- Per-output refresh as anything but advertisement. Lua sets the rate; the compositor advertises it.
- A native video detector. The hint is exposed; the heuristic is Lua's, per the mechanism-and-policy split.
- `ext-image-copy-capture-v1` and libei, both recorded as out of scope in Phase 4.
- Explicit sync, deferred in the design; implicit sync works on Mesa in practice.
