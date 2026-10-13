# Arc layout

The arc contributor registers a layout that orders panels around a vertical circle and turns each panel toward its centre.

| Registers | Requires |
| --- | --- |
| A named layout in `lunette/layouts` | `lunette/layouts` |

[Options](config.luau) · [Layouts broker](../../layouts/README.md) · [Geometry examples](../../../../examples/layout/)

The layout preserves caller order and uses panel widths to set adjacent spacing. It keeps the configured edge gap when panels fit; when the requested gaps exceed the span, it scales them uniformly and panels may overlap. The arc remains centred on angle zero. The shipped desktop consumer selects the name `arc`; changing either entry's configuration does not change the other.