# Plugin facade

`@lunette-plugin` lets plugin authors declare typed capabilities, build definitions, and compose session entries. Consumers import [neutral contracts](../lunette-contracts/README.md), declare dependencies, and read services through their context. Native graph planning belongs to the [plugin runtime](../../docs/dev/architecture.md#plugin-runtime).

## Capabilities and definitions

Capabilities carry a service type and identify a contract by name and positive version. Use `plugin.capability`, not native contract constructors. Definitions publish provisions only after successful initialization and reject undeclared access. Runtime validation checks declarations and matching, not service fields; Luau supplies that check. Callbacks must be synchronous and must not yield.

## Configuration and composition

[Configuration and composition](configuration-and-composition.md) defines schema resolution, factories, patches, and managed startup. [Ownership and lifecycle](ownership.md) defines resource release and service revocation. [Writing plugins](../../docs/guide/writing-plugins.md) links complete checked examples; [facade declarations](init.luau) own the API.

## Authority limits

Plugins share the Lua state and full native API; the runtime is not a security boundary. Contract authorities are naming conventions, not authenticated identities. The first declaration of a name and version binds its identity for the current source-reload epoch. Package authority enforcement remains open to packaging and distribution (#39).
