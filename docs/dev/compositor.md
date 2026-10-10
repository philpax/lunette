# Compositor

lunette is a Wayland compositor. Applications it spawns connect to its socket and submit dmabufs or shared-memory buffers; the compositor sizes their surfaces, routes their input, and decides when they draw.

`crates/lunette-compositor` is a hard vendor of WayVR's `backend/wayvr/`, with WayVR's vulkano import path replaced by lunette's ([Rendering](rendering.md#texture-import)). It is vendored rather than tracked because nearly every file has been modified. Capture is different: `wlx-capture` remains an external dependency ([Host desktop](host-desktop.md)). The compositor runs on its own thread and talks to the frame loop through bounded command and event channels. It starts at the first frame that has a LÖVR graphics device, because it imports buffers against that device.

## Protocols

The compositor advertises `wl_compositor` (version 6), `xdg_wm_base`, `zxdg_decoration_manager_v1`, the KDE server decoration protocol, `wl_output`, `wl_seat`, `wl_shm`, `zwp_linux_dmabuf_v1`, `wp_viewporter`, `wp_fractional_scale_v1`, `wp_content_type_v1`, `wl_data_device_manager`, `zwp_primary_selection_device_manager_v1`, `zwlr_data_control_manager_v1`, and `ext_data_control_manager_v1`. `Application::new` in `crates/lunette-compositor/src/wayvr/mod.rs` creates them.

`wp_fractional_scale_v1` decouples panel resolution from physical size, so a panel can render sharper as the user approaches. `wp_content_type_v1` is reported to Lua as `win.contentType` and not acted on natively; the pacing provider combines it with the observed commit rate ([Rendering](rendering.md#frame-pacing)). `linux-drm-syncobj-v1` is not supported ([Rendering](rendering.md#synchronisation)).

## Outputs

Clients see virtual monitors that Lua creates:

```lua
local out = lunette.newOutput { width = 1920, height = 1080, scale = 1.5, refresh = 90 }
```

WayVR advertises one output for every client. lunette gives each client only the outputs assigned to it, so each panel can have its own scale and refresh, and `xdg_toplevel.set_fullscreen` fills the panel rather than the whole workspace.

`lunette.spawn { output = out }` assigns one output to the process, and every client attributed to that process sees only that output, filtered before its first request is dispatched. A spawn naming an output that does not exist uses the default output and logs a warning. A running client cannot be reassigned: the filter is consulted only at registry advertisement and at bind, so reassignment would mean withdrawing and recreating the global. `output:setMode` changes a live output's size, scale, or refresh.

A session starts with a default output. It is shown to every client without an assignment, which includes every adopted client, because a client with no `wl_output` cannot choose a scale or refresh. The default output cannot be destroyed. When another output is destroyed, its clients' assignments are cleared and the default output's global is withdrawn and advertised again, so those clients receive it.

A scale change sends three things together: `wp_fractional_scale_v1.preferred_scale` with the exact scale in 120ths, `wl_surface.preferred_buffer_scale` with the scale rounded up, and an `xdg_toplevel.configure` with the matching logical size. A partial set produces sharp content at the wrong size. Each new surface receives its preferred scale before its first commit, and again when it binds `wp_fractional_scale_v1`. A mode change reconfigures each window on the output at its last committed size, clamped to the new logical bounds.

`refresh` is in hertz in Lua and millihertz on the wire. It is advertisement; `window:setFrameRate` paces callbacks.

The scale provider, `@lunette-plugins/scale`, applied by the `desktop/scale` entry, picks a discrete scale step from the distance to the nearest panel an output's clients appear on, with hysteresis, because some toolkits re-lay out expensively on every scale change ([Frame pacing and output scale](lua-api.md#frame-pacing-and-output-scale)).

## Decorations

lunette honours the decoration mode a client asks for through `xdg-decoration` or the KDE protocol, as WayVR does. A toplevel that asks for nothing, or withdraws its request, is told to use server-side decorations. The compositor records, for each toplevel, whether it draws its own decorations. lunette draws no server-side decorations in the client's pixels: titlebars and controls are 3D objects the standard library draws around the panel, which keeps panel pixels for content.

## Windows

A window handle reports `title`, `appId`, its committed size, `opaque`, `contentType`, its input sink, and its output. It accepts `close`, `resize`, and `setFrameRate` requests. [The Lua API](lua-api.md#handles) lists the handle.

A resize is clamped to the client's size limits and the output's logical bounds, as WayVR clamps it. The client's limits are read again at every commit. A maximum below 160 by 160 is raised to that floor, unless the output is smaller. The configure stays pending until the client commits with its serial acknowledged, and a request for the same size while it is pending is not sent again. A commit that has not acknowledged it leaves it pending.

The compositor owns hit-testing within a surface. Lua supplies a pixel coordinate on a window, and the compositor resolves it to the toplevel, a subsurface, or a popup, honouring input regions. Popups are tested first, because a popup can extend beyond its window. Within the window, only surfaces with a buffer receive input, while a popup's explicit input region claims input without one. A point outside the window and every popup reaches nothing. The far right and bottom edges belong to the window, as in WayVR, so a coordinate equal to the window's width or height still reaches the toplevel. This is ported from WayVR's `hit_test.rs`.

Windows and mirrored monitors share the textured interface (`getTexture`) and the sink interface, so code that draws or points at a panel does not depend on where its pixels come from.

## XWayland

X11 applications run through the optional `xwayland-satellite`. The compositor starts one satellite bridge when it starts. A non-empty `APPDIR` selects `usr/bin/xwayland-satellite` inside that bundle; otherwise the spawner looks it up on `PATH`. A missing executable is logged at debug level and lunette continues without X11. Any other spawn failure, or a bridge that exits after starting, is logged as a warning naming the executable and the error. Every spawned child receives the bridge's `DISPLAY` beside `WAYLAND_DISPLAY`, with toolkit hints that select Wayland first. The `xwayland` spawn option is accepted and changes nothing.

Satellite is a rootless X server that presents X11 clients as Wayland clients, so the lunette tree contains no X11 code. Override-redirect windows, `_NET_WM` hints, and transient-for are mapped onto xdg-shell as well as satellite can.

## Processes

```lua
local proc = lunette.spawn {
  argv = { 'foot' },
  env = { TERM = 'foot' },
  output = out,
}
```

`cwd` optionally sets the working directory, and `env` adds to the session's environment. The handle carries `id` and `dead`. `lunette.onProcessExited` reports exit, signal, or spawn failure, and `lunette.onProcessOutput` reports captured output.

### Attribution

A connecting client is attributed to a process so its output assignment applies. The connecting pid is often not the spawned child, because of shells, re-executing launchers, and Flatpak. lunette follows WayVR: each spawn receives a random 256-bit token in its environment, forwarded into Flatpak with `--env=`. On connect, the compositor reads the pid from the socket credentials, matches it against spawned and adopted processes, and otherwise looks for the token in `/proc/<pid>/environ`, read as bytes because an environment need not be UTF-8. `find_by_pid` in `crates/lunette-compositor/src/wayvr/process.rs` implements the match, and `accept_connection` in `crates/lunette-compositor/src/wayvr/client.rs` runs it for each connecting client.

### Adoption

A client lunette did not spawn connects through the same socket and is adopted. Running `WAYLAND_DISPLAY=wayland-20 foot` from a host terminal is a supported workflow. lunette does not reap an adopted process and samples its liveness through `/proc`. Lua holds no handle to one, and its disappearance is not reported as an exit, because `/proc` does not record its status.

### Lifecycle

The native layer reaps children and reports exit. Restarting, closing panels, and quitting on the last window are Lua policy.

Two behaviours differ from WayVR:

- lunette calls `setsid` for each child and signals its process group, so a wrapper's descendants are signalled too, and sets `PR_SET_PDEATHSIG` so children do not outlive a crashed lunette. WayVR signals only the direct child.
- lunette captures each child's stdout and stderr, logs each chunk at `info` with the process and stream, and reports it through `lunette.onProcessOutput`. WayVR inherits stdio, which is unreadable inside a headset.

There is no cgroup or systemd scope integration, no seatd integration, and no sandboxing. Spawned applications have lunette's privileges.

## Decisions

The `wl_output` global is lunette's own (`crates/lunette-compositor/src/output.rs`). Per-client filtering needs `GlobalDispatch::can_view`, but smithay's `Output::create_global` fixes the global data as `WlOutputData`, whose output field is private, so a filter cannot tell which output it is asked about. lunette's global names its output and implements bind, the `wl_output` events, surface enter and leave, and mode changes directly. This gives up smithay's per-client scale bookkeeping, which lunette replaces with `wp_fractional_scale_v1`. `zxdg_output_manager_v1` is not advertised. Identifying the output by the address of its `WlOutputData` was rejected, because the address is unknown at creation time.

`wl_compositor` is advertised at version 6 rather than smithay's default 5, because version 6 carries `wl_surface.preferred_buffer_scale` and `preferred_buffer_transform`, which deliver scale per surface without relying on `wl_output.scale` from a filtered output. The compositor therefore owes both events to every surface before its first commit, which `send_initial_surface_state` sends from surface and toplevel creation.

The default output stays as the output for unassigned clients, because adopted clients are never assigned one and many toolkits assume at least one output exists. An absent `output` in a spawn request means the default output.

### Window bookkeeping runs after dispatch, from WayVR's task queue

The `xdg_shell` handlers queue a task for a new toplevel, a destroyed toplevel, a title change, and a minimize request, as WayVR's do, and the drag-and-drop handlers queue one when a drag starts and when it drops. The compositor thread drains the queue after each dispatch and before it flushes the clients, in `crates/lunette-compositor/src/commands/mod.rs`, where WayVR drains it on its tick. A new toplevel therefore becomes a window, and receives its initial configure, in the same loop iteration that created it, and reads its title and app id at that point. Registering the window inside the handler was rejected because it would rewrite the handlers that keep the vendored code diffable against WayVR. A toplevel whose client disconnects has no client to queue the task for, so its window is removed at once.

### An adopted process's disappearance is not an exit

`/proc` shows that an adopted process is gone but not how it ended, and the protocol has no unknown status. Reporting `Exited { code: 0 }` invented a status for a process Lua never held a handle to, so the registry drops the entry without an event. An `unknown` outcome was rejected because no consumer could act on it.

### Frame pacing is a withhold and a timer, not smithay's throttle

smithay's `send_frames_surface_tree` cannot rate-limit: it always sends to surfaces on the primary scan-out output, and its throttle state is private. lunette keeps its own per-surface callback map (`crates/lunette-compositor/src/pacing.rs`). Withheld callbacks accumulate, because smithay's `SurfaceAttributes::merge_into` extends the list, and the next send answers them all, so no `wl_callback` is dropped. A withheld surface arms a one-shot timer for the earliest due surface, because a waiting client sends nothing and the event loop would otherwise sleep indefinitely. The 1 Hz floor is enforced natively so a configuration cannot freeze a live window, and clamping before deriving the interval keeps `Duration::from_secs_f64` from overflowing.

### Readvertising an output survives a racing bind by accident, not by guarantee

`OutputRegistry::readvertise` removes a global and creates its replacement non-atomically. wayland-backend resolves a bind by slot index without checking the global's serial, so a bind in flight for the old name is answered by whatever now occupies that slot. `create_global` reuses the lowest free slot, and the only globals removed at runtime are seats and outputs created after the default output, so the replacement takes the same name and the racing bind succeeds. Adding a removable global created before the default output would break this, and readvertisement would then need to stop depending on slot reuse.

## Known gaps

There is no sandboxing.

Whether a toplevel draws its own decorations is not yet reported to Lua, so `desktop/decorations` also gives a titlebar to a window that draws its own.

A client can start a drag, and the compositor tracks which seat owns it, but nothing reports the drag to Lua and nothing draws its icon.

X11 window management semantics are whatever `xwayland-satellite` provides.
