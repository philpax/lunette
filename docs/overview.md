# lunette — design overview

**lunette** is an XR window manager and Wayland compositor, written in Rust, scripted in Lua, rendered by [LÖVR](https://lovr.org). It runs as an OpenXR overlay, so it composites on top of whatever VR application you're already in rather than replacing it.

It does three things: it spawns and manages Wayland applications inside itself, it mirrors your existing monitors, and it hands both to Lua as textures and input sinks so you can arrange your computer in space however you like.

A lunette is a half-moon window set into a vault, and in French, a telescope — a thing you look through. Lua means moon in Portuguese. The name is doing a lot of work.

## The premise

Three projects inform this one:

- [awesome](https://awesomewm.org) supplies the philosophy: a window manager whose policy lives in Lua, whose entire state is inspectable and mutable from a shell prompt while it runs, and whose standard library is a library — something you can read, fork, or ignore.
- [WayVR](https://wayvr.org) supplies the hard-won Linux VR machinery: an embedded smithay compositor, screen capture across every compositor's quirks, input injection into the host desktop, and the knowledge of which OpenXR extensions actually work.
- [LÖVR](https://lovr.org) supplies the engine: OpenXR, Vulkan, composition layers, spatialised audio, physics, and a Lua environment people already know how to write.

The synthesis is a window manager where a window is not a special kind of object. It's a texture plus an input sink plus some metadata. Everything spatial — where a panel hangs, what shape it is, how a controller ray becomes a click — is Lua's business, computed with the engine's own maths. If you want to bounce a physics ball off your terminal and have the impact register as a click, nothing in the design is in your way.

## Goals

- Operate a computer inside XR: spawn apps, lay them out, type into them, see your real desktops.
- Run as an overlay alongside VR applications, cheaply enough that the game underneath doesn't notice.
- Keep full access to LÖVR. Anything you can do in a LÖVR project, you can do here.
- Special-case nothing. Windows and mirrored monitors reach Lua through the same interface, built from primitives a downstream user could have built the standard library out of.
- Make the standard library optional and legible — installed as readable Lua on disk, not compiled in.
- Iterate in-headset. Sub-second config reload without killing your applications.

## Non-goals

- SteamVR and OpenVR. OpenXR only. Overlay support means `XR_EXTX_overlay`, which means Monado and WiVRn.
- Sandboxing spawned applications. They're as privileged as lunette itself.
- Being a general-purpose desktop compositor. lunette is a compositor because that's how you get windows, not because it wants to run your login session.
- Multi-user anything. One person, one headset, one session.

## Architectural principles

1. **Mechanism in Rust, policy in Lua.** Rust owns scarce and stateful resources: GPU objects, Wayland protocol state, OpenXR layer swapchains, processes. Lua decides what to do with them. When we've been unsure, the test has been whether the standard library could have been written by a downstream user against the public API. If not, the API is wrong.
2. **Lua sees a snapshot and issues requests.** The compositor runs on its own thread. Window state published to Lua is a per-frame snapshot; mutations are messages applied asynchronously. This is honest about what Wayland is, and it's the same bargain awesome makes with X11.
3. **No native references into Lua.** Rust never holds a long-lived reference into the Lua state — no registry refs to callbacks, no hidden back-pointers. All authoritative state lives in Rust and is republishable into a fresh Lua state at any moment. This is what makes soft reload work.
4. **Errors don't kill the desktop.** Every user callback is `xpcall`'d. A bad config gets you an error panel, not a black headset. If the config fails to load at all, a built-in safe mode gives you a laser, a terminal, and a reload key.
5. **Two roots, two contracts.** `require 'lunette'` is native mechanism. `require 'mullion'` is the Lua standard library. Different names because they carry different promises, and deleting the second line should be an obviously available move.
6. **Upstream where possible.** Our LÖVR fork stays narrow and additive, shaped as patches bjornbytes might take. Improvements to capture and injection go back to WayVR.

## How a click reaches an application

1. LÖVR reports a controller pose through `lovr.headset` ([Input](input.md)).
2. Lua intersects that ray against whatever geometry it drew — a quad, a cylinder, a physics body — and converts the hit to pixel coordinates ([The Lua API](lua-api.md)).
3. Lua calls `sink:pointer(x, y)` and `sink:button('left', true)`. Rust knows nothing about 3D.
4. The compositor thread resolves which `wl_surface` owns that pixel — accounting for input regions, subsurfaces, and popups — and delivers seat events to the client ([Compositor](compositor.md)).
5. The client redraws and commits a dmabuf. Rust imports it as a `VkImage` on LÖVR's device, wrapped as a LÖVR `Texture` ([Rendering](rendering.md)).
6. Next frame, the texture is either sampled by Lua's own shaders or blitted into an OpenXR composition layer for crisp text.

## The documents

1. [Architecture](architecture.md) — processes, threads, ownership, and the snapshot model.
2. [LÖVR integration](lovr-integration.md) — the fork, the patch set, linking, boot, and restart semantics.
3. [Rendering](rendering.md) — texture import, composition layers and the layer pool, frame pacing, damage.
4. [Compositor](compositor.md) — the Wayland server: outputs, scale, decorations, XWayland, process management.
5. [Host desktop](host-desktop.md) — monitor capture, input injection, clipboard bridging.
6. [Input](input.md) — sinks, seats, keyboards, XR input, and blocking the game underneath.
7. [The Lua API](lua-api.md) — namespaces, handles, events, reload, error handling, and `lunctl`.
8. [Standard library](stdlib.md) — what `mullion` covers, in tiers, and the minimum viable version of each.
9. [Audio](audio.md) — per-application spatialisation, deferred but specified.
10. [Build and development](build-and-development.md) — repo layout, build system, Nix, the dev loop, testing.
11. [Roadmap](roadmap.md) — milestones, in order, and what each proves.
12. [Decisions and gaps](decisions.md) — recorded decisions, known gaps, licensing, and credit.
