# Roadmap

## Milestone 0 — the vertical slice

**Purpose: de-risk. Nothing else.**

Rust host boots LÖVR → embedded smithay compositor with one hardcoded output → spawn one client → import its dmabuf → draw it on a quad in-scene → raycast from a controller → click it.

No composition layers, no monitor mirroring, no standard library, no `lunctl`, no reload, no seats beyond one.

Two things here are most likely to hurt, and both are cheaper to discover in a 2000-line prototype than after a standard library exists:

1. **The LÖVR Vulkan patch.** Does `TextureInfo.handle` accept a foreign image cleanly? Does LÖVR's internal layout and queue-family handling cooperate with an image that arrived from `VK_QUEUE_FAMILY_FOREIGN_EXT` in an undefined layout? Is implicit sync sufficient in practice?
2. **The thread split.** Does the compositor-thread/main-thread division hold up, and is the snapshot model as workable in practice as it is on paper?

If either answer is bad, everything downstream changes.

## v1 — the daily driver

The point at which you could actually work in it. Each step is usable on its own.

1. **Composition layers and the claim pool.** The moment text becomes legible. Layer recycling, priority claims, grant/revoke events, degradation to in-scene quads. ([Rendering](rendering.md#the-layer-pool))
2. **Monitor mirroring and host input injection.** The moment it's useful — you can see and drive your real desktop from inside VR, which is motivating in a way that a nice window abstraction isn't. Portal capture with `mapping_id` identification, uinput injection. ([Host desktop](host-desktop.md))
3. **Keyboard, seats, clipboard.** Typing works, two hands work, copy-paste crosses the boundary. ([Input](input.md), [Host desktop](host-desktop.md#clipboard))
4. **Panel standard library.** Tiers 1–3: panels, interaction, layouts and rules. ([Standard library](stdlib.md))
5. **Reload, `lunctl`, error handling.** The iteration loop closes; the WM becomes inspectable from a shell. ([The Lua API](lua-api.md))
6. **Per-window outputs, fractional scale, frame pacing.** Sharpness and efficiency. ([Compositor](compositor.md#outputs), [Rendering](rendering.md#frame-pacing))

Mirroring lands before the standard library on purpose. "I can see my desktop in VR" carries a project further than "I have a nice window abstraction", and it exercises capture, injection, input domains, and the layer pool against real content.

## Beyond v1

Roughly WayVR's feature surface, plus the things only this architecture makes easy.

- Dashboard, launcher, notifications, watch or wrist menu, settings, taskbar — as example config, not library code.
- [Per-application spatial audio](audio.md).
- Explicit sync (`linux-drm-syncobj-v1`) and the LÖVR external-semaphore patch.
- `ext-image-copy-capture-v1` in `wlx-capture`, contributed upstream.
- libei injection via the portal.
- IME integration (fcitx5 and friends).
- GPU-headless test harness.

## Upstream work, opportunistically

- LÖVR: Vulkan handle export, foreign image import, `LOVR_BUILD_STATIC`, configurable `MAX_LAYERS`, embedding entry points.
- `wlx-capture`: portal `mapping_id` identification, `ext-image-copy-capture-v1`.
- WayVR: anything from the above that applies to them.
