# Plugin facade

`@lunette-plugin` declares typed capabilities and plugin definitions, and composes them into session entries. It validates declarations and configuration at runtime; the native [plugin runtime](../../docs/dev/architecture.md#plugin-runtime) owns graph planning, provider matching, retries, reservations, and epochs.

Consumers import service types from `@lunette-contracts`, declare required capabilities, and read services through their context. Providers declare capabilities and publish implementations during initialization. The contract modules define service shapes; provider documentation defines implementation options and behavior. Native mechanisms remain in `@lunette`.

## Capabilities and definitions

A capability identifies a contract by non-empty name and positive integer version, and carries its Luau service type. Declarations list capability values, not contract-name strings. Definitions reject unknown fields, duplicate or invalid capabilities, and undeclared capability access. A provider can stage one provision per declared capability only during initialization. Provisions are published only after initialization succeeds. The runtime checks graph and provision validity, not whether a service value's fields satisfy its Luau type.

Native plugin handles are nominal types: tokens, definitions, runtimes, instances, contexts, and effects cannot be replaced by ordinary tables. Use `plugin.capability`, not the native contract constructor. Source reload retires the contract epoch, and plugin callbacks are synchronous and must not yield.

## Configuration and composition

Configured provider and consumer modules separate optional `Config` from resolved, read-only `Settings`. A schema supplies their types and runtime validation. `definition` uses default settings; `define` binds defaults and an optional name. `plugin.compose` validates and freezes entries without starting them. `management.start` preflights all entry configurations before activation. See [Configuration and composition](configuration-and-composition.md) and the [schema guide](../../docs/guide/configuration-schema.md).

Shared service interfaces belong to [`@lunette-contracts`](../lunette-contracts/README.md). The [input](../lunette-contracts/docs/input.md) and [panels and UI](../lunette-contracts/panels-and-ui.md) references describe those service families.

## Decisions

Declarations are lists keyed by capability identity: `Context:require` and `Publisher:provide` already use the token, while a second name would duplicate contract identity. The facade uses “version” for contract identity and reserves “schema” for configuration descriptors. Native contract creation stays behind `plugin.capability` so policy uses the typed facade.

## Known gaps

The pinned checker reports an omitted capability service type as `unknown`; a type-level omission error exceeded its complexity limits. Runtime checks do not establish service-shape correctness. Plugins share the configuration's Lua state and full native API, so the runtime is not a security boundary; isolation would require separate states and a narrowed API.

## Deliberately left open

Contract authorities are naming conventions, not authenticated identities. Any module can declare any authority, including `lunette`; the first declaration of a name and version in an epoch binds that identity. Binding authorities to permitted packages remains open to packaging and distribution (#39).
