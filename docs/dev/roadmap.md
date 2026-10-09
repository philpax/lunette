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
2. Monitor mirroring and host input injection. The point at which the system becomes useful: the user can see and drive the real desktop from inside VR. Portal capture with streams correlated to outputs by logical geometry, uinput injection. ([Host desktop](host-desktop.md))
3. Keyboard, seats, clipboard. Typing works, two hands work, copy-paste crosses the boundary. ([Input](input.md), [Host desktop](host-desktop.md#clipboard))
4. Panel standard library. Panels, interaction, layouts, and rules, as built-in providers on the plugin runtime. ([Standard library](stdlib.md))
5. Reload, `lunctl`, error handling. The iteration loop closes; the window manager becomes inspectable from a shell. ([The Lua API](lua-api.md))
6. Per-window outputs, fractional scale, frame pacing. Sharpness and efficiency. The policy is the pacing and scale providers, applied by the `desktop/pacing` and `desktop/scale` entries, on by default (issue #38). ([Compositor](compositor.md#outputs), [Rendering](rendering.md#frame-pacing), [The Lua API](lua-api.md#frame-pacing-and-output-scale))

Mirroring lands before the standard library on purpose. Seeing the real desktop in VR carries the project further than a window abstraction alone, and it exercises capture, injection, input domains, and the layer pool against real content.

## Local VR UI

The bounded UI toolkit declares `lunette/ui` at schema 1 and supplies owner-scoped flat panels, buttons, single-line text fields, choices, lists, and regions through `@lunette-plugins/ui`. Input, drawing, and detached descriptions share declared logical geometry. Themes and draw hooks change appearance without changing hit bounds. Frozen provider and creation-owner activation tokens distinguish replacements that reuse panel names and control ids. Control ids span all live panels per actual creation owner, and different owners can reuse an id in one panel. A description identifies a live control through the generation token, owner token, and id without exposing contexts or scripting authority. Native `lunette.textBoundaries`, backed by `unicode-segmentation` 1.13.3, supplies whole-grapheme editing offsets. [UI panels](lua-api.md#ui-panels) states the contract, and the [UI guide](../guide/ui.md) gives a public-contract checker fixture.

The neutral `lunette/menu` action broker and `lunette/keyboard-display` shared display are implemented. `desktop/menu` renders the tracked wrist Menu button and scrollable action list through `lunette/ui`. `desktop/actions` registers Keyboard and Reload configuration, and the optional workspace consumer registers name-only workspace choices. Keyboard toggles the shared display. Plugins opens the manager panel. The manager uses shared UI controls for search, configuration, graph navigation, inspection, lifecycle actions, recovery, and catalog loading. The graph uses a custom region; stable control IDs identify controls in panel descriptions. Pure graph and editor logic, detailed runtime snapshots, actual dependency bindings, and opaque-value preservation remain unchanged. The manager has no `toggleKey` option or global frame key/text handlers. Its schema rejects legacy `toggleKey` with a migration diagnostic that directs the configuration to open Plugins from the session menu.

`settings.menu` owns wrist geometry and haptics; `settings.keyboardDisplay` configures keyboard placement only. The neutral bindings provider remains available for custom inputs. The desktop example uses `save-menu` and `hide-windows` menu actions. The configuration descriptors and default entry list remain the sources of truth for those options.

The checked `examples/ui` configuration provides a movable public-contract form with button, field, choice, list, and custom drawing. Logic-headless scenarios run the form, manager Search, and application hand-off against both UI implementations, including twelve provider-outage rows and ten production source reloads per implementation. Those scenarios preserve one shared keyboard and invalidate ended controls, captures, focus targets, and menu registrations.

The remaining UI work is installed-session execution, GPU-backed drawing and pass restoration, and every control workflow in the headset without a physical keyboard or mouse.

Installed-session execution, production LÖVR virtual-filesystem mounting, and GPU-backed drawing remain unverified here. The named follow-up `manual_xr_widget_and_manager_acceptance` remains open. It covers controller-only discovery, both-hand capture, grab and scroll, keyboard readability and placement, text editing and errors, long-list overflow, manager close and reopen, application focus hand-off, and reload on the target headset and runtime. No test or documentation review establishes those perceptual or GPU properties.

The current toolkit does not implement full text shaping, bidirectional editing, IME or preedit composition, general layout containers, or a complete desktop widget framework. Grapheme segmentation does not establish those capabilities. Type-check and logic-headless fixtures do not establish the hardware acceptance gates.

## Beyond v1

Roughly WayVR's feature surface, plus the items this architecture makes easier.

- Dashboard, launcher, notifications, additional watch or wrist controls, settings, and taskbar, as example configurations rather than library code. The shipped wrist menu already exposes session and workspace actions.
- [Per-application spatial audio](audio.md).
- Explicit sync (`linux-drm-syncobj-v1`) and the LÖVR external-semaphore patch.
- `ext-image-copy-capture-v1` in `wlx-capture`, contributed upstream.
- libei injection via the portal.
- IME integration (fcitx5 and similar).
- GPU-headless test harness.

## Upstream work, opportunistically

- LÖVR: external-memory device extensions, foreign image import, configurable `MAX_LAYERS`.
- `wlx-capture`: selecting every monitor in one portal dialog and correlating the returned streams to outputs by logical geometry, `ext-image-copy-capture-v1`.
- WayVR: anything from the above that applies to it.
