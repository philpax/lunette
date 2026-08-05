# Compositor

lunette is a real Wayland compositor. It creates a socket, exports `WAYLAND_DISPLAY` to processes it spawns, and their surfaces arrive as dmabufs. Applications we spawn are ours: we hand out their surfaces, size them, route their input, and decide when they draw.

The implementation is a hard vendor of WayVR's `backend/wayvr/` (~4.4k lines of smithay wiring) at `crates/lunette-compositor`, with the vulkano import path replaced by ours ([Rendering](rendering.md)). We vendor rather than track upstream because every file we care about is one we've modified, so syncing would cost more than it returns. Capture is different — `wlx-capture` stays an external dependency ([Host desktop](host-desktop.md)).

## Protocols

Starting from WayVR's set (`inspiration/wayvr/wayvr/src/backend/wayvr/comp.rs`): compositor, xdg-shell, xdg-decoration, kde-decoration, output, seat, shm, dmabuf, viewporter, single-pixel-buffer, relative-pointer, data-device, primary-selection, data-control, ext-data-control.

Additions:

- **`wp_fractional_scale_v1`.** WayVR doesn't implement it; we need it. Panel resolution and physical size are decoupled in VR, and a panel you lean toward should render sharper. Viewporter, its prerequisite, is already there.
- **`linux-drm-syncobj-v1`** eventually, for explicit sync.

## Outputs

Clients see virtual monitors that Lua creates:

```lua
local out = lunette.newOutput{ width = 1920, height = 1080, scale = 1.5, refresh = 90 }
```

WayVR advertises a single output for everything (`mod.rs:209`) and clamps windows to its bounds. We don't, because a shared output means one scale factor for every app, fullscreen meaning "the whole WM", and a client querying its display getting an answer unrelated to the panel it's on.

The standard library defaults to **one output per spawned application**. Output globals are created with a **per-client filter**, so each client sees only the outputs Lua assigned it — otherwise an app enumerating outputs would find every other window's monitor, which is genuinely confusing and affects layout decisions in some toolkits.

What this unlocks:

- **Dynamic scale.** Raise a panel's output scale as you approach; the client re-renders at higher resolution; the composition layer gets sharper. This is the largest legibility win available and it's impossible with a shared output.
- **Refresh as policy.** A background panel told 15 Hz stops burning CPU; the one you're looking at gets 90.
- **Honest fullscreen.** `xdg_toplevel.set_fullscreen` resizes the panel, not the world.

The cost: scale changes make clients reallocate buffers and re-lay-out, and some do it badly — flicker, or GTK recomputing everything. The standard library uses discrete scale steps with hysteresis rather than continuous adjustment. That's Lua policy, and tunable.

## Decorations

We force **server-side decorations** for both `xdg-decoration` and the KDE protocol, exactly as WayVR does (`comp.rs:638`) — and then draw none.

Clients hand us bare content. Titlebars, close buttons, and resize grips are 3D objects the standard library draws around the panel. That's the correct division for XR: flat chrome rendered *into* the panel wastes pixels and is hard to hit at distance. It also stops GTK apps spending panel space on window chrome.

## Windows

A window handle carries what the protocol gives us: `title`, `appId`, size, size constraints, parent/transient relationships, popup status, and the process it belongs to. Requests go the other way: `close`, `resize`, `setActivated`, `setFullscreen`, `setMaximized`.

**Native owns hit-testing within a surface.** Lua says "pixel (412, 88) on this window"; Rust decides that this is the popup menu rather than the toplevel, honouring input regions and subsurfaces. That's protocol business, not spatial business. WayVR's `hit_test.rs` is exactly this and ports over.

Windows and mirrored monitors reach Lua through the same interface — a texture, a size, an input sink, a capability set. A window advertises `close` and `resize`; a monitor doesn't. Lua code that pokes a panel doesn't branch on where its pixels came from.

## XWayland

X11 applications are supported via **`xwayland-satellite`** spawned as a child process, as WayVR does (`client.rs:101`), opt-in per application.

Satellite is a rootless X server that translates X11 clients into Wayland clients of our compositor, so from our side an X11 app is just another client and there's zero X11 code in our tree. We lose X11-specific window management semantics — override-redirect, `_NET_WM` hints, transient-for — which satellite maps onto xdg-shell as best it can.

smithay's built-in XWayland would give us those semantics and cost months. X11 window management is its own discipline; if an app needs something satellite can't express, that's a bug for a project that exists to solve it.

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

Windows carry a reference to their originating process. Getting this right needs more than pid matching, because with flatpak, shell wrappers, and re-execing launchers, the connecting pid usually isn't the child we spawned.

WayVR's solution, which we take wholesale: generate a random **auth key** per spawn, export it in the child's environment (`mod.rs:1334`, forwarded through flatpak with `--env=` at `mod.rs:1318`), then on client connect read the pid from socket credentials and check `/proc/<pid>/environ` for the key (`client.rs:158`, `process.rs`'s `find_by_pid`). Pid first, env key as fallback.

### Adoption

Processes we didn't spawn are adopted. Our socket is a real Wayland socket; anything with the right `WAYLAND_DISPLAY` can connect, and `WAYLAND_DISPLAY=lunette-0 foot` from your host terminal is the single most useful development workflow available. They appear with the same window events and a process handle marked `external = true`.

### Lifecycle

Native does the minimum: reap children, report exit. No auto-restart, no auto-closing panels, no "quit when the last window closes" — all of that is Lua.

Two divergences from WayVR, both deliberate:

- **Signal the process group, not the child.** WayVR's `Drop` sends SIGTERM to the direct child only (`process.rs`), so a shell wrapper's grandchildren survive. We `setsid` and signal the group, with `PR_SET_PDEATHSIG` as a backstop so a lunette crash doesn't strand GUI apps with no compositor to render into.
- **Capture stdout and stderr.** WayVR inherits stdio, so child output goes to whatever terminal started it. Debugging a spawned app inside a headset with no terminal is miserable, so we pipe both, surface them as `lovr.lunprocessoutput` events, and mirror them into lunette's log. The standard library can then build a log panel.

### Not our problem

No cgroup or systemd-scope integration, no seatd, no sandboxing. Spawned applications are as privileged as lunette itself.
