# Diagnostics

Diagnostics separates error reporting, retention, and presentation. [Error stream](error-stream/README.md) retains native Lua reports and suppresses repeats. [Error display](error-display/README.md) presents the latest report independently of retention. The [errors contract](../../lunette-contracts/errors.luau) defines shared reports, and [native error boundaries](../../../docs/development/native/lua-api.md#errors) define protected dispatch and reporting.

- [Protected call](protected-call.luau), `@lunette-plugins/diagnostics/protected-call`, runs a supplied callback and reports failure through the public native error API. It returns failure instead of raising the callback error again.
- [Desktop logging](desktop-logging.luau), `@lunette-plugins/diagnostics/desktop-logging`, forwards reports to LÖVR logging under `lunette.desktop`. Without logging, it prints the message with the `lunette: ` prefix.

Both libraries run in the caller's main Lua state, acquire no retained resources, install no callbacks, and publish no services. The caller owns dispatch and whether execution continues after failure. [Shipped plugins](../README.md) defines public imports.
