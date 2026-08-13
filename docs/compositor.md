# Compositor

lunette is a real Wayland compositor. It creates a socket, exports `WAYLAND_DISPLAY` to the processes it spawns, and their surfaces arrive as dmabufs. Applications spawned by lunette are owned by it: the compositor hands out their surfaces, sizes them, routes their input, and decides when they draw.

The implementation is a hard vendor of WayVR's `backend/wayvr/` (approximately 4.4k lines of smithay wiring) at `crates/lunette-compositor`, with the vulkano import path replaced by lunette's own ([Rendering](rendering.md)). It is vendored rather than tracked upstream because every file that matters here is one that has been modified, so syncing would cost more than it returns. Capture is different: `wlx-capture` stays an external dependency ([Host desktop](host-desktop.md)).

## Protocols

The protocol set starts from WayVR's (`inspiration/wayvr/wayvr/src/backend/wayvr/comp.rs`): compositor, xdg-shell, xdg-decoration, kde-decoration, output, seat, shm, dmabuf, viewporter, single-pixel-buffer, relative-pointer, data-device, primary-selection, data-control, ext-data-control.

Additions:

- `wp_fractional_scale_v1`. WayVR does not implement it; lunette requires it. Panel resolution and physical size are decoupled in VR, and a panel the user leans toward should render sharper. Viewporter, its prerequisite, is already present.
- `wp_content_type_v1`. A client's own statement of what it is drawing is the strongest single signal for whether throttling it would be noticed. It is a hint with no events and no way to ask, and adoption is thin, so it is reported to Lua as `win.contentType` rather than acted on natively; `mullion.pacing` combines it with an observed commit rate and decides. A heuristic in the compositor would be policy in the mechanism layer.
- `linux-drm-syncobj-v1`, eventually, for explicit sync.

## Outputs

Clients see virtual monitors that Lua creates.

```lua
local out = lunette.newOutput{ width = 1920, height = 1080, scale = 1.5, refresh = 90 }
```

WayVR advertises a single output for everything (`mod.rs:209`) and clamps windows to its bounds. lunette does not, because a shared output means one scale factor for every application, fullscreen meaning the whole window manager, and a client querying its display getting an answer unrelated to the panel it is on.

The standard library defaults to one output per spawned application. Output globals are created with a per-client filter, so each client sees only the outputs Lua assigned it. Without the filter, an application enumerating outputs would find every other window's monitor, which is confusing and affects layout decisions in some toolkits.

The assignment is made at spawn, through `lunette.spawn{ output = out }`, and it names one output. It is recorded against the process and applied to every client that process is attributed to, before that client's first request is dispatched — so the filter is already in place when the client reads the registry. A spawn naming an output that does not exist falls back to the default one and logs it, because a client shown no monitor at all is a harder failure to diagnose than a warning naming the output.

There is no way to reassign a running client, and that is deliberate rather than missing. `can_view` is consulted at registry advertisement and at bind and nowhere else, so changing a client's assignment after it has bound a `wl_output` retracts nothing: the only mechanism is to withdraw the global and create a fresh one, which the client experiences as a monitor unplugged and plugged back in. A toolkit may move or resize windows in response. Changing the mode of an output a client is already on is the supported operation, and `output:setMode` is it.

This design enables the following.

- Dynamic scale. Raising a panel's output scale as the user approaches makes the client re-render at higher resolution, and the composition layer becomes sharper. This is the largest legibility gain available, and it is not possible with a shared output.
- Refresh as policy. A background panel told 15 Hz stops burning CPU; the one the user is looking at gets 90.
- Correct fullscreen behaviour. `xdg_toplevel.set_fullscreen` resizes the panel rather than the whole workspace.

The cost is that scale changes make clients reallocate buffers and re-layout, and some do this poorly, causing flicker or, in the case of GTK, a full recompute. The standard library uses discrete scale steps with hysteresis rather than continuous adjustment. This is Lua policy, and it is tunable.

A session starts with one output, and it is what a client that was assigned none is shown. Every client adopted from outside lunette is one of those — nothing spawned it, so nothing named an output for it — and a client with no `wl_output` at all cannot pick a scale or a refresh rate. That output refuses to be destroyed for the same reason the seat every session starts with does. It is also where the clients of any other destroyed output go: the assignment naming a withdrawn output is cleared, so `can_view` falls back to the starting output, and that output's global is withdrawn and advertised again because `can_view` is consulted at advertisement and at bind and nowhere else. Without that a client would hold no `wl_output` for the rest of its life, while the compositor went on configuring it against the starting output's mode.

A client is owed three things when its output's scale changes, and they travel together. `wp_fractional_scale_v1.preferred_scale` carries the exact scale in 120ths, which is what the client renders at. `wl_surface.preferred_buffer_scale` carries the whole-number scale, the ceiling rather than the floor, which is what a client without the fractional protocol renders at and what one with it passes to `wl_surface.set_buffer_scale` before correcting the result with `wp_viewport.set_destination`. An `xdg_toplevel.configure` carries the logical size that matches. Sending only some of the three produces sharp content at the wrong size, which reads as a bug in the client rather than as a missing configure in the compositor. The preferred scale is set when a surface is created, before the client has asked for a `wp_fractional_scale_v1`, and replayed when it does — so a client never renders a first frame at the wrong scale.

Reconfiguring an output also reconfigures the windows on it, each at the size it last committed, clamped into the new logical bounds. Raising the scale of a fixed resolution shrinks those bounds, so a window that was filling the output is pulled in; lowering it leaves windows where Lua put them.

`refresh` is in hertz in Lua and in millihertz on the wire, converted at that boundary and nowhere else. It is advertisement rather than pacing: how often a surface is actually answered is `window:setFrameRate`.

The `wl_output` global is lunette's own rather than smithay's. `Output::create_global` has no filter hook, and the `can_view` that would supply one is handed a `WlOutputData` whose output field is private — so a hand-written filter could not tell which output it was being asked about. [Decisions](#decisions) below records what that costs. The filter itself is consulted at registry advertisement and again at bind, and the second is what makes it enforceable: a client that guesses a global name it was never told about is refused rather than served.

## Decorations

lunette forces server-side decorations for both `xdg-decoration` and the KDE protocol, exactly as WayVR does (`comp.rs:638`), and then draws none itself.

Clients hand over bare content. Titlebars, close buttons, and resize grips are 3D objects the standard library draws around the panel. This division suits XR: flat chrome rendered into the panel wastes pixels and is hard to target at a distance. It also stops GTK applications from spending panel space on window chrome.

## Windows

A window handle carries what the protocol provides: `title`, `appId`, size, size constraints, parent and transient relationships, popup status, and the process it belongs to. Requests go the other way: `close`, `resize`, `setActivated`, `setFullscreen`, `setMaximized`.

The native layer owns hit-testing within a surface. Lua supplies a pixel coordinate, such as (412, 88), on a given window; Rust decides that this point lies on the popup menu rather than the toplevel, honouring input regions and subsurfaces. This is protocol business, not spatial business. WayVR's `hit_test.rs` covers exactly this and ports over.

Windows and mirrored monitors reach Lua through the same interface: a texture, a size, an input sink, a capability set. A window advertises `close` and `resize`; a monitor does not. Lua code that acts on a panel does not need to branch on where its pixels came from.

## XWayland

X11 applications are supported via `xwayland-satellite`, spawned as a child process as WayVR does (`client.rs:101`), opt-in per application.

Satellite is a rootless X server that translates X11 clients into Wayland clients of the compositor. From the compositor's side, an X11 application is just another client, and there is no X11 code in the lunette tree. X11-specific window management semantics are lost as a result: override-redirect, `_NET_WM` hints, and transient-for are mapped onto xdg-shell by satellite as best it can.

smithay's built-in XWayland would provide those semantics directly, at a cost of months of work. X11 window management is its own discipline. If an application needs something satellite cannot express, that is a defect to raise against a project whose purpose is to solve it.

## Processes

```lua
local proc = lunette.spawn{
  argv = { 'foot' },
  env = { TERM = 'foot' },
  cwd = os.getenv('HOME'),
  output = out,
  xwayland = false,
}
```

Returns a handle with stable identity, `pid`, and `alive`. Exit arrives as `lovr.lunprocessexited(proc, code)`.

### Attribution

Windows carry a reference to their originating process. Getting this right needs more than pid matching, because with flatpak, shell wrappers, and re-execing launchers, the connecting pid is usually not the child that was spawned.

lunette takes WayVR's solution wholesale: generate a random auth key per spawn, export it in the child's environment (`mod.rs:1334`, forwarded through flatpak with `--env=` at `mod.rs:1318`), then on client connect read the pid from socket credentials and check `/proc/<pid>/environ` for the key (`client.rs:158`, `process.rs`'s `find_by_pid`). Pid matching is tried first, with the environment key as a fallback.

### Adoption

Processes not spawned by lunette are adopted. The lunette socket is a real Wayland socket; anything with the right `WAYLAND_DISPLAY` can connect, and running `WAYLAND_DISPLAY=wayland-20 foot` from a host terminal is one of the most useful development workflows available. Adopted processes appear with the same window events and a process handle marked `external = true`.

### Lifecycle

The native layer does the minimum: it reaps children and reports exit. There is no auto-restart, no auto-closing of panels, and no "quit when the last window closes" behaviour; all of that is Lua policy.

Two divergences from WayVR are deliberate.

- Signal the process group, not the child. WayVR's `Drop` sends SIGTERM to the direct child only (`process.rs`), so a shell wrapper's grandchildren survive. lunette calls `setsid` and signals the group, with `PR_SET_PDEATHSIG` as a backstop so a lunette crash does not strand GUI applications with no compositor to render into.
- Capture stdout and stderr. WayVR inherits stdio, so child output goes to whatever terminal started it. Debugging a spawned application inside a headset with no terminal available is impractical without this, so lunette pipes both streams, surfaces them as `lovr.lunprocessoutput` events, and mirrors them into lunette's log. The standard library can then build a log panel from this.

### Out of scope

There is no cgroup or systemd-scope integration, no seatd integration, and no sandboxing. Spawned applications are as privileged as lunette itself.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

The `wl_output` global is lunette's own rather than smithay's, because smithay's cannot be filtered. [Outputs](#outputs) requires that each client see only the outputs Lua assigned it, and `wayland-server` supplies exactly the hook for that: `GlobalDispatch::can_view(client, global_data) -> bool`, consulted at registry advertisement and again at bind, so a client that guesses a global name it was never told about is refused rather than served. What blocks the obvious implementation is that `Output::create_global` fixes the global data type as `WlOutputData`, whose `output` field is private and has no accessor — so a hand-written `can_view` is handed a value it cannot read, and cannot tell which output it is being asked about. Overriding the hook is possible; answering it is not. So `crates/lunette-compositor/src/output.rs` creates the global with a data type that names the output, and implements `bind`, the `wl_output` events, `wl_surface.enter` and `leave`, and mode changes against the protocol directly. What that gives up is smithay's `Output` — six calls, all reimplemented — and its per-client scale bookkeeping, which lunette does not want anyway because it owns the scale question outright from `wp_fractional_scale_v1`. It gives up no protocol surface: `zxdg_output_manager_v1` was never advertised, since nothing constructed an `OutputManagerState`, so the four xdg-output lines of `delegate_output!` were dispatching for a global no client could reach. The alternative considered was identifying the output by the address of the `&WlOutputData` handed to `can_view`, which is stable for the global's life; it was not taken because there is no way to learn that address at creation time, and the only route to it — a permanently connected probe client, so that creating a global provokes one `can_view` call — is a great deal of machinery resting on an ordering the backend does not promise.

`wl_compositor` is advertised at version 6 rather than the 5 smithay's `CompositorState::new` defaults to. Six is the version that carries `wl_surface.preferred_buffer_scale` and `preferred_buffer_transform`, and below it `send_surface_state` returns without sending anything — so a client would learn the whole-number scale only from `wl_output.scale`, on an output lunette's own filter may have refused it. Per-surface is also the right granularity for a compositor where each client is on its own virtual monitor. The cost falls on lunette rather than on clients: a client binds version 6 only if it implements version 6, so the two events are ones it already handles, but the compositor now owes them to every surface before that surface's first commit. That is why both `new_surface` and `new_toplevel` call `send_initial_surface_state`. A change that stops emitting them for some class of surface — a subsurface, a cursor surface, a surface reaching the compositor by a path that does not go through creation — is a conformance break rather than an omission, and the version is what makes it one.

The output every session starts with is kept as the one a client assigned none is shown, rather than removed once Lua can create outputs. A client adopted from outside lunette is never assigned one, because nothing spawned it and so nothing named an output for it, and `WAYLAND_DISPLAY=wayland-20 foot` from a host terminal is a workflow the design calls out as worth having. A client that sees no `wl_output` at all cannot pick a scale or a refresh rate, and several toolkits assume at least one exists. So it stays, it refuses to be destroyed for the reason the default seat does, and `SpawnRequest::output` being absent means it rather than meaning nothing.

### Frame pacing is a withhold and a timer, not smithay's throttle

smithay ships `send_frames_surface_tree` (`src/desktop/wayland/utils.rs:217-266`) and it is not usable for rate limiting. It sends when the surface is on the primary scan-out output **or** when the frame is overdue, so the scan-out branch bypasses the throttle entirely; using it means passing a closure that deliberately names a non-matching output, to disable half the function in order to reach the other half. Its `SurfaceFrameThrottlingState` is declared without `pub`, so it cannot be named, reset, or inspected, and there is nowhere to hang a per-surface override.

lunette paces its own per-surface callback map instead. Phase 3 recorded the ground that makes withholding safe: damage lives in `RendererSurfaceState` and callbacks in `SurfaceAttributes`, so the two policies do not interact, and smithay's `SurfaceAttributes::merge_into` extends the callback list rather than replacing it — a surface that commits three times while withheld holds all three callbacks, and all three are answered by the next send. Nothing is lost and no `wl_callback` is dropped without its `done`.

Withholding requires a timer, and this is the part that is easy to miss. A client waiting on a frame callback sends nothing, and the compositor's event loop runs with no timeout because every source is registered up front. Without a wakeup the withheld callback would wait for unrelated traffic, which for an idle throttled window is indefinitely — the throttle would produce exactly the hang it exists to avoid. So a withheld surface arms a one-shot timer at the earliest moment any withheld surface comes due, and a nearer deadline replaces an armed one so a fast surface does not wait out a slow one's interval.

The floor is enforced natively rather than left to Lua. A rate below approximately 1 Hz is paced at 1 Hz. Lua owns which window deserves which rate, but a mechanism that honours a request for zero would let a configuration produce a window that is frozen but alive, and `lunette-v1.AC7.3` requires a throttled client to keep answering input. The clamp is applied to the rate before the interval is derived from it, which also keeps `Duration::from_secs_f64` away from the overflow that the reciprocal of a very small rate would panic on.

`window:setFrameRate`, not `surface:setFrameRate`. The earlier documents named a `surface` handle that the Lua API does not have and was never going to grow: the window handle is the surface-level handle, and `win.width` and `win.height` are already documented as the surface's size. Adding a second handle naming the same thing would have been a worse answer than correcting three sentences.

### Readvertising an output survives a racing bind by accident, not by guarantee

`OutputRegistry::readvertise` removes a global and creates a replacement, and the pair is not atomic. A `wl_registry.bind` already in flight for the old registry name arrives after the removal. wayland-backend's `check_bind` (`src/rs/server_impl/registry.rs:103-129`) resolves a name to a slot index without comparing the global's serial, so the bind is answered by whatever global now occupies that slot.

Today that is the replacement. `create_global` reclaims the lowest free slot, and the only globals this compositor removes at runtime are seats and outputs — all created after the default output, and the default seat is protected — so the freed slot is the lowest free one and the new global lands on the same registry name. Measured on the default output: registry name 11 before, 11 after. The racing bind therefore succeeds against the new global.

This is an accident of allocation order. A removable global created before the default output would take the freed slot instead, the replacement would be advertised under a different name, and the racing bind would resolve to a global of another interface or to nothing — `DisplayError::InvalidObject`, which disconnects the client. Anything that adds an early global removable at runtime has to make readvertisement stop depending on slot reuse.

## Known gaps

Named, not solved.

No sandboxing. Spawned applications are as privileged as lunette.

XWayland semantics are whatever `xwayland-satellite` provides. Override-redirect windows, `_NET_WM` hints, and transient-for relationships are mapped onto xdg-shell approximately.
