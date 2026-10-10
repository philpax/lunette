# Roadmap

v1, the point at which the system is usable for daily work, is implemented. What remains is the work beyond v1.

## Beyond v1

Roughly WayVR's feature surface, plus what this architecture makes easier:

- Dashboard, launcher, notifications, settings, and taskbar, as example configurations rather than library code.
- [Per-application spatial audio](audio.md).
- Explicit sync (`linux-drm-syncobj-v1`) and the LÖVR external-semaphore patch.
- `ext-image-copy-capture-v1` in `wlx-capture`, contributed upstream.
- libei injection through the portal.
- Input blocking through libmonado ([Input](input.md#blocking-input-to-the-underlying-application)).
- IME integration, such as fcitx5.
- A GPU-headless test harness.

## Upstream work

- LÖVR: the patches marked upstreamable or as upstream defects in [the patch set](lovr-integration.md#the-patch-set).
- `wlx-capture`: selecting every monitor in one portal dialog and correlating the streams to outputs by logical geometry, and `ext-image-copy-capture-v1`.
- WayVR: whatever of the above applies to it.
