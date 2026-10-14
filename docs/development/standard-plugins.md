# Standard plugins

The [desktop entry list](../../lua/lunette-desktop/init.luau) owns shipped composition and startup order. [Configuration workflows](../users/desktop-configuration.md) and the [plugin guides](../../lua/lunette-plugins/README.md) own use and settings. The desktop root composes plugins; it contains no native mechanism or service implementation.

## Module ownership

The shipped tree has 18 responsibility categories and 46 independent plugin leaves. A category groups related plugins and libraries; it has no activation entry. A leaf publishes its entry and configuration schema where present. Other production modules belong under its `private/` directory unless the plugin guide documents a supported extension. Same-category imports follow the same public boundary as imports across categories.

Neutral [contract schemas](../../lua/lunette-contracts/schemas/README.md) validate shared values without importing providers. Category libraries provide reusable mechanisms or pure author configuration without runtime activation. [Contributor rules](../../CONTRIBUTING.md#lua-conventions) apply to all callers. The [dependency check](../../crates/lunette/tests/plugin_dependencies.rs) guards resolved production imports across shipped modules, examples, and dev plugins; runtime suites exercise tests and installed roots.

Entry ids, settings keys, and contract ids remain independent of source paths. The [public import migration](../../lua/lunette-plugins/README.md) records removed paths; no forwarding aliases preserve them. Root aliases, composition order, saved formats, and plugin lifecycle boundaries remain unchanged.

## Contracts and providers

[Neutral contracts](../../lua/lunette-contracts/README.md) keep consumers independent of implementations. Providers expose capabilities; desktop consumers observe the scene and apply policy. Stable entry ids identify the same plugin in settings, patches, diagnostics, and runtime inspection.

Optional children isolate dependencies. A missing service removes the feature that needs it rather than unrelated behavior. Changing a provider must not require copying the desktop consumer that measures or applies its result.

## Default configuration

The shipped desktop opens no applications. Development-only launch behavior belongs in `dev/`, not installed roots. The desktop protects its manager and VR recovery controls from managed runtime removal; direct raw-runtime mutation bypasses that protection.

## Placement

Rules, persistence, adoption, and layout application remain independently replaceable. Rule sources apply in ascending [precedence](../../lua/lunette-contracts/vocabulary.luau): configured rules, saved arrangements, then `lunette.pose`. A source must register before `desktop/adoption` resolves the first window.

The adoption consumer owns both recording dropped poses and registering the source that reads them. Splitting these across a consumer and replaceable provider would lose hand-placed poses when the provider changes. Persistence owns disk storage; arrangement owns layout application.

## Pacing and scale

Providers select rates and scales; desktop consumers observe and apply them and restore changes on unload. [Native pacing](native/rendering.md#frame-pacing-and-scene-skipping) and [output configuration](native/compositor.md#outputs) remain independent mechanisms.
