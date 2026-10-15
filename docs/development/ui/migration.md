# Migration

The design in the other UI documents replaces the earlier `lunette/ui` toolkit, as tracked in #54. Everything specific to that replacement lives in the migration record, which is deleted when the migration is complete. The other documents describe the toolkit as designed and do not refer to the earlier one.

## The earlier toolkit

The `lunette/ui` contract is [`lua/lunette-contracts/ui.luau`](../../../lua/lunette-contracts/ui.luau), at version 3. Its provider is [`lua/lunette-plugins/ui/toolkit/`](../../../lua/lunette-plugins/ui/toolkit/README.md), about 4,350 lines of Lua across 27 modules.

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

Titlebars, `ui/toolkit/private/titlebar/`, and window decorations, `panels/decorations/`, add titlebars with close and action buttons to panels. Monitor decorations concatenate status and error text into button labels because there is no status slot.

The errors overlay, `diagnostics/error-display/`, and the empty-desktop hint, `environment/empty-desktop-hint/`, draw world-space text directly. The errors overlay wraps by character columns and cannot be dismissed, scrolled, or browsed.

The virtual keyboard, `input/keyboard/` and `input/keyboard-display/`, has its own drawing, raycast, hover, and capture, and reuses only the titlebar. Its key legends come from the compositor seat through `seat:symbolFor`. #6 adds arrow and navigation keys, and they carry over to the toolkit keyboard.

The UI example, `examples/ui/form.luau`, uses each control kind once.

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

Services that the migrated consumers read publish observable stores, so that components update on change rather than by polling. The composition service is the first, because the plugin manager polls it. The backdrop service, the menu broker, the theme service, and the panels service follow as their consumers migrate. The #45 catalog and creation-request contracts publish their state and request progress as stores from the start. The read-only store type lives in the neutral contract vocabulary.

New services that the toolkit depends on:

- The accessibility settings service, `lunette/accessibility`.
- The input mode service, `lunette/input-modes`.
- The notifications service, `lunette/notifications`, with a history panel.
- A clipboard service that bridges to the Wayland selection, for copying from toolkit text.

#64 enables Luau optimisation level 2 and native code generation. The toolkit does not depend on it. With layout in Rust, the toolkit's Lua hot paths are the reconciler, instance-slot rebuilds, hit testing at elevation, gesture resolution, and layout callbacks, and #64's measurements inform how much of that work needs attention.

## Spikes

Each spike answers a question that would change the design if the answer were negative. Spikes are throwaway code on the feature branch. Their results are recorded in the design document the question belongs to, and their code is deleted or rewritten before it merges.

1. Toolkit shader. A LÖVR custom shader draws instanced boxes and glyph quads from per-instance data, with clipping by a local rounded rectangle with a depth range, elevation, the flat and cylinder shapes selected by shape id, and the paint-order depth offset. The spike confirms that the depth buffer resolves the offset for 1,000 paint indices at a metre without changing the order of surfaces separated by the minimum separation, that alpha to coverage gives clean edges with the session's multisampling, and that the result passes an offscreen pixel test. `Pass:mesh` with an instance count, `InstanceIndex`, and buffers bound with `Pass:send` exist, so no fork patch is expected.
2. Draw cost. A synthetic tree of about 1,000 nodes, the size of the plugin manager's settings pages with headroom, draws and scrolls every frame in a session. The spike records CPU frame time, upload size, and draw calls in four cases: several panels idle with hands tracked, a ray sweeping across panels, a scroll every frame, and a slider drag that re-renders a component every frame. A cost that does not fit the frame budget changes the batching or hit-testing design before any kind is written.
3. Text. cosmic-text shapes and wraps text, skrifa supplies outlines by glyph id, and msdfgen, linked directly as `libmsdfgen`, rasterises them into a paged atlas that LÖVR samples. The spike compares the result with LÖVR's own text at small sizes, compares msdfgen with a Rust distance field crate, measures the font database's startup cost, and checks the per-frame glyph budget with a burst of new glyphs. A negative result reopens the fork-patch alternative in [Layout and text](layout-and-text.md#glyph-rendering).
4. Layout binding. A userdata binding of taffy, with rounding disabled, accepts batched changes and returns flat layout arrays with composed positions, with native text measurement and the Lua callback contract. The spike measures the cost of a commit that changes one text node in a 1,000-node tree, and the cost of a Lua measure function called through the dispatcher.
5. Hand tracking. LÖVR's XR_EXT_hand_interaction poses and `getSkeleton` drive a poke point and a pinch ray in a headset session. The spike confirms that both work in an XR_EXTX_overlay session on the maintainer's runtime, settles the `controllerskeleton` setting, and records how the hand source switches between controller and hand modes. It needs a headset and a runtime that supports hand tracking, so it runs on the maintainer's setup. The interactor model can be built against fake XR before it runs.

## Phases

1. Interaction. Sources with modes, interactors with open shapes, surface queries with hit records, arbitration, the event vocabulary including context actions, modifiers, and world-space data, capture and its cancellation reasons, drag sessions, the trigger lock and filter generalised from the laser to every ray, and the input mode service, in the interaction contracts. The laser and hand-pointer plugins move onto interactors, and window panels keep working through the ray path. Tracked hands and the mouse cursor ray are added here. This phase comes first because the toolkit is its main consumer, and designing it separately would mean designing it twice.
2. Native layout and text. The layout tree, the layout callbacks, the text module, the glyph atlas, and their Rust tests.
3. Host. The element format, panels, presentations, portals, the node tree and spatial model, composite expansion, the kind and visual registries, the toolkit shader and drawing API, paint order, hit testing, routing and gesture claims, focus and traversal, animation channels, feedback, and inspection.
4. Authoring library. Elements, components, the hook set, context, stores, scheduling, error handling, and the outlet adapter, with component tests.
5. Standard components. The full kind set listed in [Requirements](requirements.md#capabilities). Each kind has kind tests and an offscreen rendering test of its default visual.
6. Migration of consumers, in the order below.
7. Removal of the `lunette/ui` contract, its provider, and its tests, once no consumer requires it.

Two vertical slices run through phases 2 to 5 before any phase is complete:

- The backdrop controls, built through a minimal host, a few kinds, the authoring library, the shader, and taffy, with controller and mouse input. They are the smallest real consumer that exercises layout, text, a toggle, a slider with detents, a list, a disabled reason, and a store.
- A plugin manager slice: the graph canvas as a kind with items, and a dense virtualised list of settings rows with a form editor. It exercises transforms, gesture claims, items, virtualisation, and focus traversal at the manager's scale before the host contract is frozen, rather than at the end of the migration.

## Migration order

1. Backdrop controls, as the first vertical slice. Response and Motion become sliders with detents at the existing preset values, which needs #60's statement about dropdowns updated first.
2. The UI example and its guide, [`docs/plugins/ui.md`](../../plugins/ui.md), which become the reference for plugin authors.
3. Wrist menu, with the wrist and summoned presentations and their one-handed summon bindings, rendering broker and catalog data. The redesign in #20 builds on this.
4. Titlebars and window decorations, as attached presentations that share their panels' surface shapes. Resize frames and curvature handles become toolkit kinds, which #8 and #48 build on.
5. Errors overlay and empty-desktop hint, as toolkit panels. The errors overlay gains dismissal, history, deduplication, and its fallback for a failed toolkit.
6. Virtual keyboard, with non-focusing keys that act on press and repeat. If the migration shows that the layout engine adds nothing for the keyboard, it keeps its own surface and uses only the interactor model. Its key legends stop depending on the compositor seat as part of #63.
7. Plugin manager, together with the redesign in #43, from the slice above. Its reconciler, grid layout, text wrapping, line clipping, and polling are deleted rather than ported.

Each migration replaces the consumer's VR tests with tests that address nodes by id, and updates the consumer's README and any guide that describes it. The `@testing/vr-ui` helpers move from panel, control, and item ids to node ids. `aim` takes an interactor and a node id, and `poke`, `clickNode`, `tab`, `arrow`, `activateFocused`, and `dismiss` are added, with hand-interaction poses in the fake XR session for `poke`. The earlier toolkit's test that asserts no `setScissor` call is replaced by an offscreen pixel test of the clip.

## Documentation changes

When the toolkit merges, the guarantees that replacement providers and consumers rely on move into contract documentation beside the new contracts, in the way [`panels-and-ui.md`](../../../lua/lunette-contracts/panels-and-ui.md) records the earlier toolkit's guarantees. The plugin author guide in [`docs/plugins/ui.md`](../../plugins/ui.md) is rewritten around components, kinds, visuals, and outlets, with a checked minimal example. The host and the standard components each get a README beside their implementation. The user guide for the runtime manager documents protected panels and the recovery path.

## Done when

Every in-tree panel is built from toolkit components with no absolute control rectangles and no consumer-drawn text: the backdrop controls, the plugin manager, the wrist menu, titlebars, decorations, the errors overlay, the hint, and the UI example. Each has VR tests that address nodes by id. Controller rays and tracked hands operate every panel in the headset, the mouse ray interactor operates every panel under fake input, and every action is reachable without a physical keyboard or mouse. Mouse operation in a live session depends on host mouse capture from #49 and is verified there. The spike results are recorded in the design documents, and the migration record is deleted.

## Issue updates

These issues need their text updated to match the design:

- #60 keeps Response and Motion as dropdowns. They become sliders with detents at the same levels, with None at 0.
- #64 names layout in #54 as a motivation. Layout is native, and the Lua hot paths are the ones listed in [Prerequisites](#prerequisites).
- #48 assumes UI panels may use cylinder layers. UI panels never use layers, and window-layer curvature is decided separately.
- #49 should note that the toolkit fixes the mouse as a head-through-cursor ray and needs source-loss cancellation and the context action.
- #28 and #30 should note that their UI-facing items are repeated after the migration.
- #43 should state its acceptance as built from toolkit components, and list the form-editor widgets.
- #54 lists table rows, which are in the widget set as table rows with aligned columns.

## Related issues

- #54 tracks the rebuild.
- #43 redesigns the plugin manager on the toolkit.
- #20 redesigns the wrist interface on the toolkit.
- #45 defines the catalog, creation-request, and active-instance contracts that the wrist menu and launcher render.
- #47 redesigns object manipulation, which shares the gesture precedence between node capture, scrolling, and panel grab.
- #8 resizes a window's contents, which uses the same handles as panel resizing.
- #48 adds persisted curvature to every panel.
- #49 adds mouse and keyboard interaction for the workspace.
- #60 adds backdrop presets and changes the backdrop controls panel.
- #59 adds per-plugin source reloads. A reload of the components plugin replaces nodes of its kinds with placeholders until it registers again, and a consumer's reload remounts only its own trees.
- #62 adds host window capture, whose window selector is a toolkit consumer.
- #63 adds Windows support, which needs text entry and key legends that do not depend on a Wayland seat.
- #6 adds navigation keys to the virtual keyboard.
- #21 and #29 verify restart and reload behaviour, which must cover the toolkit shader, the glyph atlas, and the per-panel layout trees.
- #28 and #30 repeat their UI-facing headset checks after the rebuild.
- #42 revises the VR interface text after the rebuild, following the copy rules in [Accessibility](accessibility.md#localisation).
- #64 enables Luau optimisation and native code generation.
