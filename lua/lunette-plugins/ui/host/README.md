# UI host

Provides `lunette/ui-host`: owner-scoped panels, retained element trees, native layout, pointer and fingertip routing, focus traversal, overlays, motion, drawing, and inspection. The [contract](../../../lunette-contracts/ui-host.luau) owns types, and [UI architecture](../../../../docs/development/ui/architecture.md) records scheduling and integration constraints.

## Panels and ownership

A consumer creates a panel and binds its root mount point, usually through the [React-like library](../react/README.md). Registered kinds supply behavior, named visuals supply appearance, and composites expand into host elements. The [standard kinds](../standard/README.md) are the checked reference for registrations.

Panels and registrations end with their creation owners or the host. A caller can use world, follow, dialog, or attach placement, or pose a panel explicitly. These are closed host policies, not a presentation registry. Ordinary nodes use container styles or native text; a style-sized empty box does not need a separate leaf layout kind. Native descriptor leaves and scripted callbacks remain separate native mechanisms, not host kind-registration options.

A grabbable world panel opens at its saved resting pose when one exists under its name in the host's `placed` saved setting. A panel posed by its caller each frame disables grabbing. Forgetting `placed` in the runtime manager returns panels to their caller-supplied poses. This is pose persistence, not maintained arrangements, which remain deferred in [#71](https://github.com/philpax/lunette/issues/71).

## Contributions and overrides

Outlets bind owner-scoped contributions once per placement, with separate state and effects. They render after the panel root, in the outlet's order or by contributor name. Incompatible versions and conflicting declarations are rejected. Contribution failures are attributed to their owner without stopping the rest of the panel. Attributed outlets frame and clip each contribution and name the contributing plugin.

Kind and visual overrides layer above preceding registrations. Kind changes remake nodes and carry focus, common declared state fields, hover, and capture by the same path and kind name. A drag in progress continues on the replacement node and releases there. Unmatched removed nodes lose capture without activation.

Default appearance selects base kinds, base visuals, and the base theme while retaining accessibility settings. Holding both thumbstick clicks toggles it unless `appearanceChord` is disabled. It belongs to the host activation and resets when the host reloads. Inspection attributes overrides and contributions to their owners.

A caller mutates mode or accent through the theme service it explicitly requires. `host:theme()` remains the read of effective toolkit appearance, including default appearance. The host exposes no duplicate theme mutation or font-registration service. Additional font bytes are loaded through native `lunette.loadLayoutFont(bytes)`; identical loads are idempotent, and faces remain for the Lua state's lifetime rather than an owner scope.

## Input and scheduling

Rays arrive through the shared surfaces and interaction services. Fingertip touch reports the hand as near so its idle ray stands down. Press captures a node; release activates only inside that node without a drag, and cancellation never activates. Kind overrides preserve matching capture. Keys reach the focused node, and unconsumed keys can drive traversal. Focusing a text field by pointing, traversal, or a focus request takes session focus and requests the shared keyboard. Controller traversal works while no ray points at a host panel.

A portal creates a separate overlay anchored to its opener. Outside presses dismiss overlays, and an explicit handoff lets a held ray press release on an overlay item. On a curved opener, the overlay stays flat and tangent at its centre rather than curving concentrically.

Commits run once per frame in the scene update. Changes made during pointing render on the next frame. Mount completion is a boolean query, not a callback, and the authoring library's effect hooks run after submission but before layout. There is no post-layout adapter or same-frame reconciliation after input.

Shared gesture claims, grab-sphere interactors, and manipulation are deferred in [#69](https://github.com/philpax/lunette/issues/69). Pick hooks and proximity queries are deferred in [#70](https://github.com/philpax/lunette/issues/70). Current arbitration does not transfer a gesture between nodes beyond the explicit overlay handoff.

## Drawing limits

Visuals record primitives that the host replays. A volume callback draws every frame with a posed pass and must stay inside its declared bounds; the host hides a partially clipped base rather than clipping custom geometry. The [drawing contract](../../../lunette-contracts/ui-host.luau) owns those requirements.

Luau packs instances, curved boxes use fixed grids, and panels draw in one sequence. There is no public shader include, native per-node draw buffer, adaptive mesh selection, or two-pass group fade. [Rendering](../../../../docs/development/ui/rendering.md) records the depth and transparency limits.

Native shaping and the shared glyph atlas draw text by glyph id. Fields are generated by workers on first demand, so an unready glyph draws nothing. Fonts are also initialised on first use. The atlas has a fixed page limit and clears the least recently drawn eligible page after an idle interval. Its glyphs regenerate on demand. If every page is recent, a new glyph reports pressure and draws nothing. There is no glyph reference count, reserved interface-font share, or cross-state cache. Variable faces use their default instance.

The [shared panel and UI guarantees](../../../lunette-contracts/panels-and-ui.md) state the supported text editing and resource boundary. [Options](config.luau) owns host configuration.
