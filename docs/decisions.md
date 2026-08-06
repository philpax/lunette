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

That obligation is discharged by making composition layers opaque. A layer hands its image to the XR runtime rather than through `lovr.draw`, so no Lua consumer exists on that path and no shader runs, and the padding byte would reach the compositor as alpha. Neither of the two mechanisms named above reaches it. A `VkComponentMapping` lives on an image view, and the copy into a layer is `vkCmdCopyImage` or `vkCmdBlitImage`, both of which read the image and ignore views; and there is no way to force a component during a copy. What is left is the layer's own blend flag. `LayerProperties::PANEL` therefore clears `transparent`, LÖVR passes no `XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT`, and the runtime does not look at the layer's alpha channel at all — for every source format, before and after a client renegotiates one, with no per-frame check to bypass. Premultiplication stops being a question on this path for the same reason.

The cost is that a genuinely translucent client is composited opaque while it holds a layer. Lua chooses: a panel that wants translucency renders as an in-scene quad, where the shader path resolves alpha correctly, and one that wants sharpness claims a layer. Making transparency a per-claim property was considered and rejected: the key is fixed when the claim is made, a client's format changes under it, and a layer that had become wrong for its source would have to be revoked from the blit path rather than from the ranking.

The layer path does not use smithay's `RendererSurfaceState` for damage. `on_commit_buffer_handler` is what populates it, and its first act is `attrs.buffer.take()` — the same buffer `CompositorState::apply_commit` reads to perform the import. Calling it first, as smithay documents, therefore leaves the import path with nothing to import and no client ever displays anything; reading the buffer back out of `RendererSurfaceState` instead would move buffer ownership to smithay, which releases a `wl_buffer` when it drops its own `Arc`, and lunette already releases the same buffer itself. So lunette counts its own installs instead: `TextureLedger` stamps every texture it installs with a `SurfaceCommit` drawn from one counter for the whole session, and the blit path copies when the stamp behind a claim differs from the one it last copied. That predicate is also strictly better than the one smithay offers, because `DamageSnapshot::add` returns without incrementing when a commit posted no non-empty rectangle, so a new buffer with no damage moves neither the counter nor the damage set, while counting installs sees it.

Monitors are correlated to portal streams by logical geometry, not by the portal's `mapping_id`. `mapping_id` looks like exactly the right tool and will be proposed again, so the evidence is recorded here. It was introduced in ScreenCast portal version 5 to match a libei region in a RemoteDesktop session, not to name an output, and its content is backend-defined. xdg-desktop-portal-wlr sets it to the `wl_output` name, which on wlroots is the DRM connector name (`src/screencast/screencast.c:666-668`) — the case that makes it look right. mutter sets it to `g_uuid_string_random()` from a per-EIS table (`src/backends/meta-eis.c:526-538`), which names nothing and changes every session, and emits it only when the ScreenCast session is attached to a RemoteDesktop session (`src/backends/meta-screen-cast-stream.c:426-440`); a plain ScreenCast session on GNOME gets none. xdg-desktop-portal-kde never emits it. So the field yields a connector name on wlroots, an unstable random string on GNOME under one session shape, and nothing on KDE. The portable mechanism is correlating each stream's `position` and `size` against `wl_output` logical geometry, which is what wlx-overlay-s itself does. `mapping_id` is not read at all, because `wl_output.name` supersedes it: version 4 of `wl_output` added a `name` event whose documented content is the connector name, and both wlroots and mutter send it. That is a real connector name on every backend rather than on one, and it arrives from the compositor lunette is already talking to rather than from the portal. It is still parsed against the kernel's list of connector types before being stored, because a compositor is free to put anything there and a name that is not a connector must not be recorded as one.

Monitor identity is make and model, then connector, then position, and is weaker than a compositor's. A Wayland client cannot read a serial: the `wl_output.geometry` event carries make and model only, and the EDID blob is available to whoever owns the DRM device. niri, which does own it, keys on `"{make} {model} {serial}"` and falls back to the connector. lunette copies that shape without the serial, so two monitors of the same model report one descriptor and cannot be told apart by it. The later of the two is therefore demoted to its connector alone, following niri's rule for the case where a serial does collide; where no connector is available either — GNOME or KDE with two identical monitors — the fallback is the monitor's logical position, and lunette warns that the identity will not survive the monitors being rearranged. The alternative is silence, and a mirrored monitor attaching to the wrong screen after a restart is confusing in a way an explicit warning is not.

The host's outputs are enumerated with `wayland-client` directly rather than through `wlx-capture`'s `WlxClient`. `WlxClient` connects through `WAYLAND_DISPLAY` itself and takes no socket parameter, and `CONTRIBUTING.md` forbids a library reading the environment. That is not a stylistic objection here: lunette's entry point overwrites `WAYLAND_DISPLAY` with lunette's own socket before any other thread exists, because it has to be written while the process is single-threaded, so anything reading the variable afterwards enumerates lunette's compositor and finds one virtual output. The socket is therefore resolved by the binary before that write and passed down as a path, which is the arrangement `WlVirtualConfig` already uses for the same reason. Writing the enumeration against `wayland-client` also costs nothing: it is already in the tree, `WlxClient` carries a dmabuf and screencopy client lunette has no use for, and the eight events that matter are `wl_output`'s `geometry`, `mode`, `scale`, and `name`, plus `zxdg_output_v1`'s `logical_position` and `logical_size`.

A mirrored monitor's textures are a separate ledger from a surface's, keyed by monitor identity. Reusing `TextureLedger` would mean parameterising it over its key, and the two ledgers want different bookkeeping rather than the same bookkeeping under two keys: a surface carries a death flag, a damage flag, a stabilised copy, and a retirement schedule, because a client can exit mid-frame and Lua can ask for a copy that outlives the frame, and a monitor has none of those. What a monitor's ledger needs and a surface's does not is the image handle behind the texture, because the dmabuf importer answers a recurring PipeWire buffer with the image it already made — so without recording which image is installed, every frame from a recycled buffer would allocate a fresh texture over memory a texture already covers.

Restore tokens are stored in a versioned file that an older lunette refuses to rewrite. The portal's restore token is single-use: the backend invalidates the one it was given and returns a new one in every `Start` response, so the store is rewritten after every grant rather than only when nothing was held. The granted `persist_mode` is recorded, never the requested one, because a backend may downgrade it and xdg-desktop-portal-wlr does (`src/screencast/screencast.c:171-181`). The file declares a format version, and a file from a later version yields no store at all rather than an empty one; the case that corrupts rather than fails is an old writer rendering its own fields over a newer file, which drops everything it does not know about. Anything unrecognised within a version this lunette does understand is refused rather than ignored, for the same reason: a field silently dropped on read is a field lost on the next write. The format is TOML, because the file holds a monitor's make and model, which is whatever its EDID says, and quoting arbitrary text is not worth handrolling.

## Known gaps

Named, not solved.

A captured frame is imported only as a dmabuf. PipeWire can negotiate shared memory instead, as a memfd or a mapped pointer, and lunette refuses both by name rather than showing a black mirror. The mapped-pointer case is the awkward one: the pointer is valid only inside PipeWire's callback, so supporting it means copying every frame on the capture thread, which is the one thing the raw-forwarding arrangement exists to avoid. The refusal is counted and logged once per stream rather than per frame.

wlx-capture discards the granted `persist_mode` before lunette can read it. `parse_start_response` (`wlx-capture/src/pipewire/mod.rs:686-691`) reads `streams` and `restore_token` and drops it, so lunette records that the backend stated no persistence rather than what it granted. It is an upstream change and it is not load-bearing — a stated persistence mode is a diagnostic — and the seam models the field, so lifting it upstream is a change to one adapter. `parse_streams` (`mod.rs:693-733`) likewise drops `mapping_id`, which no longer matters: the connector name comes from `wl_output.name`.

A rotated monitor's reported resolution is the panel's mode, unrotated. `wl_output.mode` describes the panel, and whether a capture stream of a rotated output delivers frames in the panel's orientation or the desktop's has not been verified on any backend. The stream reports its own frame size and that is what the texture ends up being; `monitor.width` and `monitor.height` report the mode. The two agree on every unrotated monitor, which is every monitor observed so far.

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
