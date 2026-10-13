# UI

The UI provider supplies flat VR panels, controls, and shared titlebars. Consumers own the draw pass and draw their own panels.

| Provides | Requires |
| --- | --- |
| [`lunette/ui`](../../lunette-contracts/ui.luau) | `lunette/focus`, `lunette/surfaces`, `lunette/theme`, `lunette/frame` |

The surfaces service receives panel offers from their owners; the theme service supplies inherited appearance and fonts. [Options](config.luau) · [Contract-only example](../../../docs/guide/ui.md) · [Rendering behavior](docs/rendering.md) · [UI API](../../lunette-contracts/panels-and-ui.md#ui-geometry)
