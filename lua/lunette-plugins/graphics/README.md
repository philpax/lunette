# Graphics

Graphics provides caller-owned drawing mechanisms without plugin leaves, an activation entry, or runtime services. The caller schedules the draws and owns their resources.

- [Pass state](pass-state.luau), `@lunette-plugins/graphics/pass-state`, restores pass state and transform after a callback, including on failure, then raises the original failure.
- [Client pixels](client-pixels.luau), `@lunette-plugins/graphics/client-pixels`, creates opaque or alpha client-pixel shaders on first use. The supplied context releases them; selection returns no shader after the context or caller's live predicate ends. Drawing uses premultiplied alpha blending.
- [Curved surface](curved-surface.luau), `@lunette-plugins/graphics/curved-surface`, maps rays, panel coordinates, surface points, and frames on a flat or cylindrical surface, with the half-turn clamp both panel families share. `normalizeAxis` wraps an axis into `(-pi, pi]`, and `bendOf` and `panelOf` convert between panel coordinates and the bend frame, so a hit test and a mesh traverse the same cylinder. Rendering stays with each family: the native service builds CPU meshes and the toolkit host draws with its shader.
- [Rounded geometry](rounded-geometry.luau), `@lunette-plugins/graphics/rounded-geometry`, computes silhouettes, clipping, containment, and outlines from supplied values without acquiring graphics resources.
- [Rounded drawing](rounded-drawing.luau), `@lunette-plugins/graphics/rounded-drawing`, submits rounded faces and borders to the supplied pass. Each drawing owner registers its cache's `clear` with resource cleanup; eviction releases replaced meshes.
- [SteamVR quad](steamvr-quad.luau), `@lunette-plugins/graphics/steamvr-quad`, prepares a transparent overlay and its draw pass from a world pose and dimensions. The caller releases the cached layer and submits the pass and layer in its draw callback.

The [ownership contract](../../lunette-plugin/ownership.md) defines context cleanup. [Panel and UI guarantees](../../lunette-contracts/panels-and-ui.md) define clipping and presentation limits. [Shipped plugins](../README.md) defines public imports.
