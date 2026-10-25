# LÖVR integration

## The fork

`vendor/lovr` points at `philpax/lovr`'s `lunette` branch, rebased onto upstream `dev`. Clone recursively. Patches stay narrow and additive unless they fix an upstream defect. The internal OpenVR backend is a deliberate larger exception: LÖVR still owns every headset session, and OpenXR behavior and defaults must remain intact.

The nested Luau fork retains LÖVR's vector, quaternion, and Lua-ABI additions plus mlua requirements. Its upstream updates are merged rather than rebased. Both forks use a `lunette` branch. Their `.gitmodules` entries set `update = rebase` to preserve an attached branch during ordinary submodule updates; initial clones still require attaching the branch, and an explicit `--checkout` can detach it. Submodule commits must be pushed before parent pointers; unresolved pointers break fresh clones. [Contribution rules](../../../CONTRIBUTING.md) own fork workflow.

## The patch set

The fork history is the patch inventory:

```sh
git -C vendor/lovr log --oneline upstream/dev..lunette
```

No patches have been proposed upstream. Integration plumbing keeps one Luau implementation in `liblovr.so` for both mlua and analysis. Linking a second checker copy duplicates Luau flag registration and can loop during static initialization. The shared build exports native symbols and a registration-only audio table so declaration tests do not initialize miniaudio.

Additive patches support foreign-image ownership, optional Vulkan extensions, runtime layer limits and session generations, overlay visibility, Luau entry files, physical modifier snapshots, shader-variable state restoration, stereo canvases that render each view into its own texture, CPU-written fragment density maps, and headset frame timing. Runtime declarations come from metadata and generation; call-site workarounds for wrong declarations can change behavior.

Defect fixes cover Luau loader registration, configuration without a main file, native initialization, partial resource acquisition, and buffer arrays of vectors filled from flat numbers, which wrote only the first quarter of a vec4 array. Failure paths must retain or release every acquired resource. Optional-callback inference has focused regressions but the full updated upstream Luau unit suite still has failures beyond the fork baseline. LÖVR links CodeGen in lunette builds; compiling Lua functions remains an explicit per-VM request. The Luau and LÖVR forks add hot-function counting and promotion for [tiered compilation](tiered-compilation.md).

### Luau performance

Sessions use tiered compilation unless they start with `--luau-execution interpreter`, which runs O1 interpretation. `lunette::execution` configures the LÖVR and mlua compilers together for one VM and its coroutines and changes no process-wide Luau flags. Rust-loaded functions require an explicit compile request; LÖVR's `luax_loadbufferx` applies the configured mode after loading. [Desktop benchmarks](../build-and-development.md#desktop-benchmarks) compare the execution modes.

`ExecutionMode::Interpreter` is O1 bytecode. `Optimized` is O2 bytecode with inlining. `Native` adds native compilation of every loaded module where CodeGen supports the function. `NativeMarked` forwards CodeGen's `CodeGen_OnlyNativeModules` policy, so only `--!native` modules and `@native` functions compile. The module directive lives on the original loaded chunk: a plain closure returned from a `--!native` chunk does not carry it, so a later explicit compile request on that closure emits nothing. Callers compile the original chunk before executing it; LÖVR's C loader does so automatically. `Tiered` compiles marked code at load and promotes other functions once they become hot, as [tiered compilation](tiered-compilation.md) describes. [`execution.rs`](../../../crates/lunette/src/execution.rs) documents the contract and the opt-in compiler metrics, which must be enabled before the VM's first execution configuration.

The Luau fork supports native compilation for four-component float vectors on x86-64 and ARM64. Double-vector builds reject native configuration without changing the VM's compiler options. Both generators handle the runtime's 24-byte values and 48-byte table nodes without changing the `lua_pushvector` ABI that mlua's `luau-vector4` feature matches. ARM64 validation uses cross-compilation and QEMU; ARM64 performance and macOS execution are unmeasured. Quaternion arithmetic and several vector builtins retain VM fallback paths, so a successful compile request does not establish that every function or instruction runs natively.

The mutable global environment disables Luau's builtin-call and cached-import assumptions. The fork's generators branch to the ordinary call or uncached import lookup when a guard fails and resume native execution afterwards, instead of exiting to the interpreter for the rest of the function. Sessions protect the environment instead: [`environment.rs`](../../../crates/lunette/src/environment.rs) freezes the standard library, rejects rebinding its global names, and marks the environment safe with load-time import resolution disabled, so builtin fast paths are valid and imports such as `lovr.graphics` stay live.

#### Native compile cost

On the offscreen desktop workload, all-module native compilation reduces update and draw thread CPU by a paired median of about 9% against O1 but raises startup compiler CPU from about 36 ms to about 246 ms. Marker-only compilation of the benchmark's six hot modules spends about 10 ms in the native compiler instead of about 185 ms and emits about 5% of the all-native code, with a smaller callback gain.

CodeGen reserves executable memory in arena blocks. All-native reserves 16 MiB for the initial scene and grows by roughly 12 to 16 MiB with each same-VM source reload, because Luau's `CodeAllocator` does not reuse freed blocks: collecting the old functions retires them but returns no capacity until the VM closes. Marker-only fits the initial scene and three reloads in one 4 MiB block, which does not bound memory over unlimited reloads. Enabling native compilation by default therefore needs a reload-memory policy, such as allocator reuse or VM recreation, and live-session validation. [Issue 64](https://github.com/philpax/lunette/issues/64) tracks that rollout.

#### Retained desktop optimisations

Each optimisation below is retained because a paired offscreen comparison showed a repeatable CPU reduction on its target workload. Thread CPU excludes driver workers and GPU execution, and none of these results establishes headset FPS.

UI batches upload each packed prefix to a fresh vec4 Buffer through `ui/host/private/rendering/upload.luau` and bind byte ranges, instead of decoding a nested table through `Pass:send`. This reduces draw thread CPU by about 13%. Each upload uses a distinct Buffer that `Pass:send` retains, and the renderer does not reuse an upload Buffer before a submission and retirement boundary: `beginFrame` is not such a boundary, and repeated draws before one submission must keep distinct data. A persistent upload pool requires a submission and retirement contract that the public frame API does not provide.

Window decorations publish their options only when the title or the ordered action IDs, labels, or enabled states change. `ui.store` compares table identity, so the fresh options table built on every refresh otherwise schedules a render each frame. The change reduces update thread CPU by about 36%.

The plugin manager publishes its idle Configure view only when its visible render inputs change, through `plugin-manager/private/composition/configure-publication.luau`. The skip applies only to the unfiltered Entries view with an existing selection and draft and no selected option row or active text editor; every other state publishes on each poll. The shell tracks the appearance value the UI render actually reads, so a change between scheduling and rendering cannot leave the label stale. Update thread CPU falls by about 14%.

`Graph::snapshot` keeps reverse dependent lists instead of scanning the whole graph for each instance, which makes 48-instance snapshots 70% to 95% cheaper. The desktop effect is within noise; a snapshot oracle against the nested-scan result guards ordering and binding semantics.

`lunette-contracts/quad.luau` validates projections with scalar finite and identity checks instead of temporary scan tables, which reduces production picking CPU by about 27%. It keeps every validation the table version performed. It caches no inverse, because callers can edit a pose matrix in place.

`Tree::compose` walks borrowed child lists with an explicit stack instead of cloning them recursively, which reduces chain-tree computation by a third or more; broad trees are unchanged. `Tree::compute` also skips final composition when the root and offered dimensions match and no placement-affecting change has been applied. Cached computations on deep chain and balanced trees become more than 90% cheaper, at a cost of up to about 5% on layouts that change every call. A composed NaN keeps composition invalid, because NaN differs on every report. Test-local recursive and always-compose oracles compare placement bits, stored reports, and failures.

### Shader pipeline cache lifetimes

Pipelines belong to the shader specialization that creates them. Clones share GPU shader backing but retain separate caches. Release removes CPU cache entries and defers native destruction until submitted work completes. The upstream address-keyed global cache can select stale pipelines after address reuse and accumulate entries across released lifetimes. This is an upstream defect, not lunette policy.

Native lifetime tests and real offscreen rendering check retirement and reacquisition. They do not establish headset presentation. [Backdrop rendering](../../../lua/lunette-plugins/environment/backdrop/README.md) owns its remaining visual acceptance.

## Backend selection

Selection occurs before Vulkan creation because runtime extensions, adapter choice, and presentation resources belong to one backend. GPU or presentation-start failure never triggers fallback. Pending cleanup blocks another connection and device creation. Stop/start reuse the selected connection; full teardown permits selection again.

Explicit OpenXR preserves upstream behavior. Explicit OpenVR connects as an overlay and falls back only to simulation. Automatic overlay selection probes overlay-capable OpenXR before OpenVR, ordinary OpenXR, and simulation; the first probe must not claim a primary session. No connection selects simulation. `getDriver()` names the resolved runtime, while session generation establishes whether an XR session actually started.

## OpenVR ownership

Private backend operations dispatch all headset and layer calls. Layers retain their backend and session generation; inactive-generation layers cannot submit. Session retirement waits for GPU quiescence, drains deferred destruction, invalidates backing, and disconnects the runtime before Vulkan destruction. Retired GPU objects keep readable metadata but reject GPU operations, including unchecked builds. Wait errors other than device loss preserve resources for retry.

Texture handoff runs under the queue guard and forbids graphics reentry. Destruction waits until the guard is released. Failed runtime overlay destruction retains the handle and backing rather than freeing an image still referenced externally.

OpenVR uses native panel overlays and two projection-eye overlays, not scene-compositor submission. Each eye needs a separate two-dimensional image because the overlay descriptor cannot select an array layer. The scene pass therefore uses a stereo canvas: the fork records its draws once and plays them back per eye into that eye's image, with single-view pipelines and the camera offset selecting the eye. SteamVR samples a handed-off image while the next frame renders, so each eye rotates through three images. Only `lovr.headset.getTexture` renders into an array, which submission copies into the eye images. Runtime resolution changes require restart. There is no game-depth occlusion.

Foveation uses a fragment density map per eye, rebuilt every frame around the gaze that `GetEyeTrackedFoveationCenter` reports, or around the optical axis when there is none. The Frame reports gaze with Y pointing down. `lovr.headset.setFoveationOverlay` tints each eye by its density for diagnosis, and `lovr.headset.getFrameTiming` reports the backend's pacing alongside SteamVR's compositor timing.

SteamVR composites overlays asynchronously, and each overlay call is a synchronous request to its compositor process. The backend therefore sets only the overlay properties that changed and never hides a visible overlay to update it, since a hidden overlay drops out of whichever frame SteamVR composites in the meantime. A failed update hides the overlay rather than show a partial configuration.

`WaitFrameSync` returns as the compositor begins a frame that is already bound for the next vsync, so content submitted afterwards reaches a later compositor frame. Poses are predicted for the vsync of the first compositor frame that begins after the previous frame's measured work, at most three frames ahead, and two frames never target the same vsync.

Projection transforms use the inverse eye pose and vertically reversed projection tangents at the runtime call; rendering still uses the eye pose and ordinary tangents. This follows SteamVR's OpenXR implementation because the SDK omits the convention. Reversing it makes scene content move with the head.

Frame update waits and samples predicted tracking; getters do not wait. Regressed or invalid predictions expose no pose or synthetic time. Dashboard focus suppresses input. Haptics use bounded pulses because accepted vibrations cannot be cancelled. Quit acknowledgement waits until the host commits to exit because callbacks can veto quit.

The trusted action bundle lives beside the real library. [Build and development](../build-and-development.md#where-things-live-at-runtime) owns resolution and packaging. Failed action updates clear stale input. Touch grip transforms remain unverified; controller binding fallback is not acceptance evidence.

## Boot

The host keeps LÖVR's callback loop. At frame start it refreshes snapshots and imports; at frame end it submits layer claims and sends compositor requests. Scene skipping wraps headset pass/texture access because obtaining a pass already acquires scene resources.

Returning a truthy value from `lovr.draw` discards the headset pass. The session can remain active and paced while rendering nothing. Native and dispatcher error boundaries are specified in [errors](lua-api.md#errors); an unprotected callback can terminate the process.

## Restart semantics

Hard restart closes Lua, graphics, and XR while the Rust compositor and clients survive. Before Lua closes, the host retrieves the borrowed device from the compositor and waits for acknowledgement. Closing Lua destroys the GPU; any other ordering risks use-after-free. The new device imports retained dmabufs again. Shared-memory content returns at the client's next commit.

[The restart implementation](../../../crates/lunette/src/restart.rs) owns the ordering. Plugin runtimes and native subscribers close first. [Source reload](lua-api.md#reload) avoids graphics teardown and covers routine iteration.

## Known gaps

GLFW in this build is X11-only. A Wayland host without `DISPLAY` cannot open the simulator window; without a window or XR session, lunette exits. GLFW errors bypass LÖVR logging and can reach stdout. Monado overlays require service mode; monolithic mode does not initialize overlay ordering correctly.

LÖVR's custom-event allocation is not freed by polling. Payload-free native events reduce the leak but do not fix it. Foreign-image synchronization and restart validation limits belong in [rendering](rendering.md) and [validation](rendering-validation.md). WebXR and live binding/presentation acceptance remain unverified by native tests.
