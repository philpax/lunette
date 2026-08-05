# Decisions and gaps

## Licensing and credit

lunette is **GPL-3.0-only**, because WayVR is and we use their code.

| Project | Licence | Our use |
|---|---|---|
| WayVR | GPL-3.0-only (`wayvr-ipc` is MIT) | Compositor vendored, `wlx-capture` and `HidProvider` as dependencies |
| LÖVR | MIT | Forked, linked, patched |
| awesome | GPL-2 | **Ideas only. No code.** |

awesome being GPLv2 means its code can't come into a GPLv3 project. That's fine — there's nothing to take. Every layout algorithm it has is two-dimensional, and the entire interesting question here is what those concepts mean when the walls are wherever you decided they are.

Credit is explicit and prominent. WayVR's contribution isn't incidental — galister and contributors solved capture across every Linux compositor, worked out which OpenXR extensions function on which runtime, and found the Monado input-blocking escape hatch. We're standing on that.

## Recorded decisions

Choices made deliberately, with the reasoning, so they're not relitigated by accident.

**OpenXR only; OpenVR never.** SteamVR doesn't implement `XR_EXTX_overlay`, so supporting it means a second full backend, which means routing XR outside LÖVR, which means `lovr.headset` becomes a lie. The whole architecture rests on LÖVR owning the session.

**Zero-copy import over stable per-surface textures.** Cheaper, and it's what every real compositor does. The stabilising copy is available opt-in. See [Rendering](rendering.md#texture-import) for the numbers.

**Compositor off the frame thread**, at the cost of Lua seeing snapshots rather than live state. WayVR ticks on the main thread and it works; we don't, because an overlay's value is not disturbing the game underneath.

**Rust owns the layer pool, Lua supplies the priority.** Swapchain allocation needs one owner and recycling; ranking is application knowledge. This one was argued and changed mid-design — the first proposal put the pool in Lua, and swapchain churn is what killed it.

**mlua, not raw C API or LuaJIT FFI.** A Lua mistake must raise a catchable error, not segfault the window manager.

**Multi-seat by default, collapsible to one.** Faking multi-seat over one seat is what WayVR is stuck doing; collapsing the other way is ten lines.

**Control socket over Lua eval, not a typed protocol.** awesome's design has held for seventeen years. We change the transport (0600 Unix socket, not the session D-Bus), make it deliberate rather than accidentally-on, and serialise properly.

**Standard library on disk, not embedded.** It should be legible to someone who has the binary and not the source.

**Dead handles go inert.** Ugly. Less ugly than a race taking down your desktop.

## Known gaps

Named, not solved.

**Host↔lunette drag-and-drop.** No protocol exists for a drag crossing a compositor boundary. In-compositor DnD works.

**Input blocking is Monado-only.** `libmonado`'s `BlockFlags` has no OpenXR-standard equivalent. On other runtimes, clicking a panel also reaches the application underneath.

**Multi-planar YUV costs a conversion.** LÖVR has no `VkSamplerYcbcrConversion`. Affects hardware-decoded video and some capture formats.

**Implicit sync only, for now.** Works on Mesa in practice, as WayVR demonstrates. Explicit sync needs a LÖVR patch.

**Dynamic output scale makes some clients flicker.** GTK in particular re-lays-out aggressively. Mitigated by discrete steps and hysteresis in Lua, not eliminated.

**Multi-seat is less-travelled ground.** Expect toolkit bugs around popup grabs and drag-and-drop ownership.

**XWayland semantics are whatever `xwayland-satellite` provides.** Override-redirect windows, `_NET_WM` hints, and transient-for relationships get mapped onto xdg-shell approximately.

**The `lovr.lun*` prefix squats in LÖVR's callback namespace** permanently. Distinctive enough that a collision is unlikely, but it's a bet.

**`lunctl` is root on your session.** Anything that can write to the socket owns the machine. Single-user assumption, stated loudly, never network-reachable.

**Soft reload can leak.** Timers, signal connections, and coroutines from a previous config persist unless torn down. `mullion` provides the hook; nothing forces you to use it.

**No sandboxing.** Spawned applications are as privileged as lunette.

## Deliberately left open

**`lovr.thread` and `lovr.task` access.** The lunette API is main-state only. There may eventually be a use for read-only snapshot access from worker states; the ownership rules in [Architecture](architecture.md#ownership-rules) don't preclude it, but nothing is designed for it.

**2D widget toolkit.** Deferred, and may end up as a recommended separate library rather than part of `mullion`. Ambitious UI should be a real Wayland client we spawn.

**Layout algorithms.** Genuinely unknown territory. Nothing to copy, no ancestor to consult.
