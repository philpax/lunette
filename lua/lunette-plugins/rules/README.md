# Window rules

The rules provider resolves window properties from ordered, owner-scoped sources. The desktop rule-list consumer is separate and can be replaced independently.

## Entry

- Module: `@lunette-plugins/rules` (`lua/lunette-plugins/rules/init.luau`).
- Desktop entry id: `rules`.
- Capability: `lunette/rules` version 1, declared in [the rules contract](../../../lua/lunette-contracts/rules.luau).
- Shipped consumer: `@lunette-plugins/desktop/rules`, entry id `desktop/rules`.

## Dependencies

The provider requires no plugin capabilities. The shipped consumer requires `lunette/rules`.

## Configuration and extension

The provider schema in [config.luau](config.luau) defines the default source precedence. The provider and consumer connections are listed in [standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers). The desktop consumer schema in [desktop/rules/config.luau](../desktop/rules/config.luau) defines the rule list and its default. Plugins can register additional sources through the rules contract. [Rule resolution](docs/rule-resolution.md) describes the built-in property and matching policy; the contract remains the source of truth for shared service types and precedence guarantees.

## Tests

[Desktop schema tests](../desktop/rules/tests/schema-validation.luau) cover callback predicates, matrix poses, and malformed rules. Placement tests exercise source resolution with panels and tags.