# lunette — design overview

lunette is an XR window manager and Wayland compositor. It is written in Rust, scripted in Lua, and rendered by LÖVR. It runs as an OpenXR overlay, so it composites on top of a running VR application rather than replacing it.

lunette performs three functions. It spawns and manages Wayland applications inside itself. It mirrors the user's existing monitors. It presents both to Lua as textures and input sinks, so that scripts can arrange them in space.

This document states the scope and principles of the system. The area documents listed at the end contain the detail.

## Origins

Three projects inform the design.

awesome supplies the scripting philosophy: policy lives in Lua, the running state is inspectable and mutable from a shell prompt, and the standard library is a library that can be read, forked, or ignored.

WayVR supplies the Linux VR machinery: an embedded smithay compositor, screen capture across multiple host compositors, input injection into the host desktop, and knowledge of which OpenXR extensions work on which runtime.

LÖVR supplies the engine: OpenXR, Vulkan, composition layers, spatialised audio, physics, and a Lua environment.

The result is a window manager in which a window is not a distinct object type. A window is a texture, an input sink, and a set of metadata. Spatial behaviour is computed in Lua using the engine's own maths library. A script can, for example, use the physics engine to bounce an object off a panel and convert the impact point into a click, because nothing in the native API reserves that decision for itself.

## Goals

- Operate a computer inside XR: spawn applications, lay them out, type into them, and view the host desktop.
- Run as an overlay alongside VR applications at low enough cost that the underlying application is not disturbed.
- Retain full access to LÖVR. Any operation available in a LÖVR project is available in lunette.
- Avoid special cases. Windows and mirrored monitors reach Lua through one interface, built from primitives sufficient to implement the standard library.
- Keep the standard library optional and readable. It is installed as Lua source on disk.
- Support in-headset iteration through sub-second configuration reload that does not terminate running applications.

## Non-goals

- SteamVR and OpenVR support. lunette targets OpenXR only, and overlay support requires `XR_EXTX_overlay`, which restricts it to Monado and WiVRn.
- Sandboxing of spawned applications. They run with the same privileges as lunette.
- Use as a general-purpose desktop compositor. lunette implements a compositor in order to obtain windows, not to host a login session.
- Multi-user operation. The design assumes one user, one headset, and one session.

## Architectural principles

1. Mechanism is implemented in Rust; policy is implemented in Lua. Rust owns scarce and stateful resources: GPU objects, Wayland protocol state, OpenXR layer swapchains, and processes. Lua decides how they are used. The test applied throughout the design is whether the standard library could have been written by a third party against the public API. If it could not, the API is incorrect.
2. Lua reads a snapshot and issues requests. The compositor runs on a separate thread. Window state published to Lua is a per-frame snapshot, and mutations are messages applied asynchronously. This reflects the asynchronous nature of Wayland, and matches the arrangement awesome uses with X11.
3. Rust holds no long-lived references into the Lua state. There are no registry references to callbacks and no native objects with hidden back-pointers. All authoritative state is held in Rust and can be republished into a new Lua state at any time. This property is what makes soft reload possible.
4. Errors do not terminate the session. Event listeners and plugin callbacks run under protected calls, and the shipped configuration protects each of its frame handlers, so a failing configuration produces an error report on a floating quad. A LÖVR callback a configuration assigns directly is the recorded exception ([The Lua API](lua-api.md#known-gaps)). A configuration that fails to load produces a built-in safe mode with a laser, a panel, and a reload key.
5. The two API roots carry different contracts. `require '@lunette'` provides native mechanism. `require '@mullion'` provides the Lua standard library. The names differ so that the distinction is visible, and so that removing the second line is a recognisable option.
6. Changes are contributed upstream where possible. The LÖVR fork remains narrow and additive, and its patches are shaped as upstream pull requests. Improvements to capture and injection are offered back to WayVR.

## Path of an input event

1. LÖVR reports a controller pose through `lovr.headset`. See [Input](input.md).
2. Lua intersects the resulting ray with geometry it drew, and converts the intersection to pixel coordinates. See [The Lua API](lua-api.md).
3. Lua calls `sink:pointer(x, y)` and `sink:button('left', true)`. The native layer receives pixel coordinates and has no knowledge of the 3D scene.
4. The compositor thread determines which `wl_surface` contains that pixel, accounting for input regions, subsurfaces, and popups, and delivers seat events to the client. See [Compositor](compositor.md).
5. The client redraws and commits a dmabuf. Rust imports it as a `VkImage` on LÖVR's device and wraps it as a LÖVR texture. See [Rendering](rendering.md).
6. On the next frame the texture is either sampled by Lua's shaders or copied into an OpenXR composition layer.

## The documents

1. [Architecture](architecture.md) — processes, threads, ownership, and the snapshot model.
2. [LÖVR integration](lovr-integration.md) — the fork, the patch set, linking, boot, and restart semantics.
3. [Rendering](rendering.md) — texture import, composition layers, the layer pool, frame pacing, and damage.
4. [Compositor](compositor.md) — the Wayland server: outputs, scale, decorations, XWayland, and process management.
5. [Host desktop](host-desktop.md) — monitor capture, input injection, and clipboard bridging.
6. [Input](input.md) — sinks, seats, keyboards, XR input, and input blocking.
7. [The Lua API](lua-api.md) — namespaces, handles, events, reload, error handling, and `lunctl`.
8. [Standard library](stdlib.md) — the scope of `mullion`, the built-in plugin providers, and the shipped configuration that composes them.
9. [Audio](audio.md) — per-application spatialisation, deferred but specified.
10. [Build and development](build-and-development.md) — repository layout, build system, Nix, development loop, and testing.
11. [Roadmap](roadmap.md) — milestones in order, and the purpose of each.
12. [Credits](../../CREDITS.md) — whose work lunette is built on, under what licence, and how each project is used. Each document records the decisions and the gaps of its own subject.
