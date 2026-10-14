# Theme

Theme separates active appearance, named choices, preset registration, and runtime selection.

## Plugin leaves

- [Resolver](resolver/README.md) resolves appearance and supplies fonts.
- [Catalog](catalog/README.md) stores complete named themes without selecting active appearance.
- [Standard](standard/README.md) registers Dark and Light.
- [Arcade](arcade/README.md) registers Arcade with its bundled font.
- [Selector](selector/README.md) applies a catalog choice and registers Appearance actions.

The [theme](../../lunette-contracts/theme.luau) and [themes](../../lunette-contracts/themes.luau) contracts define service access. [Panel and UI guarantees](../../lunette-contracts/panels-and-ui.md) define resolved appearance. The neutral [theme schema](../../lunette-contracts/schemas/theme.luau) validates stable values without loading fonts or selecting a provider.

## Public libraries

- [Configuration](configuration.luau), `@lunette-plugins/theme/configuration`, validates editable author settings and projects them into stable theme and font values.
- [Base](base.luau), `@lunette-plugins/theme/base`, supplies the square fallback theme used when no selection is live.

These libraries run during caller-side configuration and acquire no resources. They do not load fonts, look up services, register catalog entries, or select appearance. Runtime font creation and selection remain with the resolver and selector leaves.

[Shipped plugins and public imports](../README.md)
