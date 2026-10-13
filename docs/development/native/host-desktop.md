# Host desktop

`lunette-capture` owns host monitor enumeration, capture, input injection, and clipboard integration. `wlx-capture` is a pinned external dependency from the WayVR monorepo; fixes belong upstream rather than in a second implementation.

## Capture

Capture prefers the pinned version-3 `wlr-screencopy` path when its output matches the roster uniquely by logical geometry. Missing support, connection failure, or ambiguous matching selects xdg-desktop-portal. Portal selection requests monitors together and stores restore tokens. Direct streams need no portal grant. A configuration that never requests capture does not prompt.

The host output connection stays open and updates capture and pointer mapping together on hotplug or rearrangement. Logical geometry comes from xdg-output where available. Mode-and-scale fallback is inaccurate for fractional scale. X11 hosts have no monitor roster. The binary passes the host socket explicitly; a session started only through inherited `WAYLAND_SOCKET` has no enumeration or direct capture.

Portal streams match outputs by logical position, not enumeration order or backend-defined `mapping_id`. Direct frames report the output transform; portal frames report an undefined transform. Consumers apply the reported transform once and use logical geometry for proportions. [Rendering](rendering.md#texture-import-and-lifetime) specifies buffer lifetime.

### Identity and lifecycle

Monitor identity prefers make and model, then connector, then logical position. Wayland exposes no serial. Identical monitors can therefore fall back to connector or position, with a warning; identity is not guaranteed across every rearrangement.

Capture opens lazily once graphics import formats exist. Frames enter a bounded newest-frame queue. Portal pause retains the session; dismissal drops and joins the stream worker. Direct pause and drop inherit upstream's limitations. A device-lifetime guard prevents a detached exporter from using a retired Vulkan device.

Portal revocation stops affected streams and leaves them requested but pending. No silent re-request occurs until explicit selection, and the revoked token is discarded. Restoring automatically could resume capture the user just stopped. The cost is that backend closure for another reason also needs selection.

Revocation is inferred from PipeWire node removal because `wlx-capture` exposes no portal session closure. Only loss of every remaining node revokes the session; an unplug must not revoke other streams. The separate roster and node-watch connections can race, as recorded below.

Restore tokens are versioned state under the XDG state directory, not configuration. Each grant replaces the single-use token. Newer versions and unknown fields are rejected so an older writer cannot discard data it does not understand. The pinned response parser does not expose granted persistence mode, so it cannot be recorded.

## Input injection

`HidProvider` isolates host input. Opening tries uinput, then Wayland virtual input, then a dummy that injects nothing. Failures are reported. uinput works broadly but needs `/dev/uinput` access; membership of the input group also grants access to other input devices. Virtual input needs no device permission but depends on host protocols.

Virtual keyboards must receive a valid keymap before any key. The binary supplies the default seat layout; later host events upload their seat's layout first. Missing seats and failed uploads refuse keys. uinput uses the host's layout instead. Fatal connection loss replaces the provider with the dummy; nonfatal failures reach the caller and permit retry. libei through the portal remains deferred.

## Pointer mapping

A panel hit maps through its monitor's logical rectangle and clamps to that monitor before reaching the provider. The transform is not applied again after rendering corrects the pixels. The provider receives the desktop bounding box, not monitor identities; per-monitor clamping prevents hits landing in layout gaps.

## The input domain leak

Compositor windows have independent pointer and keyboard state per seat. Mirrored monitors share the host desktop's cursor and keyboard focus. Two hands cannot create two host cursors, and typing reaches the host's focused application. Routing must distinguish window and host sink domains despite their common interface.

## Clipboard

The host data-control client implements the compositor's selection seam. It belongs in capture because it serves host integration, not lunette's Wayland clients. [Input](input.md#clipboard) specifies the single bridge seat and descriptor-based transfers. Drag-and-drop across the host/compositor boundary has no protocol.

## Known gaps

The pinned direct backend cannot cancel or join a dropped worker, pause does nothing, and asynchronous failure does not reach lunette. A stream can remain marked mirrored without frames and cannot fail over to the portal at runtime.

PipeWire identifier reuse and delayed removal can stop a newly granted stream. Roster/node ordering can also mistake unplug for revocation; loss of the watch connection disables revocation detection for the run. Exposing the portal session's closure upstream would remove these limits.

There is no provider-order option. Hosts that bind absolute uinput to one display may have no usable whole-layout pointer until libei support. Host scroll conversion remains unmeasured, and dynamic output scale can flicker in clients such as GTK. Live checks must establish capture orientation, permission and revocation behavior, hotplug identity, host pointer mapping, keyboard layout, scrolling, and clipboard transfer on the intended host.
