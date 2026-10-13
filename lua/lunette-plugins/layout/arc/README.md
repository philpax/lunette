# Arc layout

The arc layout contributor registers a named layout that places panels around a vertical circle and turns each panel toward its centre.

## Entry

- Module: `@lunette-plugins/layout/arc` (`lua/lunette-plugins/layout/arc/init.luau`).
- Desktop entry id: `layout/arc`.
- Contract: contributes a layout to `lunette/layouts`; it does not provide a separate capability.

## Dependencies

The entry requires `lunette/layouts`. The [layouts provider](../../layouts/README.md) must be enabled for registration and application.

## Configuration and extension

The schema in [config.luau](config.luau) defines the registered `name` and geometry `tuning`. The default contributor entry is listed in [standard plugins](../../../../docs/dev/standard-plugins.md#default-configuration). The default desktop arrangement consumer selects the name `arc`; changing either entry's configuration does not alter the other entry's settings. [Arc geometry](docs/arc-geometry.md) specifies spacing and pose calculation.

## Tests

[Geometry tests](tests/geometry.luau) cover centring, spacing, span filling, and configured centres. [Provider tests](tests/provider.luau) cover registration.