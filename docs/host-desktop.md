# Host desktop

Mirroring your real monitors and typing into them is a separate problem from running our own compositor, and it's the one WayVR has spent years on. We reuse their work rather than repeat it.

`wlx-capture` stays an **external git-pinned dependency**, not a vendor. It's the highest-value, lowest-friction reuse available: galister has handled capture edge cases across every Linux compositor, none of that work touches our architecture, and it keeps receiving fixes as PipeWire and compositors change. It hands us a dmabuf and doesn't care what we do with it.

## Capture

`wlx-capture` ships four backends: `pipewire` (via xdg-desktop-portal over D-Bus), `wlr_dmabuf`, `wlr_screencopy`, and `xshm` for X11.

**PipeWire via the portal is the default.** It works on niri, GNOME, KDE, and everything else, and it's the only path that will still work in three years. WayVR does the same (`inspiration/wayvr/wayvr/src/overlays/screen/pw.rs`), using a Wayland client purely to enumerate outputs (`overlays/screen/mod.rs:76`) and falling back to xshm on X11.

Costs: a portal permission dialog and a restore token to persist so you're not re-approving on every launch.

### One divergence: monitor identification

WayVR's onboarding asks you to select your screens in a prescribed order, because the portal hands out anonymous streams. Modern portals expose a **`mapping_id`** per stream that ties it to a `wl_output`, so monitors can identify themselves. We implement that, with manual mapping as the fallback where the portal won't tell us.

This is a pure improvement and worth contributing back.

`ext-image-copy-capture-v1` support is a later addition — it's the successor to the deprecated `wlr-screencopy`, and adding it to `wlx-capture` benefits WayVR too.

### Identity and lifecycle

Monitors get **stable identities** — connector names like `DP-2` where available — so Lua layout rules survive a replug or a reboot.

Capture starts lazily and is stoppable from Lua. A mirrored screen you've dismissed costs nothing.

## Input injection

Injecting into your real desktop uses WayVR's `HidProvider` trait verbatim (`inspiration/wayvr/wayvr/src/subsystem/hid/provider/`), with three backends and a config switch (`subsystem/input.rs:24`):

- **uinput** — preferred. Kernel-level virtual devices, so it works on any compositor and on X11, and can position the cursor absolutely given your monitor layout. Needs `/dev/uinput` access via a udev rule or `input` group membership.
- **wl_virtual** — fallback. `zwlr_virtual_pointer` plus `virtual-keyboard`. No special permissions, but requires the host compositor to implement them, and it's Wayland-only.
- **dummy** — no injection.

uinput first because it works regardless of what compositor you're running today.

libei via the portal's RemoteDesktop interface is the sanctioned future and gets a slot later.

Keymaps come from the host compositor via xkbcommon (`subsystem/hid/mod.rs:389`), so typing into a mirrored monitor respects your real layout.

## The input domain leak

Windows and monitors share an interface, but they don't share semantics, and the difference is worth exposing rather than hiding.

Our compositor windows have **independent focus and pointer state** — each window can be pointed at by a different seat, with its own cursor. Mirrored monitors don't: they're all driven by one `HidProvider` poking a host desktop that has exactly one cursor and one keyboard focus. Two hands pointing at two mirrored monitors can't have two cursors. Typing at a mirrored monitor goes wherever your host compositor currently has focus, not to the monitor you're looking at.

So every sink carries an **input domain**. Sinks in the same domain share cursor position and keyboard focus. All mirrored monitors are the `host` domain; each of our windows is independently addressable. Lua can query it, so a panel library can honestly show "you're typing into the host desktop, which currently has *that* focused" instead of pretending otherwise.

## Clipboard

Copy in Firefox on your host desktop, paste into a terminal running inside lunette. Those are two compositors with two clipboards, and nothing bridges them unless we do.

WayVR bridges both directions — `smithay-clipboard` plus `subsystem/clipboard/{wl,x11}.rs` on the host side, `data_device`/`primary_selection`/`data_control`/`ext_data_control` on the compositor side. We do the same.

The split:

- **Native** exposes clipboard read, write, and offer-changed events for the host and for each internal seat. Format negotiation — MIME type lists, incremental transfers over fds, large payloads — never enters Lua. Lua sees "text/plain is available" and can request it; a 40 MB image offer is proxied without being copied into a Lua string.
- **The standard library** runs the mirroring loop. Default is bidirectional and always on, because a clipboard that doesn't cross the boundary is a broken clipboard. Per-seat opt-out exists for anyone who wants an isolated scratch panel.

**Primary selection is mirrored too, by default.** Middle-click paste is half of how text moves on Linux, and mirroring it is the more intuitive behaviour. It also means every selection in a VR terminal overwrites your host primary selection, so it's a single switch to turn off.

## Known gap: drag-and-drop across the boundary

In-compositor drag-and-drop between two lunette windows comes nearly free from smithay's `data_device`. Dragging between your host desktop and lunette does not: the drag would have to cross a compositor boundary, and no protocol exists for that. WayVR doesn't do it either.
