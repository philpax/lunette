# Design overview

lunette is an XR window manager and Wayland compositor. Rust hosts it, Luau scripts it, and LÖVR renders it. It runs as an XR overlay, so it composites on top of a running VR application. LÖVR owns the headset session through its OpenXR backend, which requires `XR_EXTX_overlay`, or through its internal OpenVR backend, which uses native overlays.

lunette spawns Wayland applications inside itself, mirrors the user's monitors, and presents both to Lua as textures and input sinks. Lua arranges them in space.

## Origins

awesome supplies the scripting model: policy lives in Lua, the running state is inspectable from a shell, and the standard library is source that a user can read, fork, or ignore.

WayVR supplies the Linux VR machinery: an embedded smithay compositor, screen capture across host compositors, input injection into the host desktop, and knowledge of which OpenXR extensions work on which runtime.

LÖVR supplies the engine: headset sessions, Vulkan, composition layers, spatial audio, physics, and a Lua environment.

A window is not a distinct object type. It is a texture, an input sink, and metadata. Lua computes spatial behaviour with the engine's own maths, so a script can, for example, convert a physics impact on a panel into a click.

## Goals

- Operate a computer inside XR: spawn applications, lay them out, type into them, and view the host desktop.
- Run as an overlay at a cost low enough that the underlying application is not disturbed.
- Retain full access to LÖVR. Any operation available in a LÖVR project is available in lunette.
- Present windows and mirrored monitors to Lua through one interface, built from primitives sufficient to implement the standard library.
- Keep the standard library optional and readable. It is installed as Luau source.
- Support in-headset iteration through configuration reload that does not terminate running applications.

## Non-goals

- An OpenVR scene application, game injection, or occlusion against another application's depth. OpenVR support is overlay-only.
- Sandboxing of spawned applications. They run with lunette's privileges.
- Use as a general-purpose desktop compositor. lunette implements a compositor to obtain windows, not to host a login session.
- Multi-user operation. The design assumes one user, one headset, and one session.

## Architectural principles

1. Rust implements mechanism and Lua implements policy. Rust owns scarce and stateful resources: GPU objects, Wayland protocol state, composition layers, and processes. Lua decides how they are used. The standard library must be writable by a third party against the public API; where it is not, the API is defective.
2. Lua reads a snapshot and issues requests. The compositor runs on its own thread. Window state reaches Lua as a per-frame snapshot, and mutations are messages applied asynchronously. [Architecture](architecture.md#the-snapshot-model) states the model.
3. Rust holds no long-lived references into the Lua state outside the plugin attachment. All authoritative native state can be republished into a new Lua state, which is what makes reload and restart possible.
4. Errors do not terminate the session. Event listeners, plugin callbacks, and frame handlers run under protected calls and report through one error boundary. A configuration that fails to load starts the built-in safe mode, which shows the error, spawns a terminal on a panel with a laser, and reloads on F5. [The Lua API](lua-api.md#errors) states the boundaries.
5. Native mechanism and Lua policy have different roots. `@lunette` is native mechanism. `@lunette-plugin`, `@lunette-contracts`, `@lunette-plugins`, and `@lunette-desktop` are the Lua standard library, and every policy it ships is a plugin that a configuration can replace or omit. [Standard plugins](standard-plugins.md) describes the service connections and shipped desktop composition.
6. Changes go upstream where possible. The LÖVR fork's patches are shaped as upstream pull requests, and capture and injection fixes are offered to WayVR.

## Path of an input event

1. LÖVR reports a controller pose through `lovr.headset`. See [Input](input.md).
2. Lua intersects the ray with geometry it drew and converts the hit to pixel coordinates.
3. Lua calls `sink:pointer(x, y)` and `sink:button('left', true)`. The native layer receives pixels and has no knowledge of the scene.
4. The compositor thread finds the `wl_surface` under that pixel, accounting for input regions, subsurfaces, and popups, and delivers seat events. See [Compositor](compositor.md).
5. The client commits a dmabuf. Rust imports it as a `VkImage` on LÖVR's device and wraps it as a LÖVR texture. See [Rendering](rendering.md).
6. On the next frame, Lua samples the texture in the scene or the host copies it into a composition layer.

## The documents

[Standard plugins](standard-plugins.md) links configuration and consumer documentation beside each plugin. Plugin-local specifications describe behaviour and rationale; central specifications cover native mechanisms and shared contracts.

- [Architecture](architecture.md): threads, ownership, the snapshot model, and the plugin runtime.
- [LÖVR integration](lovr-integration.md): the fork, the patch set, linking, boot, and restart.
- [Rendering](rendering.md): texture import, composition layers, the layer pool, frame pacing, and rounded geometry.
- [Compositor](compositor.md): the Wayland server, outputs, scale, decorations, XWayland, and processes.
- [Host desktop](host-desktop.md): monitor capture, input injection, and the clipboard bridge.
- [Input](input.md): sinks, seats, keyboards, keyboard routing, pointer input, and XR input.
- [The Lua API](lua-api.md): the native API, plugin authoring, the contracts, reload, errors, and `lunctl`.
- [Standard plugins](standard-plugins.md): service connections, the built-in plugins, and the shipped desktop composition.
- [Audio](audio.md): non-routing PCM capture, reusable analysis, and deferred spatial playback routing.
- [Build and development](build-and-development.md): layout, build, Nix, the development loop, and testing.
- [Roadmap](roadmap.md): the work beyond v1 and upstream work.
- [Credits](../../CREDITS.md): the projects lunette builds on and their licences.
