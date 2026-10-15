# Migration

The design in the other UI documents replaces the earlier `lunette/ui` toolkit, as tracked in #54. Everything specific to that replacement lives in the migration record, which is deleted when the migration is complete. The other documents describe the toolkit as designed and do not refer to the earlier one.

## The earlier toolkit

The `lunette/ui` contract is [`lua/lunette-contracts/ui.luau`](../../../lua/lunette-contracts/ui.luau), at version 3. Its provider is [`lua/lunette-plugins/ui/toolkit/`](../../../lua/lunette-plugins/ui/toolkit/README.md), about 4,400 lines of Lua across 28 modules.

A panel is a flat quad in the scene. A consumer registers each control with an absolute rectangle in the panel's top-left, y-down logical pixels. The control kinds are `button`, `text-field`, `choice`, `list`, and `region`, which is a caller-drawn control. A panel is a flat list of rectangles ordered by `z` and registration order, with no containers, measurement, or parent and child relationship.

Every control is drawn every frame. Each control builds a fresh visual table and passes it through the drawing functions. Rounded shapes are CPU-clipped meshes with a per-size cache, and text is clipped by computing a conservative rectangle inside the rounded corners. Text is a single line, ellipsised at grapheme boundaries, and drawn with `pass:text` rotated by pi about the x axis to undo the panel's y-down flip. The only native code in the text path is `lunette.textBoundaries`, which returns grapheme boundaries.

Input is entirely Lua. The interaction contract in [`lua/lunette-contracts/vocabulary.luau`](../../../lua/lunette-contracts/vocabulary.luau) models a pointer as a ray with an origin, a direction, an analog trigger, buttons, a grip state, and scroll axes. A surface implements `raycast`. Pointer events are enter, leave, move, press, release, scroll, and cancel. The controller laser and the hand-pointers plugin drive pointers. There is no point interactor for touch, no tracked-hand input, and no mouse cursor in the scene. The panel picks the topmost control whose rectangle contains the hit. Hover and capture are tracked per pointer, and a held control refuses a second pointer. Text fields and regions take keyboard focus on press, and there is no focus traversal between controls.

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

Paths are relative to `lua/lunette-plugins/`.

The plugin manager, `session/plugin-manager/`, is about 2,800 lines of production Lua. It shows an entry list or a dependency graph canvas, a toolbar of view and filter actions, and a sidebar with Inspect, Configure, and Catalog tabs. Inspect is a scrolling block of diagnostic text. Configure is a schema-driven editor with a row list and a value editor. Lifecycle actions are enabled by predicates with no visible reason. Destructive actions have no confirmation. The graph canvas is a region with its own capture state machine, a drag threshold, pan, zoom, and Liang-Barsky clipping of lines. #43 redesigns the manager around progressive disclosure on the new toolkit.

The wrist menu, `menu/wrist-menu/`, attaches a panel to a tracked hand. Closed, it is one button. Open, it is a titlebar and a list of every registered menu action, with grouping, radio selection, and disabled state encoded in labels. It destroys and recreates controls to switch modes. #20 redesigns it with launching, monitor mirrors, pending and failed states, retry, grouping, and search.

The backdrop controls, `environment/backdrop/private/controls/`, expose two toggles faked as choices, an audio source choice, an applications list, response and motion presets standing in for sliders, a diagnostic view choice, and status text drawn through a region. The panel polls every frame while visible.

Titlebars, `ui/toolkit/private/titlebar/`, and window decorations, `panels/decorations/`, add titlebars with close and action buttons to panels. Monitor decorations concatenate status and error text into button labels because there is no status slot.

The errors overlay, `diagnostics/error-display/`, and the empty-desktop hint, `environment/empty-desktop-hint/`, draw world-space text directly. The errors overlay wraps by character columns and cannot be dismissed, scrolled, or browsed.

The virtual keyboard, `input/keyboard/` and `input/keyboard-display/`, has its own drawing, raycast, hover, and capture, and reuses only the titlebar. #6 adds arrow and navigation keys, and they carry over to the toolkit keyboard.

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
- The earlier rendering design clipped rounded panels with CPU-clipped meshes and a conservative rectangle, and rejected stencil and offscreen clipping because they added pass requirements and composition cost for small controls. The toolkit clips in a shader in panel-local space instead, which follows the pose, works at any depth, and adds no pass.

## Prerequisites

Services that the migrated consumers read publish observable stores, so that components update on change rather than by polling. The composition service is the first, because the plugin manager polls it. The backdrop service, the menu broker, the theme service, and the panels service follow as their consumers migrate. The read-only store type lives in the neutral contract vocabulary.

#64 enables Luau optimisation level 2 and native code generation. The toolkit does not depend on it, but its measurements inform how much of the host's per-frame work needs attention.

## Spikes

Each spike answers a question that would change the design if the answer were negative. Spikes are throwaway code on the feature branch. Their results are recorded in the design document the question belongs to, and their code is deleted or rewritten before it merges.

1. Toolkit shader. A LÖVR custom shader draws instanced boxes and glyph quads from per-instance data, with clipping by a panel-local rounded rectangle, elevation, and cylindrical bending. The spike confirms that LÖVR's draw API exposes per-instance buffers to a custom shader without a fork patch, and that the result passes an offscreen pixel test.
2. Draw cost. A synthetic tree of about 300 nodes, the size of the plugin manager, draws every frame in a session. The spike records CPU frame time and draw calls, with and without instance buffer reuse. A cost that does not fit the frame budget changes the batching design before any kind is written.
3. Text. cosmic-text shapes and wraps text, and msdfgen rasterises glyphs by id into an atlas that LÖVR samples. The spike compares the result with LÖVR's own text at small sizes, and compares LÖVR's msdfgen with a Rust distance field crate. A negative result reopens the fork-patch alternative in [Layout and text](layout-and-text.md#glyph-rendering).
4. Layout binding. A `handle!` binding of taffy accepts batched changes and returns flat layout arrays, with native text measurement. The spike measures the cost of a commit that changes one text node in a 300-node tree.
5. Hand tracking. LÖVR's `getSkeleton` drives a poke point and a pinch ray in a headset session. This spike needs a headset and a runtime that supports hand tracking, so it runs on the maintainer's setup. The interactor model can be built against fake XR before it runs.

## Phases

1. Interaction. Sources, interactors, arbitration, the surface point query, semantic events, ray robustness, and the input mode service, in the interaction contracts. The laser and hand-pointer plugins move onto interactors, and window panels keep working through the ray path. Tracked hands and the mouse cursor ray are added here. This phase comes first because the toolkit is its main consumer, and designing it separately would mean designing it twice.
2. Native layout and text. The layout tree handle, the text module, the glyph atlas, and their Rust tests.
3. Host. Panels, presentations, the node tree, the kind and visual registries, the toolkit shader and drawing API, hit testing at elevation, event routing, focus traversal, overlays, and inspection.
4. Authoring library. Elements, components, the hook set, stores, scheduling, error handling, and outlets, with component tests.
5. Standard components. The full kind set listed in [Requirements](requirements.md#capabilities). Each kind has kind tests and an offscreen rendering test of its default visual.
6. Migration of consumers, in the order below.
7. Removal of the `lunette/ui` contract, its provider, and its tests, once no consumer requires it.

A vertical slice runs through phases 2 to 5 before any phase is complete: the backdrop controls built through a minimal host, a few kinds, the authoring library, the shader, and taffy, with controller and mouse input. The backdrop controls are the smallest real consumer that exercises layout, text, a toggle, a slider, a list, a disabled reason, and a store. The slice validates the spikes in context before the remaining kinds are written.

## Migration order

1. Backdrop controls, as the vertical slice.
2. The UI example and its guide, [`docs/plugins/ui.md`](../../plugins/ui.md), which become the reference for plugin authors.
3. Wrist menu, with a wrist presentation, a summoned presentation, and an outlet for menu contributions. The redesign in #20 builds on this.
4. Titlebars and window decorations, as attached presentations that curve with their panels. #48 adds the curvature control and the arrangement format version for persisting curvature.
5. Errors overlay and empty-desktop hint, as toolkit panels. The errors overlay gains dismissal and history.
6. Virtual keyboard, onto the near-touch path. If the migration shows that the layout engine adds nothing for the keyboard, it keeps its own surface and uses only the interactor model.
7. Plugin manager, together with the redesign in #43. Its reconciler, grid layout, text wrapping, line clipping, and polling are deleted rather than ported. The graph canvas becomes a custom drawing kind.

Each migration replaces the consumer's VR tests with tests that address nodes by id, and updates the consumer's README and any guide that describes it. The `@testing/vr-ui` helpers move from panel, control, and item ids to node ids. The earlier toolkit's test that asserts no `setScissor` call is replaced by an offscreen pixel test of the clip.

## Documentation changes

When the toolkit merges, the guarantees that replacement providers and consumers rely on move into contract documentation beside the new contracts, in the way [`panels-and-ui.md`](../../../lua/lunette-contracts/panels-and-ui.md) records the earlier toolkit's guarantees. The plugin author guide in [`docs/plugins/ui.md`](../../plugins/ui.md) is rewritten around components, kinds, visuals, and outlets. The host and the standard components each get a README beside their implementation.

## Done when

Every in-tree panel is built from toolkit components with no absolute control rectangles and no consumer-drawn text: the backdrop controls, the plugin manager, the wrist menu, titlebars, decorations, the errors overlay, the hint, and the UI example. Each has VR tests that address nodes by id. Controller rays, tracked hands, and mouse and keyboard operate every panel, and every action is reachable without a physical keyboard or mouse. The spike results are recorded in the design documents, and the migration record is deleted.

## Related issues

- #54 tracks the rebuild.
- #43 redesigns the plugin manager on the toolkit.
- #20 redesigns the wrist interface on the toolkit.
- #48 adds persisted curvature to every panel.
- #49 adds mouse and keyboard interaction for the workspace.
- #6 adds navigation keys to the virtual keyboard.
- #28 and #30 repeat their UI-facing headset checks after the rebuild.
- #42 revises the VR interface text after the rebuild.
- #64 enables Luau optimisation and native code generation.
