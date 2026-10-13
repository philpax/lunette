# Standard plugins

The [desktop entry list](../../lua/lunette-desktop/init.luau) owns shipped composition and startup order. [Configuration workflows](../guide/desktop-configuration.md) and READMEs beside [the plugins](../../lua/lunette-plugins/) own use and settings. The desktop root composes plugins; it contains no native mechanism or service implementation.

## Contracts and providers

[Neutral contracts](../../lua/lunette-contracts/README.md) keep consumers independent of implementations. Providers expose capabilities; desktop consumers observe the scene and apply policy. Stable entry ids identify the same plugin in settings, patches, diagnostics, and runtime inspection.

Optional children isolate dependencies. A missing service removes the feature that needs it rather than unrelated behavior. Changing a provider must not require copying the desktop consumer that measures or applies its result.

## Default configuration

The shipped desktop opens no applications. Development-only launch behavior belongs in `dev/`, not installed roots. The desktop protects its manager and VR recovery controls from managed runtime removal; direct raw-runtime mutation bypasses that protection.

## Placement

Rules, persistence, adoption, and layout application remain independently replaceable. Rule sources apply in ascending [precedence](../../lua/lunette-contracts/vocabulary.luau): configured rules, saved arrangements, then `lunette.pose`. A source must register before `desktop/adoption` resolves the first window.

The adoption consumer owns both recording dropped poses and registering the source that reads them. Splitting these across a consumer and replaceable provider would lose hand-placed poses when the provider changes. Persistence owns disk storage; arrangement owns layout application.

## Pacing and scale

Providers select rates and scales; desktop consumers observe and apply them and restore changes on unload. [Native pacing](rendering.md#frame-pacing-and-scene-skipping) and [output configuration](compositor.md#outputs) remain independent mechanisms.
