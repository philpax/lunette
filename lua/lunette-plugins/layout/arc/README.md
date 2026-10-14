# Arc layout

Registers a named layout that places panels around a vertical circle facing its centre. It preserves caller order and uses panel widths for spacing. If the requested gaps exceed the span, gaps shrink uniformly and panels may overlap.

The [desktop consumer](../arrange/README.md) selects the layout name separately; changing the registered name does not change that selection.

The public [geometry extension](geometry.luau) computes angles and poses for custom layouts without registering this plugin or acquiring panels.

[Options](config.luau) · [Layout examples](../../../../examples/layout/)
