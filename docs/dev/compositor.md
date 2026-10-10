# Compositor

lunette is a Wayland compositor. Applications it spawns connect to its socket and submit dmabufs or shared-memory buffers; the compositor sizes their surfaces, routes their input, and decides when they draw.

`crates/lunette-compositor` is a hard vendor of WayVR's `backend/wayvr/`, with WayVR's buffer import replaced by lunette's ([Rendering](rendering.md#texture-import)). It is vendored rather than taken as a dependency because WayVR's backend is not a library: it is a module of the WayVR binary, ticked from WayVR's overlay loop and coupled to its renderer and IPC, while lunette runs it on its own thread behind a channel protocol and adds several seats, per-client outputs, frame pacing, and a host clipboard bridge. The files under `src/wayvr/` keep upstream's names and as much of its text as lunette can, so that a fix worth taking from WayVR is a readable diff; [PROVENANCE.md](../../crates/lunette-compositor/PROVENANCE.md) records the upstream commit, where each upstream file lands, what is left out, and the upstream defects lunette fixes. Capture is different: `wlx-capture` remains an external dependency ([Host desktop](host-desktop.md)). The compositor runs on its own thread and talks to the frame loop through bounded command and event channels. It starts at the first frame that has a LÖVR graphics device, because it imports buffers against that device.

## Protocols

The compositor advertises `wl_compositor` (version 6), `xdg_wm_base`, `zxdg_decoration_manager_v1`, the KDE server decoration protocol, `wl_output`, `wl_seat`, `wl_shm`, `zwp_linux_dmabuf_v1`, `wp_single_pixel_buffer_manager_v1`, `wp_viewporter`, `wp_fractional_scale_v1`, `wp_content_type_v1`, `zwp_relative_pointer_manager_v1`, `wl_data_device_manager`, `zwp_primary_selection_device_manager_v1`, `zwlr_data_control_manager_v1`, and `ext_data_control_manager_v1`. `Application::new` in `crates/lunette-compositor/src/wayvr/mod.rs` creates them.

`wp_viewporter` lets a client set a surface's size and the part of its buffer it shows independently of the buffer, which is how a client following `wp_fractional_scale_v1` presents a buffer larger than its surface. The committed size and the source crop follow the viewport ([Windows](#windows)), and an invalid viewport is a protocol error.

`wp_fractional_scale_v1` decouples panel resolution from physical size, so a panel can render sharper as the user approaches. `wp_content_type_v1` is reported to Lua as `win.contentType` and not acted on natively; the pacing provider combines it with the observed commit rate ([Rendering](rendering.md#frame-pacing)). `linux-drm-syncobj-v1` is not supported ([Rendering](rendering.md#synchronisation)).

A single-pixel buffer is imported as a one-pixel `wl_shm` image, so a client that fills a surface with one colour scales it with `wp_viewport`. WayVR handles the buffer type but never creates the global, so its clients cannot make one; lunette advertises it. A relative pointer reports how far a seat's pointer moved within one window, the difference between two successive positions on it, and reports no motion when the pointer enters another window, as WayVR does.

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

lunette honours the decoration mode a client asks for through `xdg-decoration` or the KDE protocol, as WayVR does. A toplevel that asks for nothing, or withdraws its request, is told to use server-side decorations. `Application` in `crates/lunette-compositor/src/wayvr/comp.rs` records, for each toplevel, whether it draws its own, and the window snapshot reports it to Lua as `win.serverSideDecorations`, which is false for a client that draws its own.

lunette draws no server-side decorations in the client's pixels: titlebars and controls are 3D objects the standard library draws around the panel, which keeps panel pixels for content. `desktop/decorations` gives every native window a titlebar, including one that draws its own, because the titlebar carries the grab and close controls that the VR path needs. How it should treat a client-decorated window is left open ([Standard library](stdlib.md#deliberately-left-open)).

## Windows

A window handle reports `title`, `appId`, its committed size, `opaque`, `contentType`, its source crop, whether it leaves its decorations to the compositor, its input sink, and its output. It accepts `close`, `resize`, and `setFrameRate` requests. [The Lua API](lua-api.md#handles) lists the handle.

The committed size is in surface coordinates: the buffer's size after its transform and scale, replaced by the `wp_viewport` destination when the client sets one, or by the size of the viewport's source rectangle when it sets only that. A client that follows `wp_fractional_scale_v1` renders a buffer at the scale times its surface size and sets the destination to the surface size, so its texture is larger than its committed size. Pointer coordinates are in the same space. The source rectangle is reported as the fraction of the buffer the surface shows, after the buffer's transform. A quarter turn exchanges the buffer's axes before either is computed, where WayVR keeps them. A source rectangle that extends outside the buffer is the `wp_viewport` protocol error `out_of_buffer`, checked after each commit as WayVR checks it. `SurfaceBufWithImage::logical_size` and `source_uv` in `crates/lunette-compositor/src/wayvr/mod.rs` compute both.

A resize is clamped to the client's size limits and the output's logical bounds, as WayVR clamps it. The client's limits are read again at every commit. A maximum below 160 by 160 is raised to that floor, unless the output is smaller. The configure stays pending until the client commits with its serial acknowledged, and a request for the same size while it is pending is not sent again. A commit that has not acknowledged it leaves it pending.

The compositor owns hit-testing within a surface. Lua supplies a pixel coordinate on a window, and the compositor resolves it to the toplevel, a subsurface, or a popup, honouring input regions. Popups are tested first, because a popup can extend beyond its window. Within the window, only surfaces with a buffer receive input, while a popup's explicit input region claims input without one. A point outside the window and every popup reaches nothing. The far right and bottom edges belong to the window, as in WayVR, so a coordinate equal to the window's width or height still reaches the toplevel. This is ported from WayVR's `hit_test.rs`.

Windows and mirrored monitors share the textured interface (`getTexture`) and the sink interface, so code that draws or points at a panel does not depend on where its pixels come from.

## Drag and drop

A client starts a drag from a press of a seat's pointer, with `wl_data_device.start_drag` quoting the press's serial, and smithay runs the drag as that pointer's grab. Lua moves the pointer between windows as it moves it for any other input, so the drag enters, moves over, and leaves each window under the pointer, and the release drops on the window under the pointer at that moment. A drag between two clients' windows works as one within a client, because both clients' data devices belong to the seat that carries it. Each seat carries its own drag, so two hands can drag at once.

A release goes to the window its button was pressed on, wherever the pointer has moved since ([Input](input.md#drag-and-drop)). A drag released after the pointer has left every window drops nowhere and cancels its source. A drag whose window unmaps or closes, or whose data source the client destroys, is cancelled by the compositor, because Lua sends no release to a window that has gone. Destroying a seat cancels its drag.

The seat snapshot reports the drag each seat carries: an identifier no other drag shares, and the icon the client gave it. The icon is a surface, so its buffers reach the frame thread as a window's do. The snapshot adds the icon's committed size and source crop, computed as a window's are, and where the icon's top-left corner sits relative to the pointer: at the pointer when the drag starts, moved by each `wl_surface.offset` the client commits. An icon without content is not reported. `crates/lunette-compositor/src/drag.rs` keeps the record, and Lua reads it as `seat.drag` ([The Lua API](lua-api.md#handles)).

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

The `xdg_shell` handlers queue a task for a new toplevel, a destroyed toplevel, a title change, and a minimize request, as WayVR's do. The compositor thread drains the queue after each dispatch and before it flushes the clients, in `crates/lunette-compositor/src/commands/mod.rs`, where WayVR drains it on its tick. A new toplevel therefore becomes a window, and receives its initial configure, in the same loop iteration that created it, and reads its title and app id at that point. Registering the window inside the handler was rejected because it would rewrite the handlers that keep the vendored code diffable against WayVR. A toplevel whose client disconnects has no client to queue the task for, so its window is removed at once.

### A drag is recorded when its handler runs

smithay's drag handlers name the seat, and lunette's seats are smithay's, so `begin_drag` and `end_drag` record the drag on that seat while the handler runs. WayVR's pointers share one seat, so it infers the pointer from the one that pressed last, which gives a drag to the wrong hand when the other presses in between, and it queues a task for its overlay. Queueing the record for the drain after dispatch was rejected, because a client commits its icon's first content and offset in the same dispatch as `start_drag`, and the commit would find no drag to belong to.

### A drag is cancelled by moving its pointer onto nothing

smithay has no call that cancels a drag, and unsetting its grab drops on whatever the drag is over. The compositor therefore first moves the seat's pointer onto nothing, which leaves the target and withdraws its offer, and then unsets the grab, which finds no target and cancels the source. The pointer then returns to the window Lua last put it over. The drain after each dispatch looks for drags to cancel, after it has removed the windows that dispatch closed.

### Upstream's files stay in their own directory

The code taken from WayVR lives in `crates/lunette-compositor/src/wayvr/`, one file per upstream file under upstream's name, with upstream's identifiers and formatting. Each of those files carries WayVR's header, and no file outside the directory does. lunette's own subsystems sit beside the directory and call into it, and a lunette addition inside an upstream file is kept to the fewest lines that reach lunette's code. Renaming upstream's types and splitting its files along lunette's seams was the earlier arrangement, and it was rejected because no file could then be diffed against WayVR, so upstream fixes such as the `wp_viewport` sizing went unnoticed. `rustfmt.toml` excludes the directory, because the house import style would reformat upstream's lines.

### The host clipboard client is not in the compositor crate

The data-control client of the host desktop lives in `crates/lunette-capture/src/clipboard`, and this crate keeps only the `HostSelectionSource` seam it implements. It is host desktop integration with no counterpart in WayVR, and keeping it here put about a thousand lines of it among the vendored code ([Host desktop](host-desktop.md#decisions)).

### An adopted process's disappearance is not an exit

`/proc` shows that an adopted process is gone but not how it ended, and the protocol has no unknown status. Reporting `Exited { code: 0 }` invented a status for a process Lua never held a handle to, so the registry drops the entry without an event. An `unknown` outcome was rejected because no consumer could act on it.

### Frame pacing is a withhold and a timer, not smithay's throttle

smithay's `send_frames_surface_tree` cannot rate-limit: it always sends to surfaces on the primary scan-out output, and its throttle state is private. lunette keeps its own per-surface callback map (`crates/lunette-compositor/src/pacing.rs`). Withheld callbacks accumulate, because smithay's `SurfaceAttributes::merge_into` extends the list, and the next send answers them all, so no `wl_callback` is dropped. A withheld surface arms a one-shot timer for the earliest due surface, because a waiting client sends nothing and the event loop would otherwise sleep indefinitely. The 1 Hz floor is enforced natively so a configuration cannot freeze a live window, and clamping before deriving the interval keeps `Duration::from_secs_f64` from overflowing.

### Readvertising an output survives a racing bind by accident, not by guarantee

`OutputRegistry::readvertise` removes a global and creates its replacement non-atomically. wayland-backend resolves a bind by slot index without checking the global's serial, so a bind in flight for the old name is answered by whatever now occupies that slot. `create_global` reuses the lowest free slot, and the only globals removed at runtime are seats and outputs created after the default output, so the replacement takes the same name and the racing bind succeeds. Adding a removable global created before the default output would break this, and readvertisement would then need to stop depending on slot reuse.

## Known gaps

There is no sandboxing.

Lua can read a drag and its icon from `seat.drag`, but nothing draws the icon.

A drag icon's subsurfaces are not reported, so only the icon's own surface can be drawn. WayVR draws the icon's whole surface tree.

X11 window management semantics are whatever `xwayland-satellite` provides.
