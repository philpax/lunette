# UI

UI provides flat VR controls and titlebars. Consumers draw their panels in a supplied scene pass; larger interfaces remain Wayland clients.

## Plugin leaf

- [Toolkit](toolkit/README.md) creates panels, controls, and titlebars, with focus and pointer integration.

The [UI contract](../../lunette-contracts/ui.luau) defines service access. [Panel and UI guarantees](../../lunette-contracts/panels-and-ui.md) define clipping and draw-order limits. The [focus](../../lunette-contracts/focus.luau) and [surfaces](../../lunette-contracts/surfaces.luau) contracts define input integration. [UI authoring](../../../docs/plugins/ui.md) records composition examples.

## Public library

[Titlebar configuration](titlebar-configuration.luau), `@lunette-plugins/ui/titlebar-configuration`, projects editable settings into detached, sparse titlebar values. It runs during caller-side configuration, acquires no resources, and performs no service lookup or drawing. The neutral [titlebar-style schema](../../lunette-contracts/schemas/titlebar-style.luau) owns stable value validation. Font resources remain with the runtime theme provider.

[Shipped plugins and public imports](../README.md)
