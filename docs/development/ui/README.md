# UI toolkit design

The UI toolkit builds retained, in-scene interfaces through public plugin contracts. The host owns panels, nodes, layout synchronisation, input routing, focus, overlays, motion, drawing, and inspection. Native layout and shaping provide text and container geometry; Lua kinds, visuals, and authoring libraries provide policy.

The [host guide](../../../lua/lunette-plugins/ui/host/README.md), [authoring library](../../../lua/lunette-plugins/ui/react/README.md), and [standard kinds guide](../../../lua/lunette-plugins/ui/standard/README.md) own plugin workflows. The [host contract](../../../lua/lunette-contracts/ui-host.luau), [theme contract](../../../lua/lunette-contracts/theme.luau), and [generated native declarations](../../../lua/lunette/init.luau) own signatures and supported fields. Development documents record constraints and integration hazards rather than a second API reference.

## Reading order

1. [Requirements](requirements.md): session constraints, current boundaries, and deferred work.
2. [Architecture](architecture.md): ownership, native and Lua responsibilities, scheduling, errors, and recovery.
3. [Spatial model](spatial-model.md): panel coordinates, curvature, depth, hit geometry, and clipping.
4. [Authoring](authoring.md): component identity, scheduling, effects, stores, and reload.
5. [Extension](extension.md): registration, overrides, outlets, replacement providers, compatibility, and trust.
6. [Layout and text](layout-and-text.md): native layout, shaping, glyph resources, and editing limits.
7. [Rendering](rendering.md): scene depth, drawing boundaries, opacity, and cost.
8. [Input](input.md): ray and touch routing, capture, traversal, and deferred interaction requirements.
9. [Presentations](presentations.md): panel placement, overlays, dialogs, and saved poses.
10. [Motion and feedback](motion-and-feedback.md): retained response and reduced-motion behavior.
11. [Theming](theming.md): physical units, readability, contrast, and depth rationale.
12. [Accessibility](accessibility.md): settings, semantics, and complete VR workflows.
13. [Testing](testing.md): inspection boundaries and verification constraints.
14. [Research](research.md): source guidance and alternatives behind the constraints.

## Terms

- A panel is a host-owned scene interface with a pose, size, curve, surface, and root mount point.
- A presentation is one of the host's closed panel placement policies. A consumer can also pose a panel explicitly.
- A component is a function that receives props and returns elements through an authoring library.
- An element describes a kind, props, children, and identity. The framework expands its own constructs before submitting elements.
- A node is the retained host object with layout and transient state.
- A kind supplies a node's layout, behavior, semantics, and visual names. A composite kind expands into other elements.
- A visual records a node's appearance. A custom volume instead draws each frame under a separate bounds contract.
- An outlet is a typed contribution point with a separate mount for each contribution at each placement.
- A portal creates an overlay panel associated with its opener.
- Default appearance selects base registrations, visuals, and theme while retaining accessibility settings.
- A token is a named theme value shared by kinds and consumers.

Gesture claims, grab spheres, proximity selection, maintained arrangements, arbitrary surface roots, and public presentation registration are not implied by these terms. Deferred requirements are linked below.

## Decisions in brief

- Function components preserve ordinary Luau control flow. Retained nodes keep hover, press, focus, and scroll state separate from component renders. [Authoring](authoring.md#comparison-with-other-models) records the alternatives.
- The host keeps one tree, input route, draw order, and focus state per panel. Kinds, visuals, and authoring frameworks extend it through the public boundary. [Extension](extension.md) records ownership and recovery constraints.
- Layout and shaping remain native because their correctness tail exceeds a small widget implementation. Host kinds expose container styles and native text, not the native tree's scripted callback mechanism.
- Panels draw geometry directly in the scene to preserve stereo depth. Luau packs instances for the host shaders; there is no native per-node draw-buffer or two-pass group-fade guarantee.
- Sizes use metres because touch is physical. Distant readability still needs angular evaluation and headset testing. The host does not automatically scale every presentation for distance.
- Overlays are separate panels so they can extend beyond an opener's clip. A curved opener produces a flat tangent overlay, not a concentric one.
- Every session action requires a complete VR path without a physical keyboard or mouse. Shared gesture claims, grab spheres, and manipulation remain deferred in [#69](https://github.com/philpax/lunette/issues/69), pick hooks and proximity queries in [#70](https://github.com/philpax/lunette/issues/70), and maintained arrangements in [#71](https://github.com/philpax/lunette/issues/71).
- In-session interfaces use the plugin and owner model rather than an embedded external UI engine whose elements sit outside that model.
