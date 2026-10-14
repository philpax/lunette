# UI

Creates flat VR panels, controls, and titlebars. Consumers draw their panels in a supplied scene pass; larger interfaces remain Wayland clients.

Rounded panels use a conservative rectangular content clip. Custom draw hooks must enforce `visual.clip` themselves. Intersecting or nearly coincident panels can show draw-order artefacts.

[Options](config.luau) · [Examples](../../../../docs/plugins/ui.md) · [UI contract](../../../lunette-contracts/panels-and-ui.md)
