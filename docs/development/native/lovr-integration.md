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

Additive patches support foreign-image ownership, optional Vulkan extensions, runtime layer limits and session generations, overlay visibility, Luau entry files, physical modifier snapshots, and shader-variable state restoration. Runtime declarations come from metadata and generation; call-site workarounds for wrong declarations can change behavior.

Defect fixes cover Luau loader registration, configuration without a main file, native initialization, partial resource acquisition, and buffer arrays of vectors filled from flat numbers, which wrote only the first quarter of a vec4 array. Failure paths must retain or release every acquired resource. Optional-callback inference has focused regressions but the full updated upstream Luau unit suite still has failures beyond the fork baseline. LÖVR links CodeGen in lunette builds; compiling Lua functions remains an explicit per-VM request.

### Luau performance

[Desktop benchmarks](../build-and-development.md#desktop-benchmarks) compare O1 interpretation, O2 interpretation, and O2 native compilation when supported. Production remains at O1. `lunette::execution` configures the LÖVR and mlua compilers together for one VM and its coroutines. It changes no process-wide Luau flags. Rust-loaded functions require an explicit compile request; LÖVR's `luax_loadbufferx` applies the configured mode after loading.

The Luau fork supports native compilation for four-component float vectors on x86-64 and ARM64. Double-vector builds remain unsupported and reject native configuration without changing the VM's compiler options. Both generators handle the runtime's 24-byte values and 48-byte table nodes without changing the `lua_pushvector` ABI that mlua's `luau-vector4` feature matches. ARM64 runtime validation uses Linux cross-compilation and QEMU, not physical ARM64 hardware; ARM64 performance and macOS execution remain unmeasured. Quaternion arithmetic and several vector builtins retain VM fallback paths. A successful compile request does not establish that every function or instruction runs natively.

The benchmark verifies native execution through Luau's caller-frame inspection API and records untimed probes at entry, after the first assertion, and after representative work. Native mode requires both post-assertion probes to remain native. The probes after draw and geometry report later exits without rejecting the sample. Source-line errors remain checked in every mode. The control evaluator's deterministic runaway-chunk test verifies that the interrupt abandons an actual native frame, that a subsequent evaluation succeeds, and that syntax and runtime errors remain distinct. Executable-memory cost and live-session reload cost remain unmeasured.

The initial interpreter-only comparison on 2026-10-18 uses the benchmark added against `65750f60174677b31eec323e0d93e92f5438e9d6`, on an AMD Ryzen 9 9950X3D, x86_64 Linux 7.2.9, and Rust 1.99.0. The release executable is pinned to logical CPU 2 with `taskset -c 2`. Each mode has seven fresh-state runs, 120 warmup frames, 600 measured frames, and 20,000 geometry iterations. Compiler order alternates each round. No validation or build job runs during this comparison; ordinary workstation processes remain active. The scene contains eight textured client windows, 15 visible UI panels, and two moving hands. Its SHA-256 is `07226de9220884b98e9d06e1b10dcb110041f29f82b2e1221a7e94e41dd3251f`.

| Recorded-graphics metric, median across runs | O1 interpreter | O2 interpreter | Reduction |
|---|---:|---:|---:|
| Full frame mean | 25.187 ms | 24.610 ms | 2.3% |
| Update callback mean | 1.811 ms | 1.774 ms | 2.1% |
| Draw callback mean | 23.238 ms | 22.730 ms | 2.2% |
| Full frame p95 | 30.689 ms | 30.514 ms | 0.6% |
| Picking/geometry iteration | 25.462 us | 21.048 us | 17.3% |
| Setup | 877.4 ms | 872.1 ms | 0.6% |

[Per-run samples](../benchmarks/luau-2026-10-18.csv) retain execution order and Lua memory. All geometry checksums equal `37250.00000000051`. The median paired frame-time reduction is 1.3%, ranging from a 2.6% regression to a 7.3% reduction. The median paired geometry reduction is 16.2%, ranging from a 20.8% regression to a 24.5% reduction. These ranges show scheduling, allocation, and garbage-collection variation; they are not confidence intervals. An earlier run overlapped validation builds and is excluded.

The initial full-scene improvement is small relative to run-to-run variation. Graphics recording dominates draw time and is itself optimised in O2. These values describe the recorded-graphics workload, not a live session's CPU budget or headset FPS.

The native comparison on 2026-10-18 uses the local CodeGen changes against the same host revision, Luau `ff9af608`, and LÖVR `e395785e`. It uses the same machine, toolchain, CPU affinity, and per-run arguments, with nine fresh-state runs per mode. The execution order rotates and reverses across rounds. No build or validation job runs alongside the comparison; ordinary workstation processes remain active. The scene still contains eight textured client windows, 15 visible UI panels, and two moving hands. Its SHA-256 is `2903a8a7fc3882bdea3189be600aba59c33b0a437a91f3ed7f83b9f32e94f130`. The source differs from the initial interpreter-only scene, so only modes within one comparison are directly comparable.

| Recorded-graphics metric, median across runs | O1 interpreter | O2 interpreter | O2 native |
|---|---:|---:|---:|
| Full frame mean | 39.526 ms | 37.355 ms | 39.577 ms |
| Update callback mean | 2.921 ms | 2.758 ms | 2.987 ms |
| Draw callback mean | 36.259 ms | 34.268 ms | 36.203 ms |
| Full frame p95 | 52.200 ms | 49.863 ms | 53.797 ms |
| Picking/geometry iteration | 33.709 us | 29.533 us | 30.666 us |
| Setup | 1261.2 ms | 1238.4 ms | 1474.6 ms |

[Native-comparison samples](../benchmarks/luau-native-2026-10-18.csv) retain execution order, Lua memory, checksums, and native-frame probes. All geometry checksums equal `37250.00000000051`. O2 interpretation has a median paired frame-time reduction of 7.0% against O1, ranging from a 6.5% regression to an 11.6% reduction. Native compilation has a median paired frame-time regression of 6.5% against O2 interpretation, with regressions in every round from 4.9% to 25.5%. Against O1, native compilation has a median paired frame-time regression of 2.1%, ranging from a 13.9% regression to a 3.3% reduction. These ranges describe observed variation, not confidence intervals.

The geometry comparison has a median paired reduction of 9.0% for O2 interpretation against O1. Native compilation has a median paired regression of 7.7% against O2 interpretation, ranging from a 66.6% regression to a 28.1% reduction. Every native sample enters the frame and geometry functions in native code, then records interpreter execution after draw and geometry respectively. The probes do not attribute time to individual functions or fallback causes. Lua memory excludes executable memory.

The mutable global environment disables Luau's builtin-call and cached-import assumptions; the original generator returns to interpretation when either guard fails. The generator now branches to the ordinary call or uncached import lookup and resumes native execution afterward. Marking the environment safe without protecting its globals would permit stale builtin or import values; the change leaves the environment mutable.

An instrumented smoke run compiles and binds all 3,161 requested functions without a function-level compilation failure, but records 2,367,953 VM exits before this change. Untimed caller-frame probes and per-line exit counters place the frame and geometry functions' first exits at their initial `assert` calls. The same workload records 32,990 VM exits afterward, a 98.6% reduction, with no exits recorded in the scene module and all six caller-frame probes remaining native. [Instrumented counts](../benchmarks/luau-native-exits-2026-10-18.csv) include setup, two warmup frames, three measured frames, and the smoke harness's geometry calls, with cold-function counters enabled. These counts do not measure time spent in native code or predict frame-time gains.

The comparison after the continuation fix uses the same machine, toolchain, CPU affinity, and nine-round arguments as the initial native comparison. No build or validation job runs alongside it; ordinary workstation processes remain active. The scene SHA-256 is `4ad6aa2fd60288403a38e412eba8f4c5dd153e36b35823fbfe3589fbb7d7fc94`. Its added post-assertion probes run only during untimed validation. The compiler sources also include ARM64 support and the shared continuation fix. Only modes within this comparison are directly comparable.

| Recorded-graphics metric, median across runs | O1 interpreter | O2 interpreter | O2 native |
|---|---:|---:|---:|
| Full frame mean | 36.919 ms | 35.222 ms | 34.348 ms |
| Update callback mean | 2.689 ms | 2.639 ms | 2.655 ms |
| Draw callback mean | 33.910 ms | 32.269 ms | 31.499 ms |
| Full frame p95 | 47.718 ms | 46.680 ms | 48.969 ms |
| Picking/geometry iteration | 32.608 us | 28.727 us | 24.726 us |
| Setup | 1203.2 ms | 1237.8 ms | 1345.9 ms |

[Continuation-comparison samples](../benchmarks/luau-native-continuation-2026-10-18.csv) retain all 27 runs in execution order. Every geometry checksum equals `37250.00000000051`. All six native probes are true in every native sample and false in both interpreter modes. Native compilation has a median paired frame-time reduction of 0.5% against O2 interpretation, ranging from a 24.7% regression to a 25.4% reduction. Five rounds improve and four regress. Against O1, native compilation has a median paired reduction of 5.6%, ranging from a 26.6% regression to a 19.4% reduction. O2 interpretation has a median paired reduction of 5.1% against O1.

Native compilation has a median paired geometry reduction of 12.2% against O2 interpretation, ranging from a 21.2% regression to a 35.9% reduction. Against O1, its median paired geometry reduction is 20.7%, with reductions in every round from 5.4% to 43.2%. These paired reductions differ from ratios of the table's per-mode medians. The ranges describe observed variation, not confidence intervals.

The continuation fix removes the observed early exits but does not establish a reliable full-scene gain over O2 interpretation. Draw and graphics recording still dominate the workload, and the native p95 and setup medians are higher than O2 interpretation. Production remains at O1. A live-session measurement with real graphics remains necessary before enabling native compilation by default or completing [issue 64](https://github.com/philpax/lunette/issues/64).

### Shader pipeline cache lifetimes

Pipelines belong to the shader specialization that creates them. Clones share GPU shader backing but retain separate caches. Release removes CPU cache entries and defers native destruction until submitted work completes. The upstream address-keyed global cache can select stale pipelines after address reuse and accumulate entries across released lifetimes. This is an upstream defect, not lunette policy.

Native lifetime tests and real offscreen rendering check retirement and reacquisition. They do not establish headset presentation. [Backdrop rendering](../../../lua/lunette-plugins/environment/backdrop/README.md) owns its remaining visual acceptance.

## Backend selection

Selection occurs before Vulkan creation because runtime extensions, adapter choice, and presentation resources belong to one backend. GPU or presentation-start failure never triggers fallback. Pending cleanup blocks another connection and device creation. Stop/start reuse the selected connection; full teardown permits selection again.

Explicit OpenXR preserves upstream behavior. Explicit OpenVR connects as an overlay and falls back only to simulation. Automatic overlay selection probes overlay-capable OpenXR before OpenVR, ordinary OpenXR, and simulation; the first probe must not claim a primary session. No connection selects simulation. `getDriver()` names the resolved runtime, while session generation establishes whether an XR session actually started.

## OpenVR ownership

Private backend operations dispatch all headset and layer calls. Layers retain their backend and session generation; inactive-generation layers cannot submit. Session retirement waits for GPU quiescence, drains deferred destruction, invalidates backing, and disconnects the runtime before Vulkan destruction. Retired GPU objects keep readable metadata but reject GPU operations, including unchecked builds. Wait errors other than device loss preserve resources for retry.

Texture handoff runs under the queue guard and forbids graphics reentry. Destruction waits until the guard is released. Failed runtime overlay destruction retains the handle and backing rather than freeing an image still referenced externally.

OpenVR uses native panel overlays and two projection-eye overlays, not scene-compositor submission. Each eye needs a separate two-dimensional output because the overlay descriptor cannot select an array layer. Runtime resolution changes require restart. There is no game-depth occlusion.

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
