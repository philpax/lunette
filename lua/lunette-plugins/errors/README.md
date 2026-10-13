# Error stream

The error-stream provider subscribes to native Lua error reports, retains the latest delivered report, and notifies consumers. The desktop presenter is a separate entry.

## Entry

- Module: `@lunette-plugins/errors` (`lua/lunette-plugins/errors/init.luau`).
- Desktop entry id: `errors`.
- Capability: `lunette/errors` version 1, declared in [the errors contract](../../../lua/lunette-contracts/errors.luau).

## Dependencies

The provider requires no plugin capabilities. It subscribes to `lunette.onError` for its activation. The separate `desktop/errors` consumer presents reports and is not required by the provider.

## Configuration and extension

The schema in [config.luau](config.luau) defines the duplicate-report `window` and `maxKeys` limits. The shipped entries are listed in [standard plugins](../../../docs/dev/standard-plugins.md#default-configuration). Consumers subscribe through the errors contract. [Error-stream behaviour](docs/error-stream.md) specifies suppression and delivery. [Error boundaries](../../../docs/dev/lua-api.md#errors) remain part of the native API specification.

## Tests

[Error-stream tests](tests/stream.luau) cover report delivery, the latest report, and repeated-report suppression.