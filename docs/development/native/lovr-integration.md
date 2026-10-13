# LÖVR integration

## The fork

`vendor/lovr` points at `philpax/lovr`'s `lunette` branch, rebased onto upstream `dev`. Clone recursively. Patches stay narrow and additive unless they fix an upstream defect. The internal OpenVR backend is a deliberate larger exception: LÖVR still owns every headset session, and OpenXR behavior and defaults must remain intact.

The nested Luau fork retains LÖVR's vector, quaternion, and Lua-ABI additions plus mlua requirements. Its upstream updates are merged rather than rebased. Submodule commits must be pushed before parent pointers; unresolved pointers break fresh clones. [Contribution rules](../../../CONTRIBUTING.md) own fork workflow.

## The patch set

The fork history is the patch inventory:

```sh
git -C vendor/lovr log --oneline upstream/dev..lunette
```

No patches have been proposed upstream. Integration plumbing keeps one Luau implementation in `liblovr.so` for both mlua and analysis. Linking a second checker copy duplicates Luau flag registration and can loop during static initialization. The shared build exports native symbols and a registration-only audio table so declaration tests do not initialize miniaudio.

Additive patches support foreign-image ownership, optional Vulkan extensions, runtime layer limits and session generations, overlay visibility, Luau entry files, physical modifier snapshots, and shader-variable state restoration. Runtime declarations come from metadata and generation; call-site workarounds for wrong declarations can change behavior.

Defect fixes cover Luau loader registration, configuration without a main file, native initialization, and partial resource acquisition. Failure paths must retain or release every acquired resource. Optional-callback inference has focused regressions but the full updated upstream Luau suite still fails, including additional failures beyond the fork baseline; LÖVR does not link CodeGen.

### Shader pipeline cache lifetimes

Pipelines belong to the shader specialization that creates them. Clones share GPU shader backing but retain separate caches. Release removes CPU cache entries and defers native destruction until submitted work completes. The upstream address-keyed global cache can select stale pipelines after address reuse and accumulate entries across released lifetimes. This is an upstream defect, not lunette policy.

Native lifetime tests and real offscreen rendering check retirement and reacquisition. They do not establish headset presentation. [Backdrop rendering](../../../lua/lunette-plugins/desktop/backdrop/README.md) owns its remaining visual acceptance.

## Backend selection

Selection occurs before Vulkan creation because runtime extensions, adapter choice, and presentation resources belong to one backend. GPU or presentation-start failure never triggers fallback. Pending cleanup blocks another connection and device creation. Stop/start reuse the selected connection; full teardown permits selection again.

Explicit OpenXR preserves upstream behavior. Explicit OpenVR connects as an overlay and falls back only to simulation. Automatic overlay selection probes overlay-capable OpenXR before OpenVR, ordinary OpenXR, and simulation; the first probe must not claim a primary session. No connection selects simulation. `getDriver()` names the resolved runtime, while session generation establishes whether an XR session actually started.

## OpenVR ownership

Private backend operations dispatch all headset and layer calls. Layers retain their backend and session generation; inactive-generation layers cannot submit. Session retirement waits for GPU quiescence, drains deferred destruction, invalidates backing, and disconnects the runtime before Vulkan destruction. Retired GPU objects keep readable metadata but reject GPU operations, including unchecked builds. Wait errors other than device loss preserve resources for retry.

Texture handoff runs under the queue guard and forbids graphics reentry. Destruction waits until the guard is released. Failed runtime overlay destruction retains the handle and backing rather than freeing an image still referenced externally.

OpenVR uses native panel overlays and two projection-eye overlays, not scene-compositor submission. Each eye needs a separate two-dimensional output because the overlay descriptor cannot select an array layer. Runtime resolution changes require restart. There is no game-depth occlusion.

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
