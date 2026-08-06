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

Rust owns the layer pool; Lua supplies the priority. Swapchain allocation needs one owner and a recycling policy; ranking is application knowledge. This decision was revisited mid-design: the first proposal put the pool in Lua, and swapchain churn is what ruled it out.

mlua, not the raw C API or LuaJIT FFI. A Lua mistake must raise a catchable error, not crash the window manager.

Multi-seat by default, collapsible to one. Faking multi-seat over a single seat is the position WayVR is in; collapsing multi-seat to one seat is a small change.

Control socket over Lua eval, not a typed protocol. awesome's design has held for seventeen years. lunette changes the transport (a 0600 Unix socket, not the session D-Bus), makes it deliberate rather than incidental, and serialises properly.

Standard library on disk, not embedded. It should be legible to someone who has the binary and not the source.

Compositor tests connect over a socketpair, not a bound socket. `Connection::from_socket` and `DisplayHandle::insert_client` both take a `UnixStream` directly, so a test gives one end of a `UnixStream::pair()` to each side and the filesystem is never involved. Only the listener's own tests — bind, listen, accept, and socket-path selection — bind a real socket, in a per-test temporary directory, because that is the code under test. The real socket in [Build and development](build-and-development.md#testing) means a real Wayland connection, not a real path on disk.

The exit status is tested by spawning the binary, which is the one place a test runs a real subprocess. `boot::run` returns an `ExitCode`, which is opaque and carries no accessor, and the code that produces it cannot be reached without a live LÖVR Lua thread, so the status is observable only from outside the process. `crates/lunette/tests/exit_status.rs` runs the binary against a fixture configuration directory that opens no window and disables the audio, graphics, and headset modules, so no display, XR runtime, or sound device is needed. The exception exists because reading the status from the wrong Lua stack slot once made every exit report success while the suite stayed green.

Dead handles go inert rather than raising errors. This is a compromise, made because it is less disruptive than a race condition taking down the session.

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
