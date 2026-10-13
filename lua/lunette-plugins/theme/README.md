# Runtime theme

The runtime theme provider resolves the effective theme used by built-in consumers and supplies font faces. It provides `lunette/theme` through `@lunette-plugins/theme`, as desktop entry `theme`.

## Dependencies

The provider has no required services. Panels, keyboard, UI, laser, and desktop consumers may require the theme service independently. The `themes` catalog and the selector entry `desktop/theme` are separate plugins; the theme provider does not select a named preset.

## Configuration and extension

The provider has no configuration fields. Configured definitions still expose `.define(config)`, with the accepted shape defined by the provider's module. Plugins extend runtime appearance through owner-scoped `select` registrations and observe changes through `onChanged`, as defined by the [`lunette/theme` contract](../../lunette-contracts/theme.luau). Theme types and font specifications are owned by that contract.

## Rendering detail

[Runtime themes](docs/runtime-themes.md) records provider implementation policy. [Shared rounded geometry](docs/rounded-geometry.md) specifies the perimeter used by panels, UI, and keyboard faces. [Runtime themes in the Lua API](../../../docs/dev/lua-api.md#runtime-themes) specifies selection and change guarantees. [The shipped plugin catalogue](../../../docs/dev/standard-plugins.md#contracts-and-providers) describes the shipped catalog and selector.

## Tests

No dedicated test directory exists for this provider. The catalog integration suite in [`themes/tests/catalog.luau`](../themes/tests/catalog.luau) covers shipped registrations and disable behavior. Consumer suites exercise theme resolution and updates in their respective plugin roots.

## Decisions

The provider keeps selection resolution separate from the named catalog. This lets a configuration disable or replace catalog entries without changing consumers that read the runtime theme. [Runtime theme implementation](docs/runtime-themes.md#decisions) records the provider's registration and font-cache decisions.

## Known gaps

Geometry recorders do not rasterise edges, alpha, depth, or fonts. The shared rendering specification records the scope of offscreen graphics checks and headset acceptance limits.
