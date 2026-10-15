# UI

UI provides flat VR controls and titlebars. [Toolkit](toolkit/README.md) creates panels, controls, and titlebars with focus and pointer integration. Consumers draw in a supplied scene pass; larger interfaces remain Wayland clients.

The [UI contract](../../lunette-contracts/ui.luau) defines services; [panel and UI guarantees](../../lunette-contracts/panels-and-ui.md) define clipping and draw-order limits. [Focus](../../lunette-contracts/focus.luau) and [surfaces](../../lunette-contracts/surfaces.luau) define input integration. [UI authoring](../../../docs/plugins/ui.md) records composition examples.

[Titlebar configuration](titlebar-configuration.luau), `@lunette-plugins/ui/titlebar-configuration`, projects editable settings into detached, sparse values during caller-side configuration. It acquires no resources, looks up no services, and draws nothing. The neutral [titlebar-style schema](../../lunette-contracts/schemas/titlebar-style.luau) validates stable values; the runtime theme provider owns fonts. [Shipped plugins](../README.md) defines public imports.
