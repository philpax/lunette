# Host desktop

Mirroring the user's monitors and injecting input into them is a separate problem from running the compositor. WayVR has addressed it over several years. lunette reuses that work rather than reimplementing it.

wlx-capture remains an external git-pinned dependency rather than a vendored copy. lunette uses WayVR revision `98f800c644719d3f23a20e50bd3237c29a8082cb`. It provides capture frames independently of the renderer, including exported DMA buffers and descriptor-backed shared memory.

## Capture

`wlx-capture` ships four backends: `pipewire` (via xdg-desktop-portal over D-Bus), `wlr_dmabuf`, `wlr_screencopy`, and `xshm` for X11.

Direct `wlr-screencopy` is preferred when the host advertises the version 3 manager and the pinned `WlxClient` can initialize and uniquely match an attached monitor by logical position and size. lunette constructs the pinned `WlrScreencopyCapture`, following WayVR's `wayvr/src/overlays/screen/wl.rs`; it does not implement a separate screencopy protocol client. Each direct stream uses its own upstream Wayland client. Missing required upstream globals, a connection failure, missing protocol support, or an absent or ambiguous output match selects the existing portal/PipeWire path instead. An unavailable portal does not disable direct capture.

PipeWire via xdg-desktop-portal remains the fallback for hosts such as GNOME, KDE, and niri that do not offer this direct path. It requires a portal permission dialog on first use. A restore token is persisted so the user does not re-approve on every launch. Direct capture neither requests a portal session nor records a restore token.

The direct exporter follows WayVR's two-buffer implementation in `wayvr/src/overlays/screen/capture.rs`: it chooses the first explicit single-plane modifier supported for both import and export for the requested format, allocates two dedicated exportable images, binds their memory before exporting descriptors, and alternates them. The descriptor's offset and stride come from memory plane zero. Upstream writes into the exported descriptor; its implicit completion is converted to an owned descriptor-backed frame for lunette's existing importer. If DMA export cannot supply a buffer, the upstream backend uses its shared-memory fallback. lunette copies those pixels during the callback, removes row padding, normalizes the supported 32-bit colour layouts, and uploads or refills a LÖVR texture on the frame thread.

The built-in panels apply the captured frame's UV transform using WayVR's `ScreenPipeline::transform_uv` permutations, including all rotations and flips. The texture ledger refreshes that transform even when a frame refills or reuses an existing texture. `undefined` and `normal` sample unchanged: pinned PipeWire frames report `undefined`, while direct raw frames report the output transform. Panel proportions use the output's logical geometry rather than assuming that the host mode or captured buffer already has desktop-oriented dimensions.

### One divergence: monitor identification

WayVR's onboarding asks the user to select screens in a prescribed order, because the portal hands out anonymous streams. lunette requests every monitor in one dialog and correlates each returned stream to a `wl_output` by comparing the stream's `position` and `size` against the output's logical geometry. That works on every portal backend, and it is what wlx-overlay-s does on X11. The portal's `mapping_id` is not the mechanism: two of the three backends do not supply a usable one, and `wl_output.name` supplies a real connector name on all three. The evidence is recorded under [Decisions](#decisions) below.

This is an improvement over WayVR's approach and is a candidate for contributing upstream.

`ext-image-copy-capture-v1` support is planned as a later addition. It is the successor to the deprecated `wlr-screencopy`. Adding it to `wlx-capture` benefits WayVR as well.

### Enumeration

The monitors themselves come from the host compositor, over a Wayland connection lunette opens as a client. It binds each `wl_output`, and `zxdg_output_manager_v1` where the compositor offers one, and reads the make, the model, the connector name, the transform, the mode, and the logical geometry. The connection stays open, so a monitor plugged in, unplugged, or moved while lunette runs is seen; the roster is rebuilt and handed to both the mirror lifecycle and the pointer mapping together, so the two cannot disagree about what is attached.

Logical geometry comes from `zxdg_output_v1` where it exists. Where it does not, it is derived from `wl_output.mode` and `wl_output.scale`, with the axes swapped for a rotated output. The derived form is integer division and so is wrong on a fractional scale, which is why it is the fallback rather than the mechanism.

The binary resolves the host socket and passes it to the authoritative output watcher as a path. It retains the host's `WAYLAND_DISPLAY`, because the pinned `WlxClient` has only an environment-based constructor. The binary removes `WAYLAND_SOCKET` once during single-threaded startup, before the control thread or any capture worker starts; later upstream constructors therefore only read the environment. Lunette's spawned applications and xwayland-satellite receive Lunette's display explicitly from the compositor spawner, not through a process-wide display export. A session started only with an inherited `WAYLAND_SOCKET` and no resolvable host display has no host enumeration or direct capture.

An X11 host has no `wl_output`, so lunette sees no monitors on one. `wlx-capture` has an X11 path; v1 does not use it.

### Identity and lifecycle

Monitors receive stable identities, so Lua layout rules survive a replug or a reboot. The identity is the make and model reported in `wl_output.geometry`, falling back to a connector name such as `DP-2` where one is available, and to the monitor's logical position where neither is. The descriptor comes first because it survives a monitor moving to a different port. A Wayland client cannot read a serial, so two monitors of the same model are indistinguishable by descriptor; the second of them is identified by its connector alone, and lunette says so rather than picking one silently.

The connector name comes from `wl_output.name`, added in `wl_output` version 4, whose documented content is the connector. Both wlroots and mutter send it, which makes it a better source than the portal's `mapping_id` on every backend. A name that does not parse as a DRM connector is treated as absent rather than stored as one.

Capture starts lazily. `monitor:mirror()` first tries direct capture after graphics initialization; only a monitor that needs the fallback requests a portal session. Explicit monitor selection still requests a fresh portal grant. A successful selection replaces PipeWire streams but keeps active direct streams, and portal revocation likewise leaves direct capture running. A configuration that neither mirrors nor explicitly selects monitors never prompts.

A capture stream negotiates against the DRM formats lunette's importer accepts, and those are a property of the graphics device LÖVR creates several steps into the boot sequence. A monitor mirrored before then is remembered, and its stream opens on the first frame after the device exists. This is the same deferral the compositor thread uses, for the same reason.

Frames arrive on the selected backend's worker and enter the bounded newest-frame queue. The frame loop imports DMA buffers through the same path a hosted client's buffer takes, and uploads shared-memory pixels through the existing LÖVR texture path. The exporter creates Vulkan images but submits no GPU work. There remains one submission queue in the process. The importer answers recurring buffers with the images it already made, so the fixed direct or PipeWire buffer pool does not allocate an imported image on every frame.

The restore tokens are kept in `$XDG_STATE_HOME/lunette/screencast-tokens.toml`, falling back to `$HOME/.local/state`. They are state rather than configuration, so they do not live in the configuration directory, which may be the read-only system one.

For PipeWire, `monitor:setPaused(true)` deactivates the stream while retaining its session, and `monitor:dismiss()` drops and joins the worker. The portal session survives dismissal, so re-adding a covered monitor does not prompt again. Direct capture delegates pause, resume, requests, and stream drop to the pinned upstream implementation. Its pause is a no-op, and dropping the wrapper does not cancel or join its request worker. Dismissal and unplug remove the active mirror and texture, but do not guarantee that the upstream worker has released every resource. These inherited limitations are recorded under [Known gaps](#known-gaps).

Graphics restart replaces the sources and drops their active streams. A narrow device-lifetime guard prevents an upstream exporter retained by a detached worker from calling Vulkan through an old LÖVR device. Old export allocations are left to device teardown once this guard is closed. The guard does not cancel the upstream worker or repair its failure reporting.

[The Lua API](lua-api.md#monitors) states the surface: `lunette.monitors()`, and the fields and operations on a monitor handle.

## Input injection

Input injection into the host desktop goes through the `HidProvider` trait, whose shape follows WayVR's (WayVR upstream: `src/subsystem/hid/provider/mod.rs`). There are three providers:

- uinput: the preferred provider. It creates kernel-level virtual devices, so it works on any compositor and on X11, and can position the cursor absolutely given the monitor layout. It requires `/dev/uinput` access, granted by a udev rule or `input` group membership. Note that the `input` group also grants read access to every input device on the machine.
- wl_virtual: using `zwlr_virtual_pointer_v1` plus `zwp_virtual_keyboard_v1`. It requires no special permissions, but requires the host compositor to implement these protocols, which only the wlroots family does. KWin and mutter do not.
- dummy: performs no injection.

The providers are an ordered chain rather than a switch. uinput is tried first because it works regardless of the host compositor, then `wl_virtual`, then the dummy. Each mechanism is actually attempted, and every failure passed over is kept and reported, so a user is told what was tried and what each attempt said. A configuration override moves a named provider to the front; the rest of the chain still stands behind it. WayVR has no such chain: `HidWrapper::new` (`subsystem/input.rs:22-41`) calls one initialiser and installs the dummy on failure.

A host compositor that goes away degrades the session to the dummy provider with a logged reason. It does not abort lunette.

libei via the portal's RemoteDesktop interface is the intended long-term replacement and is planned as a future provider.

Keymaps are a parameter. `lunette-capture` takes a layout in XKB's version 1 text format and uploads it to `zwp_virtual_keyboard_v1`, so typing into a mirrored monitor respects the user's real keyboard layout; reading that layout off the host is the binary's job, not the library's. There is nothing to upload under uinput, which injects raw keycodes below the display server and leaves the layout to the host.

## Pointer mapping

A hit on a mirrored panel is normalised over the panel's desktop-oriented surface. The monitor's mapping clamps it and turns it into a position inside that monitor's logical rectangle without applying the output transform again. Rendering already corrects raw captured pixels; already-oriented portal frames likewise need no extra pointer rotation. This is equivalent to WayVR's transformed UV coordinates followed by its inverse direct-capture mouse transform, or its normal portal mouse transform. The provider then places that position on the host desktop, which it knows only as a bounding box.

The split matters. A `HidProvider` has no concept of a monitor: uinput's device spans the whole desktop in a fixed normalised range, and `zwlr_virtual_pointer_v1` takes the desktop extent on every call. Per-monitor targeting is upstream of both.

Every dimension is logical, never pixels. On a display scaled by two the two differ by that factor, and a pointer mapped through pixels lands wrong by exactly that ratio.

Clamping happens per monitor rather than to the bounding box. A non-rectangular arrangement leaves dead zones inside the box, and a hit clamped only to the box can land in the gap between two screens.

The desktop's origin and extent are recomputed on every output change and handed to the provider again. Neither provider needs anything recreated for it, which is what uinput's fixed normalised range buys.

### Known unknown: absolute uinput devices under GNOME

Whether mutter maps a bare `ABS_X`/`ABS_Y` uinput device across the whole monitor layout or binds it to a single display is unverified. wlroots spans the layout unless `wlr_cursor_map_to_output` is used, which is opt-in; GNOME may treat an absolute device as tablet-like and bind it to one display instead.

If it does bind to one, GNOME has no working absolute pointer path in v1: `zwlr_virtual_pointer_v1` is unavailable there too, and the honest answer is libei, which v1 does not implement. This is verified by observation on GNOME, not assumed.

## The input domain leak

Windows and mirrored monitors share an interface, but they do not share semantics. This difference is exposed to Lua rather than hidden.

Compositor windows have independent focus and pointer state. Each window can be pointed at by a different seat, with its own cursor. Mirrored monitors do not have this property: all mirrored monitors are driven by one `HidProvider` acting on a host desktop that has exactly one cursor and one keyboard focus. Two seats pointing at two mirrored monitors cannot produce two cursors. Typing at a mirrored monitor goes wherever the host compositor currently has focus, not necessarily to the monitor the user is looking at.

Every sink carries an input domain. Sinks in the same domain share cursor position and keyboard focus. All mirrored monitors belong to the `host` domain; each compositor window is independently addressable. Lua can query the input domain, so a panel library can report which target the host desktop currently has focused, rather than presenting inaccurate state.

The domain is a type rather than a flag, so routing is an exhaustive match: a domain added later cannot be silently unhandled. It is also per sink rather than global, which is what makes two hands pointing at two kinds of surface expressible. WayVR has one global `InputFocus { PhysicalScreen, WayVR }` (`subsystem/input.rs:10`), toggled for the whole session, and cannot express it.

The two domains route down different pipelines. A window sink's pointer and button events queue as compositor commands and are flushed at frame end, reaching the client through its seat. A host sink's are normalised over the monitor's own resolution, mapped through that monitor's logical rectangle, and handed to the `HidProvider`, which accumulates them and sends once per frame. Neither reaches the other's pipeline, in the same frame or any other.

`sink.domain` reads `'window'` or `'host'`. `sink.window` names the window a window sink reaches and `sink.monitor` names the monitor a host sink reaches; each is nil in the other domain, so a caller that has to know which it is holding is never left guessing from a number.

## Clipboard

Copying in an application on the host desktop and pasting into a terminal running inside lunette involves two compositors with two clipboards. Nothing bridges them unless lunette does.

WayVR bridges both directions, using `smithay-clipboard` plus `subsystem/clipboard/{wl,x11}.rs` on the host side, and `data_device`, `primary_selection`, `data_control`, and `ext_data_control` on the compositor side. lunette follows the same approach.

The split:

- The native layer exposes clipboard read, write, and offer-changed events for the host and for each internal seat. Format negotiation, including MIME type lists, incremental transfers over file descriptors, and large payloads, does not enter Lua. Lua sees that a format such as `text/plain` is available and can request it. A 40 MB image offer is proxied without being copied into a Lua string.
- The standard library runs the mirroring loop. The default is bidirectional and always on, because a clipboard that does not cross the boundary provides limited value. A per-seat opt-out exists for an isolated scratch panel.

Primary selection is mirrored by default as well. Middle-click paste is one of the two mechanisms by which text moves on Linux, and mirroring it matches user expectations. As a consequence, every selection made in a VR terminal overwrites the host primary selection. A single switch disables this.

## Known gap: drag-and-drop across the boundary

In-compositor drag-and-drop between two lunette windows is provided almost entirely by smithay's `data_device`. Dragging between the host desktop and lunette is not supported: the drag would have to cross a compositor boundary, and no protocol exists for this. WayVR does not support it either.

## Decisions

Choices made deliberately, recorded with their reasoning, so they are not relitigated by accident.

Monitors are correlated to portal streams by logical geometry, not by the portal's `mapping_id`. `mapping_id` looks like exactly the right tool and will be proposed again, so the evidence is recorded here. It was introduced in ScreenCast portal version 5 to match a libei region in a RemoteDesktop session, not to name an output, and its content is backend-defined. xdg-desktop-portal-wlr sets it to the `wl_output` name, which on wlroots is the DRM connector name (`src/screencast/screencast.c:666-668`) — the case that makes it look right. mutter sets it to `g_uuid_string_random()` from a per-EIS table (`src/backends/meta-eis.c:526-538`), which names nothing and changes every session, and emits it only when the ScreenCast session is attached to a RemoteDesktop session (`src/backends/meta-screen-cast-stream.c:426-440`); a plain ScreenCast session on GNOME gets none. xdg-desktop-portal-kde never emits it. So the field yields a connector name on wlroots, an unstable random string on GNOME under one session shape, and nothing on KDE. The portable mechanism is correlating each stream's `position` and `size` against `wl_output` logical geometry, which is what wlx-overlay-s itself does. `mapping_id` is not read at all, because `wl_output.name` supersedes it: version 4 of `wl_output` added a `name` event whose documented content is the connector name, and both wlroots and mutter send it. That is a real connector name on every backend rather than on one, and it arrives from the compositor lunette is already talking to rather than from the portal. It is still parsed against the kernel's list of connector types before being stored, because a compositor is free to put anything there and a name that is not a connector must not be recorded as one.

Monitor identity is make and model, then connector, then position, and is weaker than a compositor's. A Wayland client cannot read a serial: the `wl_output.geometry` event carries make and model only, and the EDID blob is available to whoever owns the DRM device. niri, which does own it, keys on `"{make} {model} {serial}"` and falls back to the connector. lunette copies that shape without the serial, so two monitors of the same model report one descriptor and cannot be told apart by it. The later of the two is therefore demoted to its connector alone, following niri's rule for the case where a serial does collide; where no connector is available either — GNOME or KDE with two identical monitors — the fallback is the monitor's logical position, and lunette warns that the identity will not survive the monitors being rearranged. The alternative is silence, and a mirrored monitor attaching to the wrong screen after a restart is confusing in a way an explicit warning is not.

The host's outputs are still enumerated with the explicit-socket `wayland-client` watcher rather than through `WlxClient`. That watcher owns stable identity, logical geometry, and hotplug for both capture and input. The pinned `WlxClient` does not consume `wl_output.name` and requires additional globals; replacing the watcher would weaken existing enumeration. Direct capture receives an environment-dependent client factory from the binary and matches that client's outputs to the authoritative roster by unique logical geometry, never enumeration order.

Direct capture follows the pinned WayVR implementation without upstream API repairs or a second screencopy implementation. The host display stays in the application environment because the upstream constructor has no explicit-connection entry point. The hosted-client spawner already supplies its display explicitly, so changing its architecture is unnecessary. The one environment removal precedes all application workers, avoiding temporary display rewrites around late capture initialization. Upstream cancellation, pause, and failure-channel limitations are accepted for this integration rather than hidden behind a replacement backend.

Restore tokens are stored in a versioned file that an older lunette refuses to rewrite. The portal's restore token is single-use: the backend invalidates the one it was given and returns a new one in every `Start` response, so the store is rewritten after every grant rather than only when nothing was held. The granted `persist_mode` is recorded, never the requested one, because a backend may downgrade it and xdg-desktop-portal-wlr does (`src/screencast/screencast.c:171-181`). The file declares a format version, and a file from a later version yields no store at all rather than an empty one; the case that corrupts rather than fails is an old writer rendering its own fields over a newer file, which drops everything it does not know about. Anything unrecognised within a version this lunette does understand is refused rather than ignored, for the same reason: a field silently dropped on read is a field lost on the next write. The format is TOML, because the file holds a monitor's make and model, which is whatever its EDID says, and quoting arbitrary text is not worth handrolling.

## Known gaps

Named, not solved.

The pinned screencopy backend has no cancellation or joined-drop contract, its pause method is empty, and a worker blocked in its frame-event loop can remain detached after a monitor is dismissed or unplugged. lunette removes the mirror and texture but cannot claim that direct capture has no remaining cost. Its two exported buffers also follow upstream's reuse and synchronization behavior without a new completion fence design.

An asynchronous screencopy failure or worker exit is not reported through a channel lunette can use for runtime portal failover. Setup fallback is implemented; runtime failover is not. A started direct stream can therefore remain marked mirrored while no new frame arrives. The pinned client's required-global and hotplug roundtrip behavior is likewise inherited. Host disconnect, hotplug during an in-flight capture, rotation, and GPU-backed execution require manual acceptance testing; the logic tests do not establish those contracts.

wlx-capture discards the granted `persist_mode` before lunette can read it. `parse_start_response` (`wlx-capture/src/pipewire/mod.rs:686-691`) reads `streams` and `restore_token` and drops it, so lunette records that the backend stated no persistence rather than what it granted. It is an upstream change and it is not load-bearing — a stated persistence mode is a diagnostic — and the seam models the field, so lifting it upstream is a change to one adapter. `parse_streams` (`mod.rs:693-733`) likewise drops `mapping_id`, which no longer matters: the connector name comes from `wl_output.name`.

`monitor.width` and `monitor.height` report the host's unrotated mode, while each texture uses the captured frame's own dimensions. The built-in panels use logical geometry for proportions and apply the frame's reported UV transform, matching pinned WayVR. Unit regressions cover every rotation and flip on flat and curved geometry and logical pointer mapping; backend-specific frame dimensions and portrait presentation still need GPU-backed manual acceptance testing.

Dynamic output scale makes some clients flicker. GTK in particular re-lays-out aggressively. This is mitigated by discrete steps and hysteresis in Lua, not eliminated.
