# Theme catalog

The catalog stores owner-scoped named, complete themes. It does not select the active appearance: the desktop selector reads the catalog and applies its choice through the separate [runtime theme provider](../theme/README.md).

The shipped presets are [Dark and Light](../theme/standard/README.md) and [Arcade](../theme/arcade/README.md). Plugins register choices through the [`lunette/themes` contract](../../lunette-contracts/themes.luau); each registration follows its owner's lifetime.

[Shipped connections](../../../docs/dev/standard-plugins.md#contracts-and-providers)
