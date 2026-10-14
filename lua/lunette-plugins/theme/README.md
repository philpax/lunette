# Theme

Theme separates active appearance, named choices, presets, and runtime selection. [Resolver](resolver/README.md) resolves appearance and supplies fonts. [Catalog](catalog/README.md) stores complete themes without selecting appearance. [Standard](standard/README.md) registers Dark and Light; [Arcade](arcade/README.md) registers Arcade with its bundled font. [Selector](selector/README.md) applies a catalog choice and registers Appearance actions.

The [theme](../../lunette-contracts/theme.luau) and [themes](../../lunette-contracts/themes.luau) contracts define services. [Panel and UI guarantees](../../lunette-contracts/panels-and-ui.md) define resolved appearance. The neutral [theme schema](../../lunette-contracts/schemas/theme.luau) validates stable values without loading fonts or selecting a provider.

- [Configuration](configuration.luau), `@lunette-plugins/theme/configuration`, validates editable author settings and projects stable theme and font values.
- [Base](base.luau), `@lunette-plugins/theme/base`, supplies the square fallback theme when no selection is live.

These caller-side configuration libraries acquire no resources, load no fonts, look up no services, register no catalog entries, and select no appearance. Runtime font creation and selection remain with the resolver and selector. [Shipped plugins](../README.md) defines public imports.
