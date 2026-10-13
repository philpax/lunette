# Runtime theme

The provider resolves appearance selections and supplies font faces to consumers. It provides [`lunette/theme`](../../lunette-contracts/theme.luau); the separate [theme catalog](../themes/README.md) stores named choices but does not select one.

An override and its font resolve before registration, so invalid data or a font-load failure leaves active state unchanged. Font faces are cached by descriptor because recorded passes can retain them. Shutdown clears the cache and lets LÖVR release faces through garbage collection.

[Shared rounded geometry](docs/rounded-geometry.md) · [Runtime theme API](../../lunette-contracts/panels-and-ui.md#themes) · [Shipped connections](../../../docs/dev/standard-plugins.md#contracts-and-providers)
