# Surfaces

The surfaces provider collects owner-scoped offers of surfaces that pointers can inspect. The panels child offers visible panels through this service; without it, panels still draw but cannot be pointed at.

Consumers register `list` callbacks through the [`lunette/surfaces` contract](../../lunette-contracts/surfaces.luau). The provider queries them when it builds the current surface list; a callback error or non-table result contributes no surfaces.

[Surface pointer input](../../lunette-contracts/docs/input.md#surface-pointer-delivery) · [Shared input limits](../../../docs/dev/input.md#known-gaps)
