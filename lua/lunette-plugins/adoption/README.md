# Adoption

The adoption provider makes eligible compositor windows into panels through the rules and placement services. The shipped consumer starts adoption and supplies its default tags and filter.

## Entry

- Module: `@lunette-plugins/adoption` (`lua/lunette-plugins/adoption/init.luau`).
- Desktop entry id: `adoption`.
- Shipped consumer: `@lunette-plugins/desktop/adoption`, entry id `desktop/adoption`.
- Capability: `lunette/adoption` version 1, declared in [the adoption contract](../../../lua/lunette-contracts/adoption.luau).

## Dependencies

The provider requires `lunette/panels`, `lunette/placement`, and `lunette/rules`. It has no configuration fields. The shipped consumer requires `lunette/adoption`; its optional pose-memory child also requires `lunette/drops`, `lunette/panels`, and `lunette/rules`.

## Configuration and extension

The provider has no settings. The shipped consumer's schema in [desktop/adoption/config.luau](../desktop/adoption/config.luau) defines `tags` and the `filter` callback. The callback decides whether each window is adopted. The contract defines the service types and options; provider replacements must satisfy that contract.

[Adoption policy](docs/adoption-policy.md) describes the shipped consumer and pose memory. [Standard plugins](../../../docs/dev/standard-plugins.md#placement) summarizes how the default entries compose. [The Lua API](../../../docs/dev/lua-api.md#rules-and-placement) specifies shared placement guarantees.

## Tests

The provider's shipped connections are listed in [standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers). [Provider adoption tests](tests/adoption.luau) cover existing and newly opened windows. [Pose-memory tests](../desktop/adoption/tests/pose-memory.luau) cover dropped poses and precedence.