# Interaction

Interaction separates target offers, pointer policy, and grab-end notifications. Drawing alone does not make a surface targetable.

## Plugin leaves

- [Surfaces](surfaces/README.md) collects offers for pointer picking.
- [Pointers](pointers/README.md) turns samples into surface hits, input events, and spatial grabs.
- [Drops](drops/README.md) publishes notifications when a grab ends.

The [surfaces](../../lunette-contracts/surfaces.luau), [interaction](../../lunette-contracts/interaction.luau), and [drops](../../lunette-contracts/drops.luau) contracts define service access. The [input protocol](../../lunette-contracts/docs/input.md) defines surface delivery and cancellation. Shared surface and tuning values belong to [contract vocabulary](../../lunette-contracts/vocabulary.luau).

## Public library

[Picking](picking.luau), `@lunette-plugins/interaction/picking`, provides picking and scroll arithmetic for configured pointer drive hooks. The caller supplies surfaces, ray values, reach, frame time, and tuning. Picking checks live surfaces through their supplied raycast methods; it does not register offers or deliver input. The library acquires no resources and publishes no service.

[Shipped plugins and public imports](../README.md)
