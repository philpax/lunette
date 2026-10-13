# Design overview

lunette is an XR window manager and Wayland compositor. Rust owns native resources, LÖVR owns graphics and headset sessions, and Luau owns desktop policy. Applications connect to lunette's compositor; host monitors arrive through capture. Both expose textures and pixel-space input sinks to Lua.

## Architectural principles

The shipped desktop uses only the public native API. A policy that needs private native access identifies a missing API capability. The standard library remains optional and replaceable.

The compositor runs independently of the frame loop. Lua reads frame snapshots and sends asynchronous requests. Native state outlives configuration reload and can be republished after a Lua-state restart.

LÖVR owns every XR session. OpenXR overlays use `XR_EXTX_overlay`; OpenVR uses native overlays. lunette does not submit OpenVR scene frames or provide occlusion against another application's depth.

## Non-goals

lunette does not provide a login compositor, application sandboxing, or multi-user sessions. Spawned applications have the session's privileges.

## The documents

- [Build and development](build-and-development.md): build, iteration, debugging, and test prerequisites.
- [Architecture](architecture.md): threads, resource ownership, and lifecycle boundaries.
- [LÖVR integration](native/lovr-integration.md): fork maintenance, backend selection, and restart hazards.
- [Rendering](native/rendering.md) and [validation](native/rendering-validation.md): imported images, layer allocation, and limits of the evidence.
- [Compositor](native/compositor.md), [input](native/input.md), [host desktop](native/host-desktop.md), and [audio](native/audio.md): native integration constraints and acceptance requirements.
- [Native Lua API](native/lua-api.md): binding lifetime, reload, errors, and control-socket authority.
- [Standard plugins](standard-plugins.md): shipped desktop composition boundaries.
- [Roadmap](roadmap.md): deferred work.

Configuration workflows belong in [the guides](../users/desktop-configuration.md). Plugin authoring and service guarantees belong beside [the facade](../../lua/lunette-plugin/README.md) and [the contracts](../../lua/lunette-contracts/README.md). Plugin behavior belongs beside its implementation.
