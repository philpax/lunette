# Diagnostics

Diagnostics separates error reporting, retained reports, and panel presentation.

## Plugin leaves

- [Error stream](error-stream/README.md) retains native Lua reports and suppresses repeated reports.
- [Error display](error-display/README.md) presents the latest report independently of retention.

The [errors contract](../../lunette-contracts/errors.luau) defines shared reports. [Native error boundaries](../../../docs/development/native/lua-api.md#errors) define protected dispatch and reporting.

## Public libraries

- [Protected call](protected-call.luau), `@lunette-plugins/diagnostics/protected-call`, runs a supplied callback and reports failure through the public native error API. It returns failure to the caller instead of raising the callback error again.
- [Desktop logging](desktop-logging.luau), `@lunette-plugins/diagnostics/desktop-logging`, preserves `report(message, level)` and forwards to LÖVR logging under `lunette.desktop`. When logging is unavailable, it prints the message with the existing `lunette: ` prefix.

Both libraries run in the caller's main Lua state. They acquire no retained resources, install no callbacks, and publish no services. The caller owns dispatch and the decision to continue after a reported failure.

[Shipped plugins and public imports](../README.md)
