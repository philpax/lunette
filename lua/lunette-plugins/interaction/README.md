# Interaction

Interaction separates target offers, pointer policy, and grab-end notifications. [Surfaces](surfaces/README.md) collects offers for picking. [Pointers](pointers/README.md) turns samples into hits, input events, and spatial grabs. [Drops](drops/README.md) publishes grab-end notifications. Drawing alone does not make a surface targetable.

The [surfaces](../../lunette-contracts/surfaces.luau), [interaction](../../lunette-contracts/interaction.luau), and [drops](../../lunette-contracts/drops.luau) contracts define services. The [input protocol](../../lunette-contracts/docs/input.md) defines surface delivery and cancellation; [contract vocabulary](../../lunette-contracts/vocabulary.luau) defines shared surface and tuning values.

[Picking](picking.luau), `@lunette-plugins/interaction/picking`, provides picking and scroll arithmetic for configured pointer drive hooks. The caller supplies surfaces, ray values, reach, frame time, and tuning. Picking checks live surfaces through supplied raycast methods without registering offers or delivering input. It acquires no resources and publishes no service. [Shipped plugins](../README.md) defines public imports.
