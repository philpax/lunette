# Panels

Panels separates source-backed panel creation, rendering, titlebars, and monitor selection. A created panel does not draw or receive pointer input without the corresponding consumer.

## Plugin leaves

- [Service](service/README.md) creates window and monitor panels.
- [Renderer](renderer/README.md) updates and draws registered panels, with optional pointer-surface offers.
- [Decorations](decorations/README.md) adds VR grab and close controls without relying on client-drawn titlebars.
- [Monitors](monitors/README.md) mirrors selected host monitors without moving existing mirrors as new ones appear.

The [panels contract](../../lunette-contracts/panels.luau) defines panel access. [Panel and UI guarantees](../../lunette-contracts/panels-and-ui.md) define clipping and rendering limits. The consumers use the [surfaces](../../lunette-contracts/surfaces.luau), [UI](../../lunette-contracts/ui.luau), and [tags](../../lunette-contracts/tags.luau) contracts. [Monitor and titlebar workflows](../../../docs/users/desktop-configuration.md#windows-monitors-and-workspaces) define session controls.

[Shipped plugins and public imports](../README.md)
