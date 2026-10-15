# Pacing

Pacing separates window-rate recommendations from native changes. [Service](service/README.md) recommends lower rates for hidden windows, exempting recent unthrottled activity and video or game content hints. [Controller](controller/README.md) observes panel visibility, applies rates, and optionally pauses hidden monitor captures. Unloading restores its owned changes.

The [pacing contract](../../lunette-contracts/pacing.luau) defines recommendations; the controller uses the [panels](../../lunette-contracts/panels.luau) and [frame](../../lunette-contracts/frame.luau) contracts. [Native pacing](../../../docs/development/native/rendering.md#frame-pacing-and-scene-skipping) defines the mechanism and scene-skipping limits. [Shipped plugins](../README.md) defines public imports.
