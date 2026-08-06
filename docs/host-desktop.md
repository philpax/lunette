# Host desktop

Mirroring the user's monitors and injecting input into them is a separate problem from running the compositor. WayVR has addressed it over several years. lunette reuses that work rather than reimplementing it.

wlx-capture remains an external git-pinned dependency rather than a vendored copy. It handles capture edge cases across Linux compositors, none of that work depends on lunette's architecture, and it continues to receive fixes as PipeWire and host compositors change. It provides a dmabuf and has no dependency on how lunette uses it.

## Capture

`wlx-capture` ships four backends: `pipewire` (via xdg-desktop-portal over D-Bus), `wlr_dmabuf`, `wlr_screencopy`, and `xshm` for X11.

PipeWire via the portal is the default backend. It works on niri, GNOME, KDE, and other Wayland compositors, and is expected to remain supported over time. WayVR uses the same approach (`inspiration/wayvr/wayvr/src/overlays/screen/pw.rs`). It uses a Wayland client only to enumerate outputs (`overlays/screen/mod.rs:76`) and falls back to xshm on X11.

This backend requires a portal permission dialog on first use. A restore token is persisted so the user does not re-approve on every launch.

### One divergence: monitor identification

WayVR's onboarding asks the user to select screens in a prescribed order, because the portal hands out anonymous streams. lunette requests every monitor in one dialog and correlates each returned stream to a `wl_output` by comparing the stream's `position` and `size` against the output's logical geometry. That works on every portal backend, and it is what wlx-overlay-s does on X11. The portal's `mapping_id` is read opportunistically and taken as a connector name when it is one, which is the case on xdg-desktop-portal-wlr; it is not the mechanism, because two of the three backends do not supply a usable one. [Decisions](decisions.md#recorded-decisions) records the evidence.

This is an improvement over WayVR's approach and is a candidate for contributing upstream.

`ext-image-copy-capture-v1` support is planned as a later addition. It is the successor to the deprecated `wlr-screencopy`. Adding it to `wlx-capture` benefits WayVR as well.

### Identity and lifecycle

Monitors receive stable identities, so Lua layout rules survive a replug or a reboot. The identity is the make and model reported in `wl_output.geometry`, falling back to a connector name such as `DP-2` where one is available, and to the monitor's logical position where neither is. The descriptor comes first because it survives a monitor moving to a different port. A Wayland client cannot read a serial, so two monitors of the same model are indistinguishable by descriptor; the second of them is identified by its connector alone, and lunette says so rather than picking one silently.

Capture starts lazily and can be stopped from Lua. Nothing is asked of the portal until the first `monitor:mirror()`, so a configuration that mirrors nothing never prompts.

Stopping and pausing are separate operations, because they cost different things. `monitor:setPaused(true)` deactivates the PipeWire stream but keeps it, for a panel that has left the user's view; resuming costs nothing. `monitor:dismiss()` drops the stream entirely, which stops PipeWire's thread and closes its descriptors, so a dismissed screen has no ongoing cost at all. The portal session survives a dismissal, so mirroring the monitor again does not prompt a second time; only a session the user revokes, or one the backend loses, produces another dialog.

WayVR does not make this distinction. Dismissal there maps to visibility alone (`backend/openxr/overlay.rs:208-223`), and `pause()` is an empty no-op in three of its four capture backends — only the PipeWire one honours it, by deactivating the stream (`pipewire/capture.rs:144`). There is no way to stop a capture and release its resources.

[The Lua API](lua-api.md#monitors) states the surface: `lunette.monitors()`, and the fields and operations on a monitor handle.

## Input injection

Input injection into the host desktop goes through the `HidProvider` trait, whose shape follows WayVR's (`inspiration/wayvr/wayvr/src/subsystem/hid/provider/mod.rs:8`). There are three providers:

- uinput: the preferred provider. It creates kernel-level virtual devices, so it works on any compositor and on X11, and can position the cursor absolutely given the monitor layout. It requires `/dev/uinput` access, granted by a udev rule or `input` group membership. Note that the `input` group also grants read access to every input device on the machine.
- wl_virtual: using `zwlr_virtual_pointer_v1` plus `zwp_virtual_keyboard_v1`. It requires no special permissions, but requires the host compositor to implement these protocols, which only the wlroots family does. KWin and mutter do not.
- dummy: performs no injection.

The providers are an ordered chain rather than a switch. uinput is tried first because it works regardless of the host compositor, then `wl_virtual`, then the dummy. Each mechanism is actually attempted, and every failure passed over is kept and reported, so a user is told what was tried and what each attempt said. A configuration override moves a named provider to the front; the rest of the chain still stands behind it. WayVR has no such chain: `HidWrapper::new` (`subsystem/input.rs:22-41`) calls one initialiser and installs the dummy on failure.

A host compositor that goes away degrades the session to the dummy provider with a logged reason. It does not abort lunette.

libei via the portal's RemoteDesktop interface is the intended long-term replacement and is planned as a future provider.

Keymaps are a parameter. `lunette-capture` takes a layout in XKB's version 1 text format and uploads it to `zwp_virtual_keyboard_v1`, so typing into a mirrored monitor respects the user's real keyboard layout; reading that layout off the host is the binary's job, not the library's. There is nothing to upload under uinput, which injects raw keycodes below the display server and leaves the layout to the host.

## Pointer mapping

A hit on a mirrored panel is normalised over the panel's surface. The monitor's mapping turns it into a position inside that monitor's logical rectangle, applying the monitor's rotation and flip, and clamping to the rectangle first. The provider then places that position on the host desktop, which it knows only as a bounding box.

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

## Clipboard

Copying in an application on the host desktop and pasting into a terminal running inside lunette involves two compositors with two clipboards. Nothing bridges them unless lunette does.

WayVR bridges both directions, using `smithay-clipboard` plus `subsystem/clipboard/{wl,x11}.rs` on the host side, and `data_device`, `primary_selection`, `data_control`, and `ext_data_control` on the compositor side. lunette follows the same approach.

The split:

- The native layer exposes clipboard read, write, and offer-changed events for the host and for each internal seat. Format negotiation, including MIME type lists, incremental transfers over file descriptors, and large payloads, does not enter Lua. Lua sees that a format such as `text/plain` is available and can request it. A 40 MB image offer is proxied without being copied into a Lua string.
- The standard library runs the mirroring loop. The default is bidirectional and always on, because a clipboard that does not cross the boundary provides limited value. A per-seat opt-out exists for an isolated scratch panel.

Primary selection is mirrored by default as well. Middle-click paste is one of the two mechanisms by which text moves on Linux, and mirroring it matches user expectations. As a consequence, every selection made in a VR terminal overwrites the host primary selection. A single switch disables this.

## Known gap: drag-and-drop across the boundary

In-compositor drag-and-drop between two lunette windows is provided almost entirely by smithay's `data_device`. Dragging between the host desktop and lunette is not supported: the drag would have to cross a compositor boundary, and no protocol exists for this. WayVR does not support it either.
