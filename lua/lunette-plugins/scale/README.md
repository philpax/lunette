# Scale

Scale separates recommendations from output changes. [Service](service/README.md) recommends scale from panel distance with hysteresis to limit toolkit relayouts. [Output controller](output-controller/README.md) measures the nearest shown window panel and applies recommendations. Unloading restores original values only where no other plugin changes them in the meantime.

The [scale contract](../../lunette-contracts/scale.luau) defines recommendations; the controller uses the [panels](../../lunette-contracts/panels.luau) and [frame](../../lunette-contracts/frame.luau) contracts. [Native output configuration](../../../docs/development/native/compositor.md#outputs) defines the mechanism. [Shipped plugins](../README.md) defines public imports.
