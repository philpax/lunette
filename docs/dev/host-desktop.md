# Host desktop

Mirroring the user's monitors and injecting input into them is separate from running the compositor. lunette reuses WayVR's work for both. `wlx-capture` is an external dependency pinned at WayVR revision `98f800c644719d3f23a20e50bd3237c29a8082cb`, not a vendored copy ([CONTRIBUTING.md](../../CONTRIBUTING.md) states why the pin names the monorepo). `crates/lunette-capture` wraps it, the input providers, and the host clipboard client.

## Capture

lunette prefers direct `wlr-screencopy` and falls back to PipeWire through xdg-desktop-portal.

Direct capture is used when the host advertises the version 3 screencopy manager and the pinned `WlxClient` initializes and matches the monitor uniquely by logical position and size. lunette constructs the pinned `WlrScreencopyCapture`, as WayVR's `wayvr/src/overlays/screen/wl.rs` does, with one upstream Wayland client per stream. A missing global, a connection failure, or an absent or ambiguous match selects the portal path for that monitor. Direct capture requests no portal session and stores no restore token.

The portal path serves hosts without direct capture, such as GNOME, KDE, and niri. The first use shows a permission dialog. lunette requests every monitor in one dialog and stores the restore token so later sessions do not prompt again.

The direct exporter follows WayVR's `wayvr/src/overlays/screen/capture.rs`: it picks the first single-plane modifier supported for both import and export, allocates two exportable images, and alternates them. When DMA export fails, upstream falls back to shared memory; lunette copies those pixels during the callback, removes row padding, normalises the supported 32-bit layouts, and uploads them on the frame thread.

The built-in panels apply each frame's UV transform with WayVR's `ScreenPipeline::transform_uv` permutations, covering every rotation and flip. Portal frames report `undefined` and direct frames report the output transform; `undefined` and `normal` sample unchanged. Panel proportions use the output's logical geometry.

`ext-image-copy-capture-v1`, the successor to `wlr-screencopy`, is planned as an addition to `wlx-capture`.

### Monitor identification

lunette correlates each portal stream with a `wl_output` by comparing the stream's logical `position` with the output's, as wlx-overlay-s does. WayVR instead asks the user to select screens in a prescribed order. The portal's `mapping_id` is not read ([Decisions](#decisions)).

### Enumeration

lunette connects to the host compositor as a Wayland client, binds each `wl_output` and `zxdg_output_manager_v1` where offered, and reads the make, model, connector name, transform, mode, and logical geometry. The connection stays open. On hotplug or rearrangement the roster is rebuilt and handed to the mirrors and the pointer mapping together.

Logical geometry comes from `zxdg_output_v1`. Without it, lunette derives it from the mode and scale with axes swapped for rotation; that integer division is wrong for fractional scales.

The binary resolves the host socket and passes its path to the output watcher. It keeps the host's `WAYLAND_DISPLAY`, because the pinned `WlxClient` has only an environment-based constructor, and removes `WAYLAND_SOCKET` once during single-threaded startup. Spawned applications receive lunette's display from the compositor's spawner. A session started with only an inherited `WAYLAND_SOCKET` has no host enumeration or direct capture.

An X11 host has no `wl_output`, so lunette sees no monitors there.

### Identity and lifecycle

A monitor's identity is its make and model from `wl_output.geometry`, then its connector name such as `DP-2`, then its logical position. The descriptor comes first because it survives a change of port. A Wayland client cannot read a serial, so of two monitors with the same make and model the second is identified by its connector alone, and lunette logs that. The connector name comes from `wl_output.name` (version 4); a name that does not parse as a DRM connector is treated as absent.

Capture starts lazily. `monitor:mirror()` tries direct capture and requests a portal session only for a monitor that needs the fallback. A configuration that never mirrors and never asks for monitor selection never prompts. An explicit selection requests a fresh portal grant and replaces portal streams but keeps direct ones.

A portal session ends when the user stops it from the host desktop or the backend closes it, and the backend then removes the session's PipeWire nodes. lunette watches the PipeWire registry on a connection of its own and stops the stream on each removed node. Once none of the session's nodes remain, it drops the session and keeps direct capture running. A revoked session is a refusal, as a declined dialog is: the monitors stay requested, `monitor.pending` stays true, `monitor:mirror()` returns false, and nothing asks the portal again until `lunette.selectMonitors()`, which offers no restore token. A completed selection no longer reports `ready`, so the titlebar offers Select monitors again; a selection still in flight continues. A monitor whose node alone is removed stays wanted until a later grant covers it. An unplugged monitor's node leaves the session when the roster loses the monitor, so its later removal does not revoke the rest. Removals are handled at the start of each poll, before a pending grant is taken. The stored restore token is kept, so the next run restores the grant as it would after a refusal.

Streams negotiate against the DRM formats lunette's importer accepts, which exist only once LÖVR has a graphics device. A monitor mirrored earlier opens on the first frame after the device exists. Frames arrive on the backend's worker into a bounded newest-frame queue. The frame loop imports dmabufs through the client import path and answers a recurring buffer with the image it already made. The exporter creates images but submits no GPU work.

Restore tokens are stored in `$XDG_STATE_HOME/lunette/screencast-tokens.toml`, or under `$HOME/.local/state`. They are state, not configuration, and the configuration directory may be read-only.

For portal streams, `monitor:setPaused(true)` deactivates the stream and keeps its session, and `monitor:dismiss()` drops and joins the worker while the portal session survives. Direct capture delegates pause, requests, and stream drop to upstream; its pause does nothing, and dropping it neither cancels nor joins its worker. A graphics restart replaces the sources, and a device-lifetime guard stops a detached upstream exporter from calling Vulkan through the old device.

`lua/lunette/init.luau` declares the monitor handle.

## Input injection

Host input goes through the `HidProvider` trait, shaped after WayVR's (`src/subsystem/hid/provider/mod.rs`). The providers are:

- uinput: kernel virtual devices that work on any compositor and on X11, with absolute positioning from the monitor layout. It needs `/dev/uinput` access through a udev rule or the `input` group, which also grants read access to every input device.
- wl_virtual: `zwlr_virtual_pointer_v1` and `zwp_virtual_keyboard_v1`, which need no permissions but exist only on wlroots compositors. It uploads an XKB keymap so typing follows the user's layout.
- dummy: injects nothing.

`hid::open` tries the providers as an ordered chain, uinput then wl_virtual, and falls back to the dummy. Every failure is recorded and reported. WayVR instead calls one initialiser and installs the dummy on failure.

The binary supplies the chain's configuration: the host's Wayland socket, and the layout the default seat compiles from the `XKB_DEFAULT_*` names. `zwp_virtual_keyboard_v1` disconnects a client that sends a key before a keymap, so wl_virtual uploads that layout before it reports itself open, and it reports itself unconfigured when the layout does not compile. A key or modifier change on a host sink first gives the provider its seat's layout. The provider keeps the layout it last uploaded and skips an upload that would change nothing, so the default seat's first keystroke uploads nothing further. A seat absent from the frame's snapshot has no layout, and its key is refused. uinput accepts the layout and ignores it, because the host applies its own.

A fatal failure, which is a lost connection to the host compositor, replaces the provider with the dummy at the call that reports it and logs the reason. A key, a modifier change, a layout upload, and the frame's commit can each report one. A failure that is not fatal is reported to the caller, and a failed upload is not remembered, so the next keystroke tries again.

libei through the portal's RemoteDesktop interface is the planned long-term provider.

## Pointer mapping

A hit on a mirrored panel is normalised over the panel's desktop-oriented surface. The monitor's mapping clamps it to that monitor and converts it to a position in the monitor's logical rectangle. The output transform is not applied again, because rendering already corrects captured pixels. This matches WayVR's transformed UVs followed by its inverse mouse transform. The provider places the position on the host desktop, which it knows only as a bounding box.

Per-monitor targeting happens before the provider, because no provider knows about monitors. All dimensions are logical. Clamping is per monitor, so a hit cannot land in a gap of a non-rectangular arrangement. The desktop's origin and extent are recomputed on every output change.

## The input domain leak

Windows and mirrored monitors share the sink interface but not its semantics. Each compositor window has independent focus and its own cursor per seat. Every mirrored monitor is driven by one `HidProvider` acting on a host desktop with one cursor and one keyboard focus. Two hands pointing at two monitors cannot produce two cursors, and typing at a monitor goes to whatever the host has focused.

Every sink carries an input domain. `sink.domain` is `'window'` or `'host'`. Routing matches on the domain exhaustively. A window sink's events become compositor commands flushed at frame end and reach the client through its seat. A host sink's events are mapped through the monitor's logical rectangle and accumulated by the provider, which sends once per frame. WayVR has one global `InputFocus` and cannot express two hands on two kinds of surface.

## Clipboard

lunette bridges the clipboard and primary selection between its clients and the host. The compositor advertises `wl_data_device`, `zwp_primary_selection_v1`, `zwlr_data_control_v1`, and `ext_data_control_v1` to its clients, and uses the host's data-control protocols as a client. The client is `DataControlSource` in `crates/lunette-capture/src/clipboard`, which implements the compositor's `HostSelectionSource` seam. One designated seat's selections are the host's; `seat:setClipboardBridge` chooses it. Transfers pass file descriptors between the owning processes, and lunette buffers nothing. [Input](input.md#clipboard) states the contract.

Drag-and-drop between the host desktop and lunette is not supported, because no protocol carries a drag across a compositor boundary. WayVR does not support it either. Drag-and-drop between lunette windows is smithay's `data_device`.

## Decisions

Portal streams are correlated by logical geometry, not by `mapping_id`. ScreenCast portal version 5 added `mapping_id` to match libei regions, and its content is backend-defined: xdg-desktop-portal-wlr sends the output name, mutter sends a random UUID only for a ScreenCast attached to a RemoteDesktop session, and xdg-desktop-portal-kde sends nothing. `wl_output.name` provides a real connector name on wlroots and mutter from the connection lunette already holds, so `mapping_id` is not read.

Monitor identity omits the serial, which a Wayland client cannot read; only the DRM owner sees the EDID. niri keys on make, model, and serial and falls back to the connector. lunette uses the same shape without the serial and demotes the second of two identical monitors to its connector. Where no connector is available either, it falls back to logical position and warns, because silently attaching a mirror to the wrong screen is worse.

The host's outputs are enumerated by lunette's own explicit-socket watcher rather than `WlxClient`. The watcher owns identity, logical geometry, and hotplug for both capture and input, and `WlxClient` ignores `wl_output.name` and needs more globals. Direct capture matches `WlxClient`'s outputs to the roster by unique logical geometry, never by enumeration order.

uinput precedes wl_virtual in the provider chain. uinput works on every compositor and on X11, while wl_virtual exists only on wlroots compositors, so wl_virtual is the fallback for a wlroots host without `/dev/uinput` access. wl_virtual's layout is the default seat's, compiled at startup, because the provider opens before any seat exists and cannot send a key without one.

Direct capture uses the pinned WayVR implementation as it is, without a second screencopy implementation or upstream API changes. Its cancellation, pause, and failure-reporting limits are accepted and recorded in [Known gaps](#known-gaps).

Restore tokens are rewritten after every grant, because a token is single-use and each `Start` response returns a new one. The granted `persist_mode` is recorded, never the requested one, because a backend may downgrade it. The file is versioned TOML. A file from a later version yields no store, because an older writer would drop fields it does not know; unknown fields within a known version are rejected for the same reason. TOML is used because the file holds EDID make and model strings.

The end of a portal session is detected through the removal of its PipeWire nodes, not through the portal's `Session.Closed` signal. The signal is addressed to the D-Bus connection that created the session, which is `wlx-capture`'s private connection, and `wlx-capture` exposes neither that connection nor the session handle. Its capture thread logs the stream's state changes and reports none of them. Node removal is visible to any PipeWire client, so detection needs no change to `wlx-capture`. The session is revoked only when all of its nodes are gone, because a backend can remove one output's node, as when the output is unplugged, while the rest of the session stays live.

A revoked session is treated as a refusal rather than requested again with its restore token. On a portal that restores a grant silently, such as GNOME's with persistence, a new request resumes the capture the user just stopped, and the stop flickers and undoes itself. Requesting again was the earlier behaviour and is rejected for that reason. The cost is that a session the backend closes for another reason also waits for an explicit selection.

The host clipboard client lives in `lunette-capture`, and `lunette-compositor` keeps only the `HostSelectionSource` seam and the selection vocabulary that crosses it. The client is a Wayland client of the host desktop, like the output watcher and the virtual-input provider, and has no part in serving lunette's own clients. Keeping it in the compositor crate was rejected because it puts about a thousand lines of host integration among the code vendored from WayVR, which has no counterpart for it. `lunette-capture` depends on `lunette-compositor` for the seam; the compositor does not depend on the capture crate.

## Known gaps

The pinned screencopy backend has no cancellation or joined drop, its pause is empty, and a worker blocked in its event loop can stay detached after a monitor is dismissed or unplugged. Its asynchronous failures do not reach lunette, so a started direct stream can stay marked as mirrored with no frames, and there is no runtime failover to the portal.

No configuration option changes the provider order, so a wlroots host where uinput is writable always uses uinput.

If mutter binds an absolute uinput device to one display rather than mapping it across the whole layout, GNOME has no working absolute pointer path until libei is implemented.

PipeWire reuses node identifiers, and the node watch runs on its own thread. If it reports a node's removal only after a grant that reused the identifier, and without the node's re-addition, lunette stops the new stream, and revokes the session if that node was its last. Detecting the end through `Session.Closed` removes the race, and needs `wlx-capture` to expose the session handle and its closure. A lost PipeWire connection ends detection for the rest of the run, and lunette logs it.

The roster and the node watch are separate connections. If the backend removes an unplugged monitor's node before lunette's output watcher reports the unplug, and the node was the session's last, lunette revokes the session as though the user had stopped it, and the replugged monitor waits for an explicit selection.

`wlx-capture`'s `parse_start_response` drops the granted `persist_mode`, so lunette records that the backend stated none. Lifting this upstream changes one adapter.

`monitor.width` and `monitor.height` report the host's unrotated mode, while textures use the captured frame's dimensions.

`SURFACE_UNITS_PER_DETENT` in `crates/lunette-compositor/src/protocol/input.rs` is 10.0, the value WayVR's `UNITS_PER_DETENT` carries with the comment "no clue". A host sink divides a scroll distance by it to count wheel detents, and nothing has measured what a host compositor or its applications do with the result. The compositor reports a wheel detent to its own clients as 15 units, WayVR's `AXIS_VALUE_PER_DETENT`, so the two directions do not share a value, as they do not upstream.

Dynamic output scale makes some clients, GTK in particular, flicker. Discrete scale steps with hysteresis reduce it.
