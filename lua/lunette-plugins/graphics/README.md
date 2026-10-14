# Graphics

Graphics provides caller-owned drawing mechanisms without plugin leaves, an activation entry, or runtime services. Calls run in the caller's draw callback with a live supplied pass. The libraries acquire no pass, schedule no drawing, and select no provider.

- [Pass state](pass-state.luau), `@lunette-plugins/graphics/pass-state`, restores pass state and transform after a callback, including on failure, then raises the original failure.
- [Client pixels](client-pixels.luau), `@lunette-plugins/graphics/client-pixels`, creates opaque or alpha client-pixel shaders on first use. The supplied context releases them; selection returns no shader after the context or caller's live predicate ends. Drawing uses premultiplied alpha blending.
- [Rounded geometry](rounded-geometry.luau), `@lunette-plugins/graphics/rounded-geometry`, computes silhouettes, clipping, containment, and outlines from supplied values without acquiring graphics resources.
- [Rounded drawing](rounded-drawing.luau), `@lunette-plugins/graphics/rounded-drawing`, submits rounded faces and borders to the supplied pass. Each drawing owner registers its cache's `clear` with resource cleanup; eviction releases replaced meshes.

The [ownership contract](../../lunette-plugin/ownership.md) defines context cleanup. [Panel and UI guarantees](../../lunette-contracts/panels-and-ui.md) define clipping and presentation limits. [Shipped plugins](../README.md) defines public imports.
