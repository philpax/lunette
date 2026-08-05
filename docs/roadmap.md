# Roadmap

## Milestone 0 — the vertical slice

The purpose of this milestone is de-risking. Nothing else.

Rust host boots LÖVR, an embedded smithay compositor with one hardcoded output starts, one client is spawned, its dmabuf is imported, it is drawn on a quad in-scene, a ray is cast from a controller, and the quad is clicked.

No composition layers, no monitor mirroring, no standard library, no `lunctl`, no reload, no seats beyond one.

Two unknowns carry the most risk. Both are cheaper to resolve in a 2000-line prototype than after a standard library exists.

1. The LÖVR Vulkan patch. It is unverified whether `TextureInfo.handle` accepts a foreign image without further changes, whether LÖVR's internal layout and queue-family handling tolerates an image that arrived from `VK_QUEUE_FAMILY_FOREIGN_EXT` in an undefined layout, and whether implicit sync is sufficient in practice.
2. The thread split. It is unverified whether the compositor-thread and main-thread division holds under load, and whether the snapshot model is as workable in use as in specification.

An unfavourable result for either unknown changes the downstream design.

## v1 — the daily driver

The point at which the system is usable for daily work. Each step is usable on its own.

1. Composition layers and the claim pool. The point at which text becomes legible. Layer recycling, priority claims, grant/revoke events, degradation to in-scene quads. ([Rendering](rendering.md#the-layer-pool))
2. Monitor mirroring and host input injection. The point at which the system becomes useful: the user can see and drive the real desktop from inside VR. Portal capture with `mapping_id` identification, uinput injection. ([Host desktop](host-desktop.md))
3. Keyboard, seats, clipboard. Typing works, two hands work, copy-paste crosses the boundary. ([Input](input.md), [Host desktop](host-desktop.md#clipboard))
4. Panel standard library. Tiers 1 through 3: panels, interaction, layouts and rules. ([Standard library](stdlib.md))
5. Reload, `lunctl`, error handling. The iteration loop closes; the window manager becomes inspectable from a shell. ([The Lua API](lua-api.md))
6. Per-window outputs, fractional scale, frame pacing. Sharpness and efficiency. ([Compositor](compositor.md#outputs), [Rendering](rendering.md#frame-pacing))

Mirroring lands before the standard library on purpose. Seeing the real desktop in VR carries the project further than a window abstraction alone, and it exercises capture, injection, input domains, and the layer pool against real content.

## Beyond v1

Roughly WayVR's feature surface, plus the items this architecture makes easier.

- Dashboard, launcher, notifications, watch or wrist menu, settings, taskbar, as example config rather than library code.
- [Per-application spatial audio](audio.md).
- Explicit sync (`linux-drm-syncobj-v1`) and the LÖVR external-semaphore patch.
- `ext-image-copy-capture-v1` in `wlx-capture`, contributed upstream.
- libei injection via the portal.
- IME integration (fcitx5 and similar).
- GPU-headless test harness.

## Upstream work, opportunistically

- LÖVR: Vulkan handle export, foreign image import, `LOVR_BUILD_STATIC`, configurable `MAX_LAYERS`, embedding entry points.
- `wlx-capture`: portal `mapping_id` identification, `ext-image-copy-capture-v1`.
- WayVR: anything from the above that applies to it.
