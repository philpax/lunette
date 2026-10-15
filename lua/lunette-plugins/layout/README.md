# Layout

Layout separates named callbacks, arrangement policy, and saved panel state. [Catalog](catalog/README.md) stores callbacks without arranging panels. [Arc](arc/README.md) registers a vertical-circle layout in caller order. [Arrange](arrange/README.md) applies the selected layout to windows without poses, preserving saved and dropped poses. [Persistence](persistence/README.md) saves and restores poses, sizes, and tags through `desktop/persistence`.

The [layouts](../../lunette-contracts/layouts.luau) and [arrangement](../../lunette-contracts/arrangement.luau) contracts define registration and persistence. [Panels](../../lunette-contracts/panels.luau), [tags](../../lunette-contracts/tags.luau), and [drops](../../lunette-contracts/drops.luau) supply state and notifications. [Placement precedence](../../../docs/development/standard-plugins.md#placement) defines interaction with rules and adoption.

[Arc geometry](arc/geometry.luau), `@lunette-plugins/layout/arc/geometry`, computes angles and poses from supplied widths and tuning, preserving width order. Returned values, including matrices, belong to the caller. It registers no layout or service and retains no resources. [Shipped plugins](../README.md) defines public imports.
