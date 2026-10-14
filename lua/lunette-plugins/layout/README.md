# Layout

Layout separates named layout callbacks, arrangement policy, and saved panel state. Registration alone does not arrange panels.

## Plugin leaves

- [Catalog](catalog/README.md) stores named layout callbacks.
- [Arc](arc/README.md) registers a layout that places panels around a vertical circle in caller order.
- [Arrange](arrange/README.md) applies a selected layout to windows without poses, leaving saved and dropped poses untouched.
- [Persistence](persistence/README.md) saves and restores panel poses, sizes, and tags through the `desktop/persistence` entry.

The [layouts](../../lunette-contracts/layouts.luau) and [arrangement](../../lunette-contracts/arrangement.luau) contracts define registration and persistence services. [Panels](../../lunette-contracts/panels.luau), [tags](../../lunette-contracts/tags.luau), and [drops](../../lunette-contracts/drops.luau) supply shared state and notifications. [Placement precedence](../../../docs/development/standard-plugins.md#placement) defines interaction with window rules and adoption.

## Public extension

[Arc geometry](arc/geometry.luau), `@lunette-plugins/layout/arc/geometry`, computes angles and poses from caller-supplied widths and tuning. It preserves width order, returns caller-owned values, and registers no layout or service. The caller owns any returned matrices; the extension retains no resources.

[Shipped plugins and public imports](../README.md)
