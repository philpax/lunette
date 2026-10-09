# OpenVR backend implementation plan

This is the historical implementation plan for the OpenVR work merged from `main`. Its baseline findings and branch restrictions describe that work before the merge into `plugin-system`. Current behavior and remaining validation gates are specified in [LÖVR integration](../lovr-integration.md), [Rendering](../rendering.md), [Input](../input.md), and [Build and development](../build-and-development.md).

## Goal

Implement a complete Linux SteamVR OpenVR overlay backend inside the current LÖVR fork, integrate it into lunette, and make coherent local commits along the way in the affected repositories. Preserve the LÖVR-facing rendering/input contract and useful standalone fallback; do not merge the plugin-system branch.

## Implementation Summary

Introduce private headset backend dispatch in `vendor/lovr`, preserving existing OpenXR/simulator behavior. Implement OpenVR through the official SDK C function-table ABI: native panel overlays and per-eye projection overlays for ordinary stereo scene rendering, tracking/actions/haptics, Vulkan initialization and submission, events, and lifecycle. Integrate build/configuration/definitions in lunette and lovr-docs.

The operator explicitly accepts speculative full implementation before visual headset validation. Continue past the prototype if hardware is unavailable; never report unavailable runtime or visual checks as passed. A concrete API incompatibility or failed rendering experiment is a real blocker, not permission to fake support.

The plugin-system worktree uses the same LÖVR revision. Its ordered plugin shutdown complements, but does not replace, backend shutdown before Vulkan destruction. Do not modify its worktree or duplicate its lifecycle refactor.

Relevant seams and findings:
- `vendor/lovr/src/modules/headset/headset.c` combines OpenXR, simulator, layers, and global runtime state; `headset.h` exposes opaque layers and feature flags.
- `vendor/lovr/src/modules/graphics/graphics.c:685` installs headset Vulkan creation/device-selection callbacks. Selection happens before GPU creation (`vendor/lovr/etc/boot.lua:161`).
- `vendor/lovr/src/core/gpu_vk.c:3720` destroys partially initialized GPU state internally; host-level shutdown cannot protect this path.
- `crates/lunette/src/layers/lovr.rs:129` deliberately abandons stale layer wrappers; safe native invalidation must precede removing that workaround.
- Valve recommends projection overlays for rendered 3D imagery, once per eye per frame: https://github.com/ValveSoftware/openvr/issues/1527#issuecomment-786036117 and https://github.com/ValveSoftware/openvr/issues/1309#issuecomment-840112481 . This is intended functionality, not proof of Linux visual equivalence.
- Vulkan submission requirements: https://github.com/ValveSoftware/openvr/wiki/Vulkan . Existing OpenXR texture handoff barriers are not reusable unchanged.

Scope: Linux Vulkan backend first, existing non-Linux/WebXR builds unaffected, no OpenVR scene backend, game injection, compatibility runtime, automatic live backend switching, or plugin-system merge.

## Implementation Plan

### 1. Establish repository and dependency baseline

Record dirty state, branch tips, submodule revisions, available tools, and checks before edits. Never include unrelated changes in commits. Work on the current lunette branch and the current LÖVR `lunette` patch branch; if detached, attach a clearly named continuation branch rooted at the current revision rather than committing on an unrelated branch. Do the equivalent for lovr-docs if changed. Preserve existing commits; no amend, force push, or skipped hooks.

Pin official Valve OpenVR SDK 2.15.6 commit `0924064316de3effbcd1acf1e309182a2deb1c05` in LÖVR's dependency mechanism, with its license/provenance. Use versioned interfaces from this pinned header, not the older local sample. Mirror SDK initialization's `SetSDKVersion` and error cleanup; set `NoBackside` for ordinary overlays so 2.15's default gray backing does not alter transparent scene presentation. Do not depend on `/opt/steamvr` or redistribute a locally copied SDK without provenance. Build the SDK loader from pinned sources. Use its `openvr_capi.h` and versioned `FnTable:` interfaces from C; isolate any C++ SDK loader build from the C backend. Prefer a static loader linked into LÖVR to avoid an additional installed shared-library search path; verify the upstream target/source compilation flags, required system libraries, PIC, and license. It must not load/start SteamVR merely because lunette or the checker loads LÖVR. Missing runtime is a recoverable connection failure.

Add optional `LOVR_ENABLE_OPENVR` (off upstream, on in lunette on supported Linux builds). Keep SDK source output in build directories, not the dependency source tree; upstream CMake otherwise sets outputs beneath its source directory. Other platforms build without the new dependency.

Commit this foundation after build checks and missing-runtime smoke checks.

### 2. Build deterministic native test infrastructure and private dispatch

Create focused native headset tests under LÖVR `test/native/`, with `LOVR_BUILD_HEADSET_TESTS=ON`, CTest labels `headset`, and injected runtime/Vulkan operation tables. `make check-headset` configures a dedicated build directory, builds the native test targets, and runs `ctest --test-dir <directory> --output-on-failure -L headset`; its dependency is present in `make check`. Add harness self-checks for CTest discovery, deliberately failing child-case status propagation, and execution with absent SteamVR/runtime/hardware. Test doubles replace unmanaged SteamVR and hardware, not the public Lua API. Integrate a named `make check-headset` target into `make check`, so CI uses the same checks; make native test configuration reproducible independently of a live runtime. Include a sanitizer configuration when supported.

Retain public `lovrHeadset*` / `lovrLayer*` API entry points as a facade. Extract existing OpenXR/simulator implementation behind a fixed private operations interface into dedicated files, with common config/reference counting/session-generation ownership in the facade. Do not introduce dynamic backend plugins. Cover all public entry points, including unsupported feature behavior, Vulkan callbacks, and layer operations; avoid pervasive conditional branches in the OpenXR implementation. Preserve WebXR compilation.

Add configuration `t.headset.backend = 'auto' | 'openxr' | 'openvr'`, backed by a C enum and validated Lua parser. The upstream default remains `openxr`; lunette explicitly selects `auto`. Keep `getDriver()` as runtime name, not backend selector.

Selection policy:
- `connect = false`: simulator/desktop only.
- Explicit `openxr`: preserve current OpenXR behavior, including primary-session fallback when overlay extension is absent.
- Explicit `openvr`: overlay application only; failure can retain current desktop/simulator fallback, with an actionable diagnostic, but never silently try another XR API.
- `auto` with overlay requested: probe OpenXR first without creating a primary session; select it if overlay support exists. Otherwise try OpenVR. If neither overlay path connects, reconnect OpenXR in ordinary existing fallback mode, then use desktop/simulator if unavailable.
- `auto` without overlay requested: existing OpenXR then desktop/simulator; do not select an OpenVR overlay for a requested standalone XR application.
- Probe attempts release all temporary runtime state; never have two active connections and never change backend under an existing Vulkan device. Aggregate meaningful failure reasons without treating normal absent-runtime fallback as fatal.

Commit extraction/selection and tests separately from presentation implementation.

### 3. Make native ownership and GPU teardown correct

Give layers immutable creator-backend and session-generation identity. Preserve reference counts and an intrusive/non-owning session registry. Session stop releases backend swapchains/overlay handles and GPU textures while their dependencies remain valid, invalidates surviving wrappers, and removes submission references safely. Later wrapper destruction is safe and idempotent. Reject stale or cross-session submissions atomically before replacing the existing list; stale methods fail consistently rather than accessing released resources. Keep one process-monotonic generation counter across backend/module reloads, zero while stopped.

Distinguish presentation stop from runtime disconnect. OpenVR stop hides/destroys presentation resources but retains the connection for start on the same GPU. Full disconnect shuts down OpenVR.

Add a private GPU pre-destruction callback, dispatched through the headset facade, covering normal teardown and partial `gpu_init` failure. Define ordering as safe GPU completion, release backend presentation resources, OpenVR shutdown, then Vulkan device/instance destruction. Hook before any referenced Vulkan resource destruction, not merely Lua finalization. Make cleanup idempotent regardless of headset/graphics finalizer order and absent/partial initialization. Avoid introducing a dependency on OpenVR into the generic GPU core.

Extend invalidation to publicly retained session textures, nested views, and passes, not just Layer wrappers. Add private live session texture/pass registries and idempotent GPU-backing invalidation; root invalidation retires descendant image views, passes release recorded references and temporary attachments/tallies/buffers. Preserve CPU wrappers as dead tombstones: metadata reads remain possible, GPU-consuming operations and new views fail. Validate dead objects before submission touches graphics locks, including recorded sampling in otherwise live passes. Final retain/release destruction of tombstones performs CPU cleanup only. Drain deferred GPU victims before destroying runtime-owned images. Do not claim this solves every unrelated graphics object retained across full module teardown.

Add failing lifetime/order tests before fixes. Compile actual graphics texture/view/pass retain/release and headset paths against fake GPU/runtime boundaries; assert no post-device-destruction calls. Include never-submitted layers, retained headset scene textures/passes, nested views, recorded stale sampling, temporary pass resources, repeated stop, restart, and delayed destruction in both orders. Once safe invalidation is demonstrated, replace lunette's stale-layer abandonment leak with normal reference release, keeping session-loss behavior unchanged. Commit native fixes and the adapter change as separate coherent commits.

### 4. Implement Vulkan panels and projection presentation

Negotiate and deduplicate required SteamVR instance/device extensions with LÖVR/lunette requests; preserve optional external-memory feature reporting and shared-memory fallback. Query the correct GPU using the created instance. A missing required adapter must prevent device creation: LÖVR otherwise silently enumerates a fallback GPU.

Expose only the private native texture/image information required for submission. Use backend-owned output textures with `TRANSFER_SRC` and sampled usage, resolved single-sample images, correct Vulkan color format and explicit color-space/alpha conventions. Submit in `TRANSFER_SRC_OPTIMAL`, restoring the renderer's tracked layout correctly on subsequent use. Integrate submission with LÖVR's queue and command completion; serialize external queue access and avoid per-frame `vkDeviceWaitIdle`/CPU fence waits as the normal path. Concrete transport algorithm: use the same Vulkan graphics queue for renderer work and runtime submissions, with one queue-external-synchronization guard covering all application queue calls and each `SetOverlayTexture` call. Submit render/resolve/copy and write-to-transfer-read barriers first; call `SetOverlayTexture` while holding the queue guard; enqueue a post-call transfer-read-to-next-write barrier and completion marker on that same queue before the next reuse. The authoritative Vulkan wiki states that runtime queue work is scheduled during the call, other threads must not access the queue until it returns, and the image remains transfer-source when submission work completes. Do not infer GPU completion from CPU return. Same-queue ordering plus the barriers protects repeated reuse; a fence/timeline completion marker submitted after the call protects retirement. Track that marker for resize/stop, retaining images until completion; normal frames do not CPU-wait for it. Renderer frame-slot fences must cover the post-runtime marker, not only pre-call rendering. On submission error assume work may have been enqueued: still record the post-call barrier/marker, hide the affected overlay, report the error, and retain resources until completion. If device loss prevents markers, transition to explicit lost-device cleanup and disconnect before device destruction, without waiting forever. Resize and teardown may wait for bounded completion/device-loss handling; no normal-frame global idle. `vulkan_handoff_trace` asserts exact render-barrier → renderer-submit → guarded runtime-call → post-call barrier/marker → next write ordering, guard exclusion, repeated reuse, partial submission errors, and retirement after marker completion. This does not assume asynchronous future runtime access to app images after the documented submission work; if runtime evidence contradicts that published contract, halt the transport path and report the blocker. Imported client textures still follow existing acquire/release rules; do not submit unowned client images directly without the required handoff.

Map LÖVR layer pose/origin/device attachment, size, viewport, stereo, supported curve/color/filter/alpha, order, immutable contents, and visibility into native overlays. Report unsupported capabilities/operations explicitly. Hide omitted layers, retain unchanged visible textures, clean up resize/replacement handles, and derive a conservative limit accounting for both eye projection overlays and stereo panel handles within `MAX_LAYERS`.

Implement `getPass`/`getTexture` and the main scene with backend-owned stereo render targets and two per-eye projection overlays, each with its corresponding frustum and render pose. Use separate per-eye images or GPU copies from LÖVR's stereo array where the overlay ABI cannot express an array layer; do not assume scene-compositor array flags apply to overlays. Preserve asymmetric frusta, infinite reverse-Z, orientation, internal scene depth/MSAA, transparent clear, and `setLayers(..., main)` behavior. Do not promise occlusion against the game's depth. No `IVRCompositor::Submit` scene frames from this backend.

Create a minimal checked-in diagnostic fixture using project's existing runtime-validation fixture conventions (extend those where present; otherwise create only the necessary test scene): animated Vulkan panel, labeled distinct eye images, world-space cubes/beam, alpha regions, moving overlays, layer removal, and scene-disabled frames. Use it for early runtime checks if available. Continue full build with visual checks pending as authorized, but stop and report if an actual failure disproves the transport design.

Commit panel transport and stereo projection support as separate tested stages.

### 5. Complete tracking, input, events, and capabilities

Use overlay `WaitFrameSync` with bounded refresh-derived timeout, not scene-only `WaitGetPoses`. Maintain useful delta/predicted time on timeout and missing/stalled scenes. Update a coherent pose/action snapshot once per frame using relative-to-now predicted poses. Do not double-wait when Lua requests both scene and layer resources, or skip pacing on native-layer-only frames.

Provide embedded/build-installed OpenVR action manifests and supported controller bindings; initialize them before event polling/action updates and never use checkout-relative or `/opt` paths. Preserve LÖVR head/left/right grip and aim vocabulary, axes/button transitions, tracking validity, velocity, haptics, seated/standing origins, recenter, quit, and disconnected devices. Unsupported tracking/model/passthrough/depth/background functions follow existing API unsupported conventions and feature flags rather than fabricating data.

Implement own visibility/focus/mount state distinctly from scene visibility. Derive main-scene visibility conservatively from scene renderer/focus/state and dashboard events; uncertainty must not enable an opaque background over another application. Document precisely the supported mapping. Test game appears/exits, dashboard shown/hidden, lost tracking, stale inputs, action errors, and stop/start.

Commit input/lifecycle completion after native regression tests.

### 6. Integrate lunette, declarations, packaging, and documentation

Enable OpenVR in `crates/lunette-lovr/build.rs`; add dependency/build-input watches (current watcher omits `deps/`). Update binding definitions if the private build macros affect layouts. Verify runtime manifests/assets locate correctly in build and installed layouts without developer paths. Update Makefile and any existing Nix/package recipe so the pin/assets and tests are reproducible.

Set shipped `etc/xdg/lunette/conf.lua` to explicit `auto`, preserving desktop fallback; update misleading OpenXR-only comments and capabilities explanations. Update backend configuration metadata in `vendor/lovr-docs`, not generated declarations by hand. Regenerate with `cargo run -p lunette-generate-definitions`. Preserve native API/standard-library split; no backend checks scattered across mullion.

Update normative `docs/dev/architecture.md`, `overview.md`, `lovr-integration.md`, `rendering.md`, and `input.md` where behavior changes. Explain reversal of OpenVR exclusion: LÖVR retains headset ownership through an internal backend. Record the larger fork-patch exception, limitations, and visual checks pending. Keep documentation's technical register and decisions/gaps sections. Update existing build/development and user configuration documentation for selection/dependency installation; do not add unsolicited documentation files.

Commit lovr-docs metadata separately, then generated artifacts/config/build/docs in lunette referencing final submodule commits.

### 7. Validate, review, and checkpoint

Run native tests (including sanitizers where available), explicit backend/fallback process fixtures, generated-definition verification, both workspace feature sets, and full `make check`. Use nightly rustfmt and StyLua. Repair regressions; record environment blockers honestly. Do not silently skip hardware tests in the ordinary suite: put the real-runtime harness behind an explicit feature/command and fail that invocation clearly when prerequisites are absent.

Run implementation review after tests using a general subagent reviewing all changed repos, particularly API completeness, queue/layout correctness, layer lifetime, failover, and partial teardown. Fix or rebut findings; repeat after critical findings until clear or blocked.

Make local commits at each completed stage, with tests and narrowly scoped paths. Parent commits must name committed LÖVR/lovr-docs revisions, never dirty submodule contents. Operator authorized commits in the current repositories but not pushes: do not push. Clearly report that local pointers cannot be consumed by fresh clones until fork commits are published. Do not claim public distributability or merge completion. Leave working trees clean except pre-existing user changes, with a final report of commits/checks and exact diagnostic command/checklist for the operator's headset check.

## Acceptance Criteria

- AC.1: OpenVR-enabled Linux builds require no SteamVR installation paths and non-OpenVR builds remain usable. `headset_build_without_steamvr` and `headset_build_openvr_disabled` pass in isolated build/package checks.
- AC.2: Explicit selection and auto overlay preference preserve standalone fallback and never initialize two live runtimes or replace a primary scene through OpenVR. `selection_matrix`, `probe_cleanup`, and process fixture `backend_fallback_scenario` pass.
- AC.3: OpenVR disconnect precedes Vulkan destruction on normal, partial-init, and both finalizer-order paths. `gpu_teardown_order_matrix` and `partial_gpu_init_cleanup` assert exact event traces.
- AC.4: Retained/stale layers and exposed session graphics objects release safely without leaks, reject invalid GPU use/submissions atomically, and generations remain unique. `retained_layer_after_stop`, `cross_session_submission`, `layer_generation_restart`, `retained_session_texture_view_pass`, `stale_recorded_sampling`, `delayed_graphics_release_after_teardown`, and sanitizer run pass; graphics-object tests exercise actual native refcount/destruction paths.
- AC.5: Panels and stereo projection submit the correct per-eye pose/frustum/image metadata and handoff sequence; removed overlays disappear and layer-only frames work. `projection_eye_mapping`, `vulkan_handoff_trace`, `panel_property_matrix`, and `layer_only_frame` pass; real-runtime `steamvr_overlay_coexistence` verifies successful calls and unchanged scene-process identity when prerequisites exist.
- AC.6: Tracking/input/haptics, pacing, visibility and unsupported capabilities behave consistently under simulated runtime state changes. `action_snapshot_transitions` asserts pressed/released edges, disconnected-device reset, and action failures; `haptic_action_routing` asserts hand routing, duration/frequency/amplitude and error propagation; `predicted_pose_conversion` asserts asymmetric eye/aim transforms and linear/angular velocities; `tracking_origin_recenter` asserts seated/standing and stop/start reset; `frame_pacing_once` asserts one wait/update across both scene and layer requests; `overlay_frame_timeout`, `visibility_state_matrix`, and `capability_contract_matrix` assert timeout progress, game/dashboard/unknown safety, and unsupported operations respectively.
- AC.7: Normal scene and native-layer rendering coexist without disrupting existing OpenXR behavior. `main_and_native_layers`, `openxr_dispatch_regression`, and lunette `scene_skip_submission` regression tests pass.
- AC.8: Configuration declarations and packaged assets agree with runtime behavior. `backend_config_validation`, `installed_action_asset_resolution`, `make check-definitions`, and `make check-luau` pass.
- AC.9: Delivered code passes standing checks, implementation review, and is captured in coherent local commits. `make check` and `git diff --check` pass; review has no unresolved critical findings; named checkpoint `local_commit_integrity` verifies clean scoped trees and committed submodule pointers.
- AC.10: The diagnostic scene gives the operator a reproducible check of stereo, alpha, alignment, native text panels, and motion while a game remains visible. Named manual scenario `headset_visual_acceptance` is prepared; its actual pass remains explicitly pending until the operator returns. Autonomous delivery is not contingent on that pass.

- AC.11: Native infrastructure is hardware-free, discovers all headset tests, and propagates failures through CTest and Make. `native_harness_discovery`, `native_harness_failure_propagation`, and `native_harness_without_runtime` pass, including the intentionally failing child probe being observed as failure rather than swallowed.

## Test Strategy

Build missing native test infrastructure in phase 2, rather than pretending current Rust fakes test LÖVR internals. Native fake interfaces run without SteamVR/Vulkan hardware and validate state/ownership and submission traces. Unit tests cover selection/extension transforms/state machines; native integration tests exercise facade/backend/GPU cleanup with fake unmanaged APIs. Existing Rust layer/scene tests are extended to assert the new safe-release behavior.

AC mapping is given by the named tests above. Add the named tests or equivalent clearly named cases, not mere existing pass-through checks. Selection/API configuration scenarios run real LÖVR Lua with graphics/headset disabled or injected native runtimes as appropriate, following the existing exit-status test exception and temporary-directory isolation. Build/install checks validate actual SDK/asset packaging without `/opt` and with OpenVR disabled; no fresh network access during test execution.

Real-runtime harness: explicit opt-in command, bounded frame count/timeout, no fixed sleeps for readiness, capture runtime errors, coexistence scene PID, submissions and restart traces, and always cleanup. It must not launch/kill the user's game or change active runtime globally. Runtime unavailability is reported as a blocked opt-in check, not a silent skip.

The missing human perceptual oracle for AC.10 cannot be automated reliably. The operator explicitly accepted speculative implementation with that gate deferred. Provide the diagnostic scene and checklist, and separate automated results from pending visual/runtime results. Texture/pose metadata assertions do not prove visual quality.

## Review Strategy

Before handoff, request a plan_reviewer audit and address its findings. After implementation and automatable tests, dispatch a general review across lunette, LÖVR, and lovr-docs changes. Review backend API coverage, unchanged OpenXR semantics, provenance, device selection, queue synchronization, ownership across stop/reload, capability honesty, cleanup failures, and test coverage. Fix/rebut all findings and repeat on critical findings. Do not request plugin-system merge work.

## Documentation Strategy

Update existing normative and user-facing documents listed in phase 6. Record reversal reasoning and unsupported/untested semantics beside their subject. Metadata is the source of truth for declarations, generated artifacts are verified by the generator. Final report includes commands/results, local commits, pending hardware checks, and the publishing limitation; do not create a new narrative progress document.

## Risks, Blockers, and Required Decisions

- Accepted: stereo projection visual equivalence is unproven. Full implementation proceeds speculatively; actual hardware/API failure must still halt the affected path rather than silently flatten geometry or claim support.
- Accepted: operator is AFK; headset_visual_acceptance stays pending. Hardware availability determines whether the explicit runtime harness can run, not whether deterministic work proceeds.
- SDK image copy/reuse and queue semantics must be followed precisely. No unbounded texture reuse or per-frame global GPU idle workaround masquerading as completion.
- OpenXR extraction is large and must preserve defaults; keep staged commits and regression coverage to limit fork rebase grief.
- Layer lifetime changes remove a deliberate workaround only once safe invalidation is tested; plugin activation cleanup cannot solve native session ownership.
- Stop/start, source reload, GPU teardown, and runtime disconnect are different lifetimes. Keep their contracts distinct.
- Committed local submodule pointers require later publication for cloneability. Pushes are not authorized; report this explicitly rather than pushing or claiming a distributable revision.
- No plugin-system merge is included. Its shared LÖVR base was confirmed by the operator, but integration tests on that branch occur later.
