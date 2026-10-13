# Panels

The panels provider creates and draws window and monitor panels. It owns their geometry, visibility, appearance, and draw order; the shipped desktop's render consumer updates and draws them.

| Provides | Requires |
| --- | --- |
| [`lunette/panels`](../../lunette-contracts/panels.luau) | [`lunette/theme`](../../lunette-contracts/theme.luau) |

A separate desktop child offers visible panels as pointer surfaces through [`lunette/surfaces`](../../lunette-contracts/surfaces.luau). Without that child, panels still draw but cannot be pointed at.

[Options](config.luau) · [Panel API](../../../lua/lunette-contracts/panels-and-ui.md#panels) · [Rendering behavior](docs/rendering.md) · [Shared rendering guarantees](../../../docs/dev/rendering.md)
