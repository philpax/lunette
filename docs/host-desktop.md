# Host desktop

Mirroring the user's monitors and injecting input into them is a separate problem from running the compositor. WayVR has addressed it over several years. lunette reuses that work rather than reimplementing it.

wlx-capture remains an external git-pinned dependency rather than a vendored copy. It handles capture edge cases across Linux compositors, none of that work depends on lunette's architecture, and it continues to receive fixes as PipeWire and host compositors change. It provides a dmabuf and has no dependency on how lunette uses it.

## Capture

`wlx-capture` ships four backends: `pipewire` (via xdg-desktop-portal over D-Bus), `wlr_dmabuf`, `wlr_screencopy`, and `xshm` for X11.

PipeWire via the portal is the default backend. It works on niri, GNOME, KDE, and other Wayland compositors, and is expected to remain supported over time. WayVR uses the same approach (`inspiration/wayvr/wayvr/src/overlays/screen/pw.rs`). It uses a Wayland client only to enumerate outputs (`overlays/screen/mod.rs:76`) and falls back to xshm on X11.

This backend requires a portal permission dialog on first use. A restore token is persisted so the user does not re-approve on every launch.

### One divergence: monitor identification

WayVR's onboarding asks the user to select screens in a prescribed order, because the portal hands out anonymous streams. Modern portals expose a `mapping_id` per stream that ties it to a `wl_output`, allowing monitors to identify themselves. lunette implements this, with manual mapping as a fallback where the portal does not provide it.

This is an improvement over WayVR's approach and is a candidate for contributing upstream.

`ext-image-copy-capture-v1` support is planned as a later addition. It is the successor to the deprecated `wlr-screencopy`. Adding it to `wlx-capture` benefits WayVR as well.

### Identity and lifecycle

Monitors receive stable identities, connector names such as `DP-2` where available, so Lua layout rules survive a replug or a reboot.

Capture starts lazily and can be stopped from Lua. A mirrored screen that a script has dismissed has no ongoing cost.

## Input injection

Input injection into the host desktop uses WayVR's `HidProvider` trait verbatim (`inspiration/wayvr/wayvr/src/subsystem/hid/provider/`). It has three backends, selected by a config switch (`subsystem/input.rs:24`):

- uinput: the preferred backend. It creates kernel-level virtual devices, so it works on any compositor and on X11, and can position the cursor absolutely given the monitor layout. It requires `/dev/uinput` access, granted by a udev rule or `input` group membership.
- wl_virtual: a fallback backend, using `zwlr_virtual_pointer` plus `virtual-keyboard`. It requires no special permissions, but requires the host compositor to implement these protocols, and works only on Wayland.
- dummy: performs no injection.

uinput is tried first because it works regardless of the host compositor.

libei via the portal's RemoteDesktop interface is the intended long-term replacement and is planned as a future backend.

Keymaps come from the host compositor via xkbcommon (`subsystem/hid/mod.rs:389`), so typing into a mirrored monitor respects the user's real keyboard layout.

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
