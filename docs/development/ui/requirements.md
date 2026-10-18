# Requirements

## Capabilities

The toolkit provides retained elements, native container layout and text shaping, owner-scoped panels and contributions, kind and visual overrides, ray and fingertip input, focus traversal, overlays, and node inspection. The [host guide](../../../lua/lunette-plugins/ui/host/README.md), [authoring library](../../../lua/lunette-plugins/ui/react/README.md), and [standard kinds guide](../../../lua/lunette-plugins/ui/standard/README.md) own supported workflows. Contract declarations and checked registrations own the widget and API inventory.

These capabilities have limits. Commits run in the scene update, effects run before layout, presentations form a closed set, and native scripted layout is not a host registration feature. Rendering uses fixed curved meshes and Lua-packed data, and new glyphs can remain absent while workers generate them or the atlas is full. The relevant development topics state those boundaries rather than treating planned guarantees as complete.

## Session requirements

Every session action remains reachable through VR controls without a physical keyboard, mouse, or flatscreen interface. A two-handed gesture cannot be the sole path to an action. Traversal, text entry, panel management, and recovery need complete workflows rather than an API that merely permits a future consumer to build them.

Shared gesture claims, grab-sphere interactors, general capture transfer beyond explicit overlay handoff, and manipulation remain deferred in [#69](https://github.com/philpax/lunette/issues/69). Pick hooks and proximity assistance remain deferred in [#70](https://github.com/philpax/lunette/issues/70). Maintained arrangements of toolkit panels remain deferred in [#71](https://github.com/philpax/lunette/issues/71). The host's current saved world-panel poses do not satisfy maintained arrangement requirements.

Kinds use semantic events instead of independently polling physical devices. Controller traversal supplies a channel separate from pointing. Consumers adapt their own placement to available input; the host does not automatically move a tree between registered wrist and summoned presentations or negotiate density for it.

Shipped plugins use only public contracts. Constructors, kinds, visuals, and contributions follow owner lifetime, and modules remain safe to require twice. Internal host helpers are not substitutes for missing public mechanisms.

Default appearance selects base kinds, visuals, and theme while preserving accessibility settings. The controller chord and the independent recovery plugin keep a VR path to disabling a faulty extension. Replacing the host itself needs the recovery path outside the toolkit. [Architecture](architecture.md#protection-and-recovery) states that boundary.

Accessibility includes readable text, contrast, visible reasons for disabled actions, semantics, one-handed use, and alternatives to sound and haptics. Implemented settings and inspection do not prove every consumer meets those requirements. [Accessibility](accessibility.md) distinguishes current support from remaining workflow work.

## Out of scope

- Composition layers for toolkit panels, because a flat layer loses per-element depth and does not share scene depth with rays. [Rendering](rendering.md#composition-layers) records the trade-off.
- An external UI engine rendered to a texture, because its elements sit outside the plugin and owner model.
- A visual layout editor or a separate markup language. Components use Luau.
- Host-system permission prompts, such as desktop screen-capture portals, until an in-session consumer provides an appropriate workflow.

Bidirectional editing, input-method composition, and complete multi-line editing are not supported. Native shaping can display text that the field cannot correctly edit. This remains a gap for users whose scripts require those paths, not an exception to the session's VR workflow requirement. [Layout and text](layout-and-text.md#open-questions) records the text limitations.
