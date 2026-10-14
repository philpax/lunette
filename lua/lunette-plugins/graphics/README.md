# Graphics

Graphics provides reusable drawing mechanisms. The category has no plugin leaves, activation entry, or runtime services.

## Public libraries

- [Pass state](pass-state.luau), `@lunette-plugins/graphics/pass-state`, restores the supplied pass's state and transform after a drawing callback, including when the callback raises. It then raises the original failure.
- [Client pixels](client-pixels.luau), `@lunette-plugins/graphics/client-pixels`, creates opaque or alpha client-pixel shaders on first use. The supplied plugin context releases them, and selection returns no shader after the context or caller's live predicate ends. Drawing uses premultiplied alpha blending.
- [Rounded geometry](rounded-geometry.luau), `@lunette-plugins/graphics/rounded-geometry`, computes silhouettes, clipping, containment, and outline geometry from supplied values. It acquires no graphics resources.
- [Rounded drawing](rounded-drawing.luau), `@lunette-plugins/graphics/rounded-drawing`, submits rounded faces and borders to the supplied pass. Each cache belongs to its drawing owner; that owner registers `clear` with its resource cleanup. Cache eviction releases replaced meshes.

Drawing calls run in the caller's draw callback with a live supplied pass. Libraries do not acquire a pass, schedule drawing, or select a service provider. The [ownership contract](../../lunette-plugin/ownership.md) defines context cleanup. [Panel and UI guarantees](../../lunette-contracts/panels-and-ui.md) define clipping and presentation limits for consumers.

[Shipped plugins and public imports](../README.md)
