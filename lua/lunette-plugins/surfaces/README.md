# Surfaces

The surfaces provider collects owner-scoped offers of surfaces that pointers can inspect. It provides `lunette/surfaces` through `@lunette-plugins/surfaces`, as desktop entry `surfaces`.

## Dependencies

The provider has no required services. The shipped desktop's panel-offer child requires this service and offers shown panels. If that child cannot run, the panels provider can continue drawing panels without surfaces for pointing.

## Configuration and extension

The provider has no configuration fields. Its config type is defined in [`init.luau`](init.luau). Consumers register named `list` callbacks through the [`lunette/surfaces` contract](../../lunette-contracts/surfaces.luau). The contract owns surface semantics, pointer behavior, and the callback type.

Offer results are queried when the service builds its current list. Each callback runs under protection; a callback that raises or returns a non-table contributes no surfaces. An offer's lifetime follows its registering owner.

## Tests

[`tests/offers.luau`](tests/offers.luau) covers offer registration and querying.

## Known gaps

Multi-seat input is less exercised in toolkits. Bugs around popup grabs and drag-and-drop ownership are expected; [Input](../../../docs/dev/input.md#known-gaps) records this shared limitation.

## References

[Surface pointer input](../../../docs/dev/input.md#surface-pointer-input) specifies the shared pointer and capture guarantees. [Input](../../../docs/dev/input.md) describes the raycasting boundary.
