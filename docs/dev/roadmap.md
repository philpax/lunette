# Roadmap

## Milestone 0: the vertical slice

Milestone 0 existed to retire risk. The Rust host boots LÖVR, starts an embedded smithay compositor with one output, spawns one client, imports its dmabuf, draws it on a quad in the scene, casts a ray from a controller, and clicks the quad. It has no composition layers, monitor mirroring, standard library, `lunctl`, reload, or second seat.

It tested two unknowns that would have changed the downstream design: whether LÖVR's Vulkan path accepts a foreign image imported from `VK_QUEUE_FAMILY_FOREIGN_EXT` with implicit sync, and whether the split between the compositor thread and the main thread, with Lua reading snapshots, holds up in use. [Milestone 0 findings](2026-08-06-milestone-0-findings.md) records the measurements, which come from one NVIDIA driver, and the gates still outstanding.

## v1: the daily driver

v1 is the point at which the system is usable for daily work. Each step is usable on its own.

1. Composition layers and the claim pool: legible text, layer recycling, priority claims, grant and revoke events, and fallback to scene quads ([Rendering](rendering.md#the-layer-pool)).
2. Monitor mirroring and host input injection: portal capture correlated to outputs by logical geometry, and uinput injection ([Host desktop](host-desktop.md)).
3. Keyboard, seats, and clipboard: typing, two hands, and copy and paste across the host boundary ([Input](input.md)).
4. The panel standard library: panels, interaction, layouts, rules, and placement as built-in providers on the plugin runtime ([Standard library](stdlib.md)).
5. Reload, `lunctl`, and error handling ([The Lua API](lua-api.md)).
6. Per-window outputs, fractional scale, and frame pacing, applied by the `desktop/pacing` and `desktop/scale` entries and on by default (issue #38) ([Compositor](compositor.md#outputs), [Rendering](rendering.md#frame-pacing)).

Mirroring comes before the standard library because seeing and driving the real desktop in VR is useful on its own, and it exercises capture, injection, input domains, and the layer pool against real content.

All six steps are implemented and covered by hardware-free tests. The shipped desktop runs `@lunette-desktop`, and logic-headless tests drive it over the fake native API through provider outages, persistence, monitor hotplug, reopened windows, and ten production source reloads.

## VR session UI

Every session workflow is reachable through VR controls. The `lunette/ui` provider supplies owner-scoped flat panels with buttons, text fields, choices, lists, regions, and shared titlebars ([UI panels](lua-api.md#ui-panels)). The wrist menu renders `lunette/menu` actions: Keyboard toggles the shared keyboard display, Reload configuration reloads, Plugins opens the runtime manager, the theme selector lists catalog themes, and a configuration with several workspaces adds workspace choices. The runtime manager inspects and edits the plugin composition with controller input and the shared keyboard. The checked `examples/ui` configuration adds a third-party form through the public contracts, and logic-headless tests run its controller workflow.

The toolkit does not implement text shaping, bidirectional editing, IME or preedit composition, or general layout containers.

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

- LÖVR: external-memory device extensions, foreign image import, and a configurable `MAX_LAYERS`.
- `wlx-capture`: selecting every monitor in one portal dialog and correlating the streams to outputs by logical geometry, and `ext-image-copy-capture-v1`.
- WayVR: whatever of the above applies to it.
