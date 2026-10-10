# Roadmap

v1, the point at which the system is usable for daily work, is implemented and covered by hardware-free tests. What remains are the gates that need an operator and the work beyond v1.

## Human gates

The automated checks run without a headset, GPU-backed session, or host desktop. The following remain unverified and need an operator:

- An actual XR or GPU-backed boot of the shipped configuration, and execution of an installed session.
- `manual_xr_widget_and_manager_acceptance`: controller-only discovery, two-hand capture, grab and scroll, keyboard readability and placement, text editing and errors, long-list overflow, manager close and reopen, focus hand-off to applications, and reload, on the target headset and runtime.
- The theme and rounded-geometry gates in [Desktop configuration](../guide/desktop-configuration.md): `theme-runtime-switch`, `theme-appearance-matrix`, `theme-font-fit`, `theme-documentation-check`, `theme-rounded-content`, `theme-joined-frame`, `theme-widget-edges`, and `theme-rendering-exceptions`.
- Host-desktop acceptance of capture, injection, the clipboard bridge, and physical keypad lock state.
- OpenVR controller bindings and haptics on SteamVR beyond the observed controllers ([Input](input.md#known-gaps)).

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
