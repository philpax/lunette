# Arc layout

Registers a named layout that places panels around a vertical circle facing its centre. It preserves caller order and uses panel widths for spacing. If the requested gaps exceed the span, gaps shrink uniformly and panels may overlap.

By default on Windows, each arrangement centres the arc on the current head position and horizontal facing direction. `anchor = 'origin'` uses the configured playspace centre. The arc also uses that centre when head tracking is unavailable.

The [desktop consumer](../arrange/README.md) selects the layout name separately; changing the registered name does not change that selection.

The public [geometry extension](geometry.luau) computes angles and poses for custom layouts without registering this plugin or acquiring panels.

[Options](config.luau) · [Layout examples](../../../../examples/layout/)
