# Decisions and gaps

## Licensing and credit

lunette is GPL-3.0-only, because WayVR is GPL-3.0-only and lunette uses its code.

| Project | Licence | Use |
|---|---|---|
| WayVR | GPL-3.0-only (`wayvr-ipc` is MIT) | Compositor vendored, `wlx-capture` and `HidProvider` as dependencies |
| LÖVR | MIT | Forked, linked, patched |
| awesome | GPL-2 | Ideas only. No code. |

awesome being GPLv2 means its code cannot enter a GPLv3 project. This has no practical effect, because no awesome code is taken. Every layout algorithm it has is two-dimensional, and the open question in this design is what those concepts mean when the walls are wherever the user decided they are.

Credit is explicit and prominent. WayVR's contribution is not incidental: galister and contributors solved capture across every Linux compositor, worked out which OpenXR extensions function on which runtime, and found the Monado input-blocking mechanism. This design depends on that work.

## Recorded decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

OpenXR only; OpenVR never. SteamVR does not implement `XR_EXTX_overlay`. Supporting it would require a second full backend, which would require routing XR outside LÖVR, which would make `lovr.headset` inaccurate. The architecture depends on LÖVR owning the session.

Zero-copy import over stable per-surface textures. Zero-copy is cheaper and matches what other compositors do. The stabilising copy is available as an opt-in. See [Rendering](rendering.md#texture-import) for the numbers.

Compositor off the frame thread, at the cost of Lua seeing snapshots rather than live state. WayVR ticks on the main thread and this works for WayVR; lunette does not follow that arrangement because an overlay's value depends on not disturbing the application underneath.

Rust owns the layer pool; Lua supplies the priority. Layer allocation needs one owner and a recycling policy; ranking is application knowledge. This decision was revisited mid-design: the first proposal put the pool in Lua, and layer churn is what ruled it out.

The pool recycles whole `Layer` objects, not their swapchains. The original framing put the swapchain in that role, keyed by size and format; that is the obvious framing and will be proposed again, so the reason it was not taken is recorded here. LÖVR offers no way to detach one from the other. `struct Layer` embeds its `Swapchain` by value, `lovrLayerDestroy` calls `xrDestroySwapchain` inline and unconditionally, every swapchain function is `static`, and there is no setter for the swapchain a layer's `subImage` names. Patching the fork to allow it would mean splitting `Swapchain` out into a refcounted object and rewriting `subImage` on both the quad and the cylinder structs, because `lovrLayerSetCurve` copies `subImage` between them and a stale handle left in the inactive one resurfaces on a curve change. That is a behavioural change to an existing path, which the fork discipline forbids. The original framing was wrong about the unit and right about the goal, and the goal is met exactly by keeping the whole layer: everything a panel varies has a setter and lives outside `LayerInfo`, so a layer of a given size serves any panel wanting that size, and keeping the layer alive keeps its swapchain alive. Format leaves the key for a separate reason — `lovrSwapchainInit` hard-codes `VK_FORMAT_R8G8B8A8_SRGB` and session start aborts if the runtime refuses it, so there is exactly one and nothing to key on.

mlua, not the raw C API or LuaJIT FFI. A Lua mistake must raise a catchable error, not crash the window manager.

Multi-seat by default, collapsible to one. Faking multi-seat over a single seat is the position WayVR is in; collapsing multi-seat to one seat is a small change.

Control socket over Lua eval, not a typed protocol. awesome's design has held for seventeen years. lunette changes the transport (a 0600 Unix socket, not the session D-Bus), makes it deliberate rather than incidental, and serialises properly.

Standard library on disk, not embedded. It should be legible to someone who has the binary and not the source.

Compositor tests connect over a socketpair, not a bound socket. `Connection::from_socket` and `DisplayHandle::insert_client` both take a `UnixStream` directly, so a test gives one end of a `UnixStream::pair()` to each side and the filesystem is never involved. Only the listener's own tests — bind, listen, accept, and socket-path selection — bind a real socket, in a per-test temporary directory, because that is the code under test. The real socket in [Build and development](build-and-development.md#testing) means a real Wayland connection, not a real path on disk.

The exit status is tested by spawning the binary, which is the one place a test runs a real subprocess. `boot::run` returns an `ExitCode`, which is opaque and carries no accessor, and the code that produces it cannot be reached without a live LÖVR Lua thread, so the status is observable only from outside the process. `crates/lunette/tests/exit_status.rs` runs the binary against a fixture configuration directory that opens no window and disables the audio, graphics, and headset modules, so no display, XR runtime, or sound device is needed. `lovr.filesystem.setIdentity` creates a save directory on every run and fails the boot when it cannot, so each run points `XDG_DATA_HOME` at its own temporary directory and each fixture carries a distinct identity. That keeps the write inside the temporary directory, keeps two parallel runs from racing to create one shared leaf, and makes the run independent of `HOME` and of the running uid having a passwd entry. The exception exists because reading the status from the wrong Lua stack slot once made every exit report success while the suite stayed green.

Dead handles go inert rather than raising errors. This is a compromise, made because it is less disruptive than a race condition taking down the session.

An opaque dmabuf's alpha is forced by the consumer, not by the import. This leaves the same semantic problem solved two different ways in one crate: a `wl_shm` buffer is repacked on the way in, so the padding byte becomes one during the copy and the question never reaches Lua, while a dmabuf is imported without a copy, so whatever the client left in the padding byte survives to the sampler and `window.opaque` reports that it must be ignored. The asymmetry follows from zero-copy import rather than from a preference: there is no write to the dmabuf's memory to fix it in, and adding one would give up the property the import exists for. The alternative considered was a `VkComponentMapping` on the image view, which resolves it structurally at no per-frame cost and would make `window.opaque` unnecessary. It was not taken because LÖVR creates the view itself from `TextureInfo`, so it needs a fifth patch to the fork adding a swizzle field, and the patch set is kept narrow while the milestone is still measuring. It remains the right fix if a second consumer has to repeat the shader. See [Rendering](rendering.md#alpha) for what a consumer does today.

That leaves one obligation for phase 3. A composition layer hands the image to the XR runtime rather than through `lovr.draw`, so no Lua consumer exists on that path and no shader runs; the padding byte would reach the compositor as alpha. Resolving it there is lunette's own Rust, not the configuration's, so the composition-layer path either carries the swizzle patch above or forces alpha in the copy it makes before submission. Phase 3 inherits the obligation rather than the flag.

## Known gaps

Named, not solved.

Host-to-lunette drag-and-drop. No protocol exists for a drag crossing a compositor boundary. In-compositor drag-and-drop works.

Input blocking is Monado-only. `libmonado`'s `BlockFlags` has no OpenXR-standard equivalent. On other runtimes, clicking a panel also reaches the application underneath.

Multi-planar YUV costs a conversion. LÖVR has no `VkSamplerYcbcrConversion`. This affects hardware-decoded video and some capture formats.

Implicit sync only, for now. This works on Mesa in practice, as WayVR demonstrates. Explicit sync needs a LÖVR patch.

Dynamic output scale makes some clients flicker. GTK in particular re-lays-out aggressively. This is mitigated by discrete steps and hysteresis in Lua, not eliminated.

Multi-seat is less-travelled ground. Toolkit bugs around popup grabs and drag-and-drop ownership are expected.

XWayland semantics are whatever `xwayland-satellite` provides. Override-redirect windows, `_NET_WM` hints, and transient-for relationships are mapped onto xdg-shell approximately.

The `lovr.lun*` prefix squats in LÖVR's callback namespace permanently. It is distinctive enough that a collision is unlikely, but this remains an assumption rather than a guarantee.

`lunctl` has root-equivalent access to the session. Anything that can write to the socket controls the machine. This follows from the single-user assumption, stated explicitly, and the socket is never network-reachable.

Soft reload can leak. Timers, signal connections, and coroutines from a previous config persist unless torn down. `mullion` provides the hook; nothing forces its use.

No sandboxing. Spawned applications are as privileged as lunette.

## Deliberately left open

`lovr.thread` and `lovr.task` access. The lunette API is main-state only. There may eventually be a use for read-only snapshot access from worker states. The ownership rules in [Architecture](architecture.md#ownership-rules) do not preclude it, but nothing is designed for it yet.

2D widget toolkit. Deferred, and may end up as a recommended separate library rather than part of `mullion`. Ambitious UI should be a real Wayland client, spawned rather than built in.

Layout algorithms. There is no prior implementation to copy and no comparable system to consult.
