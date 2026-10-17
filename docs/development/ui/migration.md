# Migration

The design in the other UI documents replaces the earlier `lunette/ui` toolkit, as tracked in #54. Everything specific to that replacement lives in the migration record, which is deleted when the migration is complete. The other documents describe the toolkit as designed and do not refer to the earlier one.

## The earlier toolkit

The `lunette/ui` contract was `lua/lunette-contracts/ui.luau`, at version 3. Its provider was `lua/lunette-plugins/ui/toolkit/`, about 4,350 lines of Lua across 27 modules. Both are removed.

A panel is a flat quad in the scene. A consumer registers each control with an absolute rectangle in the panel's top-left, y-down logical pixels. The control kinds are `button`, `text-field`, `choice`, `list`, and `region`, which is a caller-drawn control. A panel is a flat list of rectangles ordered by `z` and registration order, with no containers, measurement, or parent and child relationship.

Every control is drawn every frame. Each control builds a fresh visual table and passes it through the drawing functions. Rounded shapes are CPU-clipped meshes with a per-size cache, and text is clipped by computing a conservative rectangle inside the rounded corners. Text is a single line, ellipsised at grapheme boundaries, and drawn with `pass:text` rotated by pi about the x axis to undo the panel's y-down flip. The only native code in the text path is `lunette.textBoundaries`, which returns grapheme boundaries.

Input is entirely Lua. The interaction contract in [`lua/lunette-contracts/vocabulary.luau`](../../../lua/lunette-contracts/vocabulary.luau) models a pointer as a ray with an origin, a direction, an analog trigger, buttons, a grip state, and scroll axes. A surface implements `raycast`, which returns one hit. Pointer events are enter, leave, move, press, release, scroll, and cancel. The controller laser and the hand-pointers plugin drive pointers. The laser filters its ray with a one-euro filter (`input/laser/private/aim.luau`) and locks it during a trigger pull (`input/laser/private/trigger-lock.luau`). There is no point interactor for touch, no tracked-hand input, and no mouse cursor in the scene. The panel picks the topmost control whose rectangle contains the hit. Hover and capture are tracked per pointer and per button, and a held control refuses a second pointer. Text fields and regions take keyboard focus on press, buttons do not, and there is no focus traversal between controls. Hiding, disabling, destroying, resizing, or changing a control's bounds or items cancels its capture, as [`panels-and-ui.md`](../../../lua/lunette-contracts/panels-and-ui.md) guarantees.

### Limitations

1. Every rectangle is placed by hand. The backdrop panel is a fixed 860x1375 canvas, and the plugin manager carries its own grid layout with hard-coded row heights.
2. A choice opens inside its own bounds, so a caller reserves the full open height permanently. There is no overlay layer.
3. There is no label or text widget. Status text needs a region whose draw hook calls `pass:text` and undoes the flip by hand. Four consumers copy that flip, and getting it wrong once mirrored the backdrop panel's status text.
4. Text does not wrap and is not shaped. Consumers reimplement wrapping: the manager with `font:getLines` and the errors overlay by byte columns. The choice chevron is drawn with line strokes because the default font has no arrow glyph.
5. The widget set has no toggle, slider, stepper, segmented control, tabs, scroll container, tooltip, popover, dialog, progress indicator, image, icon, or separator. On and off settings are two-item choices, continuous values are five-step presets, and the manager draws booleans as buttons labelled `name: true`.
6. Items and labels are single strings, so structure is encoded as text, such as `Group: label [selected] [disabled]` in the wrist menu.
7. A disabled control cannot show why it is disabled. The reason goes into the label instead.
8. Nothing is reactive, and a control's label cannot change. The manager contains a hand-written keyed reconciler that diffs with deep equality and recreates controls whose labels change. It also rebuilds every 0.25 seconds because the composition service publishes no change events. The backdrop panel re-sets every value each frame.
9. Panels are flat. The provider flattens the structured global theme into one token bag with one font size, so the manager caps tokens to keep fixed-size slots from overflowing.
10. Hit targets are rectangles, while the panel silhouette is rounded. Custom draw hooks are not clipped by the provider and must restore pass state.

## Consumers

Paths are relative to `lua/lunette-plugins/` unless they start with `examples/`.

The plugin manager, `session/plugin-manager/`, is about 3,400 lines of production Lua. It shows an entry list or a dependency graph canvas, a toolbar of view and filter actions, and a sidebar with Inspect, Configure, and Catalog tabs. Inspect is a scrolling block of diagnostic text. Configure is a schema-driven editor with a row list and a value editor. Lifecycle actions are enabled by predicates with no visible reason. Destructive actions have no confirmation. The graph canvas is a region with its own capture state machine, a drag threshold, pan, zoom, edge hit testing, and Liang-Barsky clipping of lines. #43 redesigns the manager around progressive disclosure on the new toolkit, and its Configure editor needs number, vector, and colour fields with validation.

The wrist menu, `menu/wrist-menu/`, attaches a panel to a tracked hand. Closed, it is one button. Open, it is a titlebar and a list of every registered menu action, with grouping, radio selection, and disabled state encoded in labels. It destroys and recreates controls to switch modes. #20 redesigns it with launching, monitor mirrors, pending and failed states, retry, grouping, and search. Its content stays data from the menu broker and the #45 catalogs, so search and grouping work across contributors.

The backdrop controls, `environment/backdrop/private/controls/`, expose two toggles faked as choices, an audio source choice, an applications list, response and motion presets standing in for sliders, a diagnostic view choice, and status text drawn through a region. The response and motion settings are continuous values from 0 to 1 in the backdrop's configuration, and the presets None, Low, Medium, High, and Full map to 0, 0.25, 0.5, 0.75, and 1. The panel polls every frame while visible.

Titlebars, `ui/toolkit/private/titlebar/`, and window decorations, `panels/decorations/`, add titlebars with close and action buttons to panels. Monitor decorations concatenate status and error text into button labels because there is no status slot. The panels service draws each window panel's title itself with `pass:text`, in `draw.chrome` in `panels/service/private/draw.luau`, so the title stays flat on a curved window.

The errors overlay, `diagnostics/error-display/`, and the empty-desktop hint, `environment/empty-desktop-hint/`, draw world-space text directly. The errors overlay wraps by character columns and cannot be dismissed, scrolled, or browsed.

The virtual keyboard, `input/keyboard/` and `input/keyboard-display/`, has its own drawing, raycast, hover, and capture, and reuses only the titlebar. Its key legends come from the compositor seat through `seat:symbolFor`. #6 adds arrow and navigation keys, and they carry over to the toolkit keyboard.

The UI example, `examples/ui/form.luau`, uses each control kind once. Other examples, such as `examples/first-plugin/`, the audio backdrop's meter, and the tiny keyboard example, draw text with `pass:text` to demonstrate LÖVR drawing in a plugin. They are not panels, and they keep drawing directly.

The consumers need these capabilities. The count is the number of consumers that need each one.

| Capability | Consumers |
|---|---|
| Static and wrapped text with ellipsis and overflow | 6 |
| Toggle, checkbox, or selected state on menu rows | 4 |
| A visible reason for a disabled control | 4 |
| Layout containers and content sizing | 3 |
| Change-driven updates instead of polling | 3 |
| Titlebar actions with status | 3 |
| Scroll containers for arbitrary content | 2 |
| Tabs and segmented controls | 2 |
| Grouped lists with section headers and action rows | 2 |
| A custom drawing node clipped by the toolkit, with capture that survives updates | 2 |
| Text fields with inline errors, keyboard summoning, and programmatic focus | 2 |
| Per-panel density instead of per-control theme overrides | 2 |
| Sliders and steppers | 1 |
| Confirmation dialogs | 1 |
| Compact and expanded modes of one panel | 1 |

Every VR test of these consumers addresses controls by panel name, control id, and item id through `inspect()` and the `@testing/vr-ui` helpers `describe`, `discover`, and `clickControl`.

## Decisions reversed

- The earlier design kept larger interfaces as Wayland clients and limited `lunette/ui` to small VR controls. The plugin manager, the wrist menu, and the backdrop controls are in-session interfaces regardless, so all in-session interfaces are now built with the toolkit. The statement survives in the earlier toolkit's README and is removed with it.
- The earlier guide listed layout containers and a general widget framework as outside the contract. Both are now in scope.
- The earlier rendering design clipped rounded panels with CPU-clipped meshes and a conservative rectangle, and rejected stencil and offscreen clipping because they added pass requirements and composition cost for small controls. The toolkit clips in a shader in local space instead, which follows the pose, works at any depth, and adds no pass.
- The earlier toolkit cancelled a capture whenever a control's bounds changed. The toolkit keeps the capture through relayout and defers content resizing while a capture is live, because relayout is routine under change-driven rendering.

The normative documents state each of these decisions with its reason: [README](README.md#decisions-in-brief) for in-session interfaces, [Requirements](requirements.md) for the scope, [Rendering](rendering.md#clipping) for clipping, and [Input](input.md#capture-and-cancellation) for capture. They remain when this record is deleted.

## Prerequisites

Services that the migrated consumers read publish observable stores, so that components update on change rather than by polling. The composition service is the first, because the plugin manager polls it. The backdrop service, the theme service, and the panels service follow as their consumers migrate. The #45 catalog and creation-request contracts publish their state and request progress as stores from the start. The read-only store type lives in the neutral contract vocabulary.

Contract revisions:

- `lunette/menu` version 2, before the wrist menu migrates. An action gains a disabled reason, an icon, a detail line, and a selection kind of none, toggle, or radio, and its label, reason, and icon can change through its state. The broker publishes its actions as a store rather than through `onChanged`, and records each action's contributing plugin.
- `lunette/focus` version 3. Targets receive held keys with key-up, keys are released on route loss, the focus service repeats held keys from virtual sources only, targets carry an input hint, and text is mapped with a session keymap that does not depend on a `lunette.Seat`. The frame service dispatches key releases.
- The interaction contract: one interaction pass per frame owned by the interaction service, with `beforePick` and `afterDelivery` hooks; owner-scoped `pick` registrations and the proximity query; the outside-press observer; manipulation sessions; surface shapes in metres on every surface; the extended set of cancellation reasons; and a pinch press state with hysteresis.
- The frame service: a draw phase after the opaque content of the scene, for faded panels.
- The plugin runtime's protection rule: providers that a protected entry depends on can be reloaded and reconfigured at runtime, but not disabled. The runtime records the last configuration under which the toolkit's entries activated and stayed healthy.

New services and plugins:

- The standard kinds entry, `ui/standard`, providing `lunette/ui-standard-kinds`.
- The accessibility settings service, `lunette/accessibility`, with its settings panel, its own persisted settings file, and its event stream.
- The input mode service, `lunette/input-modes`.
- The notifications service, `lunette/notifications`, with progress, prompts, and a history panel.
- The clipboard service, `lunette/clipboard`, which is platform-neutral, with a Wayland backend. #27 verifies the underlying bridge.
- The recovery plugin, `diagnostics/recovery`, which does not depend on the toolkit and is a protected entry in `lua/lunette-desktop/init.luau`.

Native additions:

- The layout tree over taffy's low-level API, the text module, the glyph atlas, the image atlas, and instance packing, with their release in the restart ordering before the Lua state closes.
- Native read and offer of the compositor's selection for the clipboard service's Wayland backend. The same compositor-originated data source is the open question for bridging drag sessions to Wayland drags.
- A request to restart the session into the compiled-in safe mode.
- A link directive for `libmsdfgen` in `crates/lunette-lovr/build.rs`. The library is already installed with LÖVR.
- resvg for SVG rasterisation, a new dependency pinned exactly. The Markdown composite parses in Lua, so it needs no native parser.
- The IBM Plex Sans and Iosevka fonts, bundled with their licences and recorded in CREDITS.md.

The UI host's theme carries the default theme in [Theming](theming.md#the-default-theme): surface roles including sides and header bands, the accent with its guard, elevation, and motion. The standard Dark and Light themes are the lunette theme's two modes. The earlier theme contract, its catalog and selector, and the Arcade theme are removed, and the keyboard, laser, mouse cursor, and window outlines read the session theme from the theme provider, below the host.
- A maximum for panel curvature in the panels service, which today validates only that the curve is not negative.
- The `getHandPose` declaration's metadata, which must state the zero result for an unavailable pose.

#64 enables Luau optimisation level 2 and native code generation. The toolkit does not depend on it. With layout in Rust, the toolkit's Lua hot paths are the reconciler, visual runs, hit testing, gesture resolution, and layout callbacks, and #64's measurements inform how much of that work needs attention.

## Spikes

Each spike answers a question that would change the design if the answer were negative. Spikes are throwaway code on the feature branch. Their results are recorded in the design document the question belongs to, and their code is deleted or rewritten before it merges.

1. Toolkit shader. A LÖVR custom shader draws instanced boxes and glyph quads from per-instance data, with clipping by a rounded rectangle with a depth range, elevation, the flat and cylinder shapes selected by shape id, content mapped through its box's chords, and bound parameters read from a per-node buffer and a per-panel interactor uniform. The spike confirms that text at the 0.25 mm content offset never fights its box at 1 to 3 metres, at oblique angles, on the D24 fallback, and on a cylinder at the maximum curvature; that a hovered raised button keeps its label inside a scroll box; that alpha to coverage gives clean edges with the session's 4x multisampling; that a two-pass group opacity fade with text looks correct in stereo; that clipping rigid content through a shape's inverse works; and that the result passes an offscreen pixel test.
2. Draw cost. A synthetic tree of about 1,000 nodes, the size of the plugin manager's settings pages with headroom, draws and scrolls every frame in a session, with instance data packed in Rust. The spike records CPU frame time, upload size, and draw calls in four cases: several panels idle with hands tracked, a ray sweeping across panels, a fling through a virtualised list, and a slider drag that re-renders a component every frame. A cost that does not fit the frame budget changes the batching or hit-testing design before any kind is written.
3. Text. cosmic-text shapes and wraps text, skrifa supplies outlines by glyph id, and msdfgen, linked directly as `libmsdfgen`, rasterises them into a paged atlas that LÖVR samples. The spike compares the result with LÖVR's own text at small sizes, compares msdfgen with a Rust distance field crate, measures the font database's startup cost, checks that a burst of new glyphs generates in the background without stalling a frame, and checks that the atlas survives a restart of the Lua state without validation errors.
4. Layout binding. A tree over taffy's low-level API accepts batched changes and returns flat layout arrays with composed positions, including for descendants of moved nodes whose layout was cached, with native text measurement. A scripted layout written in Lua sizes itself from its children through a context that re-enters the computation through mlua's scoped userdata, and places absolutely positioned descendants as their containing block. The spike measures the cost of a commit that changes one text node in a 1,000-node tree, the cost of a scripted layout under taffy's repeated sizing passes, and the nesting depth that Luau's call limits allow.
5. Hand tracking. `getHandPose` and `getSkeleton` drive a poke point, a pinch ray, and a grab sphere in a headset session, with the fingertip proxy. The spike confirms that they, and controller haptics, work in an XR_EXTX_overlay session on the maintainer's runtime, which #24 verifies first; records how the hand source switches between controller and hand modes, with and without XR_EXT_hand_tracking_data_source; and sets the pinch thresholds and the near-touch gaps against measured jitter. It needs a headset and a runtime that supports hand tracking, so it runs on the maintainer's setup. The interactor model can be built against fake XR before it runs.

## Stages

The work proceeds in stages. Each stage ends at a checkpoint that the hardware-free checks verify, so most of the work can proceed and be verified without a headset or a window. The first release is the end of stage 9, which meets #54's done-when.

### Verification without hardware

Three layers of checks need no headset and no window:

- Lua tests run the real host, kinds, authoring library, and native layout and text binding in the Lua test runner, with bundled fonts and a stepped clock. Layout calculations, text measurement, routing, gesture resolution, focus traversal, and inspection are verified there.
- Offscreen graphics tests in `make check-graphics` render panels through real LÖVR with the lavapipe software Vulkan driver and read back pixels. They verify the toolkit shader. A snapshot harness in the same suite renders a panel, such as a page of the widget gallery, to a PNG file at a chosen pose and scale, so a contributor or an agent can look at the result and compare it against a reference.
- Interaction tests drive fake XR sessions, including fake hand poses, through `@testing/vr-ui`.

The desktop simulator runs the real session without an XR runtime, with the mouse as the interactor, for checking by hand on a desktop. Tracked hands are implemented against fake XR and verified in a headset when one with hand tracking is available.

### The widget gallery

A development plugin, `dev/plugins/ui-gallery`, shows every standard kind and composite on pages grouped by family: display, actions, choices, values, collections, structure, and overlays. Each page shows the kind's states, such as hovered, pressed, focused, disabled with a reason, and invalid, and a page of combined layouts shows how the kinds fit together. Controls on the gallery switch the theme, density, presentation, curvature, reduced motion, text scale, and default appearance. The development configuration loads it, it is not shipped, and the snapshot harness renders each page, so the gallery is also the visual regression fixture.

### Stages to the first release

0. Harness. The snapshot harness, the gallery's skeleton, and the test helpers that later stages use. Checkpoint: a blank gallery page renders to a PNG offscreen.
1. Native layout and text. The layout tree over taffy's low-level API, scripted layout callbacks, the text module with cosmic-text, the glyph atlas with msdfgen, and their Rust and Lua tests. This stage absorbs spikes 3 and 4. Checkpoint: Lua tests lay out and measure nested flex, grid, and text through the real binding.
2. Shader and drawing. The toolkit shader, the drawing API, instance packing, clipping, curvature with content mapped through chords, draw order, and group opacity. This stage absorbs spike 1. Checkpoint: pixel tests for each rendering rule, and snapshot PNGs of boxes and text on flat and curved surfaces.
3. Interaction pass for rays. The interaction service's single pass, hit records, gesture claims, capture and cancellation reasons, and the event vocabulary, with the controller laser and the mouse as interactor providers. Window panels keep working through the ray path. Checkpoint: interaction tests with fake controllers and the existing window panel tests pass.
4. Host core and authoring. The element format, mount points, panels and the standard presentations, the node tree and spatial model for `flow` and `scripted` placement, composite expansion, kind and visual registries, routing, focus and traversal, inspection, and the React-like library. Checkpoint: component tests mount trees, route events, and traverse focus.
5. First kinds and the backdrop slice. The standard kinds entry with text, box containers, button, toggle, slider with detents, segmented control, and list rows, the components plugin, the backdrop controls migrated, and the gallery's first pages. Checkpoint: the backdrop controls work in the desktop simulator and in their VR tests, and gallery snapshots render.
6. The rest of the widget set. Every remaining kind in [Requirements](requirements.md#capabilities), portals, dialogs, notifications, virtualisation, motion and feedback, the clipboard, and default appearance, each added to the gallery. Checkpoint: kind tests and gallery snapshots for every kind.
7. Tracked hands, speculatively. Poke, pinch, and grab-sphere interactors, near touch, the fingertip proxy, and pinch thresholds, implemented against fake XR with the documented starting values. Checkpoint: interaction tests with fake hands. Spike 5 and tuning happen later, in a headset.
8. Consumers. The UI example, the wrist menu on `lunette/menu` version 2, titlebars and decorations, the errors overlay and hint, the recovery plugin, the virtual keyboard on `lunette/focus` version 3, and the plugin manager port, with the manager slice built early in this stage. Checkpoint: every consumer's VR tests address nodes by id.
9. Removal. The `lunette/ui` contract, its provider, and its tests are removed. Checkpoint: #54's done-when, with tracked hands verified under fake XR.

### After the first release

These parts of the design are specified but not needed for the first release, and follow it:

- The `posed` and `attach` placements, meshes, registered shapes beyond the flat plane and the cylinder, and orientation constraints.
- Manipulation sessions beyond panel grab, node-level `manipulate` claims, and the policy that #47 defines.
- Drag sessions across panels and the bridge to Wayland drags.
- The Markdown composite, the image atlas, and SVG icons beyond what the wrist menu needs.
- Headset tuning of the hand interactors, the near-touch gaps, and the fingertip proxy, and a full hand mesh.
- The redesigns in #43 and #20.

### Vertical slices

Two vertical slices run through stages 1 to 5 before the host contract is frozen:

- The backdrop controls, built through a minimal host, a few kinds, the authoring library, the shader, and taffy, with controller and mouse input. They are the smallest real consumer that exercises layout, text, a toggle, a slider with detents, a list, a disabled reason, and a store.
- A plugin manager slice, at the start of stage 8 or earlier: the graph canvas as a kind with items, and a dense virtualised list of settings rows with a form editor. It exercises transforms, gesture claims, items, virtualised items as components, a scripted layout, and focus traversal at the manager's scale.

## Migration order

1. Backdrop controls, as the first vertical slice. Response and Motion become sliders with detents at the existing preset values, which needs #60's statement about dropdowns updated first. The preset picker that #60 adds goes into the same panel once #60 lands.
2. The UI example and its guide, [`docs/plugins/ui.md`](../../plugins/ui.md), which become the reference for plugin authors.
3. Wrist menu, with the wrist and summoned presentations, their one-handed summon bindings, and a default-appearance entry, rendering the revised broker's data and catalog data. The redesign in #20 builds on this.
4. Titlebars, window decorations, and the window title that `draw.chrome` draws, as attached presentations that share their panels' surface shapes. Grab handles, resize and scale frames, and curvature handles become toolkit kinds, which #8, #47, and #48 build on.
5. Errors overlay and empty-desktop hint, as toolkit panels, and the recovery plugin. The errors overlay gains dismissal, history, and deduplication.
6. Virtual keyboard, as a toolkit panel with non-focusing keys that act on press and send key-up on release, input-hint layouts, and a paste key, on the revised focus contract. Its key legends stop depending on the compositor seat as part of #63.
7. Plugin manager, ported from the slice above with its current design: the same views, tabs, and actions, built from toolkit components, with an entry for default appearance and a view of which plugins override what. Its reconciler, grid layout, text wrapping, line clipping, and polling are deleted rather than ported. The redesign in #43 follows the migration on the toolkit and does not block #54.

Each migration replaces the consumer's VR tests with tests that address nodes by id, and updates the consumer's README and any guide that describes it. The `@testing/vr-ui` helpers move from panel, control, and item ids to node ids. `aim` takes an interactor and a node id, and `poke`, `grab`, `clickNode`, `tab`, `navigate`, `activate`, `context`, `dismiss`, `nextPanel`, and `defaultAppearance` are added, with `getHandPose` answers in the fake XR session for `poke` and `grab`. The earlier toolkit's test that asserts no `setScissor` call is replaced by an offscreen pixel test of the clip.

## Documentation changes

When the toolkit merges, the guarantees that replacement providers and consumers rely on move into contract documentation beside the new contracts, in the way [`panels-and-ui.md`](../../../lua/lunette-contracts/panels-and-ui.md) records the earlier toolkit's guarantees. The plugin author guide in [`docs/plugins/ui.md`](../../plugins/ui.md) is rewritten around components, kinds, visuals, and outlets, with a checked minimal example. The host, the standard kinds, and the components each get a README beside their implementation. The user guide for the runtime manager documents default appearance and its chord, the recovery plugin, the last known good configuration, which entries are protected and what protection refuses, and the accessibility settings.

## Done when

Every in-tree panel is built from toolkit components with no absolute control rectangles and no consumer-drawn text: the backdrop controls, the plugin manager, the wrist menu, titlebars, decorations, window titles, the errors overlay, the hint, the virtual keyboard, and the UI example. The recovery plugin, which draws without the toolkit by design, is exempt. Each panel has VR tests that address nodes by id. Controller rays operate every panel in the headset. Tracked hands operate every panel in the headset where the runtime supports hand tracking in the overlay session, and under fake XR otherwise, and the record of the migration says which applied. The mouse ray interactor operates every panel under fake input, and mouse operation in a live session depends on host mouse capture from #49 and is verified there. Every action is reachable without a physical keyboard or mouse, through pointing and through focus traversal on one controller, and default appearance restores a usable interface with a deliberately broken override active. The spike results are recorded in the design documents, and the migration record is deleted.

## Progress

Stages 0 to 9 are implemented on `feature/ui-toolkit` and verified without hardware, through the Lua suites, fake XR, and offscreen snapshots. No part has been checked in a headset. Every consumer listed above is built on the toolkit, and the earlier toolkit is removed. Beyond the first release, the attach presentation, outlets, the recovery plugin, default appearance, and a mouse ray from the head without host capture are implemented.

These parts of the design remain open:

- Pick hooks and the proximity query, and default appearance reached from `lunctl`.
- Grab-sphere interactors, gesture claims that transfer a capture between nodes, drag sessions, and manipulation sessions beyond panel grab. Arbitration covers only a fingertip standing its hand's ray down.
- Carrying transforms and captures in progress across a change of a kind's current registration.
- The glyph atlas's reference counting, eviction of single glyphs rather than whole undrawn pages, the reserved share for interface fonts, and variable-face instances.
- Native instance packing; Lua packs instance data and sends it per batch.
- The panels service's optional chrome title, which still draws with `pass:text` when `chrome` is on; window titles otherwise come from the decorations titlebar.
- Host mouse capture and release, which belong to #49.

## Issue updates

These issues need their text updated to match the design:

- #54: its paths are stale (`docs/dev/stdlib.md`, `docs/guide/ui.md`, `desktop/manager/`), its open implementation choice is decided (taffy's low-level API, cosmic-text, a distance field atlas, scene rendering without offscreen textures or layers), its done-when should match the one above, including the conditions for tracked hands and the mouse and the separation from #43, the keyboard is migrated rather than evaluated, and the recovery plugin and default appearance are added.
- #60 keeps Response and Motion as dropdowns. They become sliders with detents at the same levels, with None at 0, in the backdrop controls panel that the first vertical slice rebuilds; the preset picker joins that panel.
- #64 names layout in #54 as a motivation. Layout is native, and the Lua hot paths are the ones listed in [Prerequisites](#prerequisites).
- #48: UI panels never use layers, and lunette's window layers are quads, so its cylinder-layer verification needs restating; curvature persistence is a requirement with a format version bump; the control is a curvature handle kind; and curvature has a maximum.
- #49 should note that the toolkit's mouse ray starts at the head while the projection model stays with #49, that panels move in depth with the wheel and a modifier, that manipulation sessions take key routing for its chords, and that the toolkit needs source-loss cancellation and the context action.
- #43 should state that the manager is first ported unchanged and then redesigned on the toolkit, and list the form-editor widgets the redesign can use.
- #20 builds on migration step 3, uses notifications with progress and prompts and their history, needs the `lunette/menu` version 2 revision with selection kinds, and has its permission prompts deferred.
- #45 should require catalog and request state to be published as stores.
- #47 should record what the toolkit fixes, gesture precedence and manipulation sessions with node-level claims, and what remains its own: whether translation and rotation are coupled, reach amplification, and moving targets in depth with bare hands. It should also note that world panels keep their physical size by default.
- #8 should note that the content resize frame is the gesture surface and follows the client's committed size, and that keeping the panel's size in metres or its pixel density remains its decision.
- #6 should note that keys send down and up on the `lunette/focus` version 3 revision, and that receivers repeat.
- #59 should note that the host, the standard kinds, and the components plugin can be reloaded at runtime but not disabled, that reloading them remounts every UI tree, and that a consumer's reload remounts only its own trees.
- #21 should add the glyph atlas, the instance buffers, and the toolkit shader to its checks, and expect them to be released before the Lua state closes. #29 should replace its "one laser per hand" check with one interactor set per source, no duplicate mount points, and a stable atlas page count over ten reloads.
- #28 should add non-US layouts and `typeText` into toolkit fields. #30 should note that the chrome title moves with migration step 4, add the recovery plugin and default appearance to its checks, and note that its UI-facing items are repeated after the migration.
- #63 should name the clipboard service's backends, the focus contract's session keymap that replaces `keymapSeat`, and the key legends.
- #27 should note that toolkit copy and paste depend on the native selection API and the bridge it verifies, and that attached chrome can overlap a client popup that overhangs its window.
- #24 should note that spike 5, hand poses, the skeleton, and haptics in the overlay session, depends on it.
- #62 should note that its window selector is a toolkit consumer.

## Related issues

- #54 tracks the rebuild.
- #43 redesigns the plugin manager on the toolkit, after the port.
- #20 redesigns the wrist interface on the toolkit.
- #45 defines the catalog, creation-request, and active-instance contracts that the wrist menu and launcher render.
- #47 redesigns object manipulation, which owns the manipulation policy behind the toolkit's manipulation sessions.
- #8 resizes a window's contents, which uses the content resize frame.
- #48 adds persisted curvature to every panel.
- #49 adds mouse and keyboard interaction for the workspace.
- #60 adds backdrop presets and changes the backdrop controls panel.
- #59 adds per-plugin source reloads, under the narrowed protection rule.
- #62 adds host window capture, whose window selector is a toolkit consumer.
- #63 adds Windows support, which needs text entry, a clipboard, and key legends that do not depend on Wayland.
- #27 verifies the clipboard bridge that the clipboard service uses.
- #24 verifies the overlay session that hand tracking and haptics depend on.
- #39 packages plugins, which is where third-party kind and presentation namespaces meet plugin identity.
- #6 adds navigation keys to the virtual keyboard.
- #21 and #29 verify restart and reload behaviour, which must cover the toolkit shader, the atlases, the instance buffers, and the per-panel layout trees.
- #28 and #30 repeat their UI-facing headset checks after the rebuild.
- #42 revises the VR interface text after the rebuild, following the copy rules in [Accessibility](accessibility.md#localisation).
- #64 enables Luau optimisation and native code generation.
