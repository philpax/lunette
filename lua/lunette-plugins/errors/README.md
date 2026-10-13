# Error stream

The error provider retains and publishes native Lua error reports. The separate desktop presenter can be replaced without disabling the stream.

`lunette/errors` suppresses repeated reports by exact message and traceback, then delivers the accumulated count when the suppression window ends. It retains the latest delivered report for consumers that start late. A report raised by a listener becomes latest but is not delivered recursively, so a failing presenter cannot feed itself.

[Options](config.luau) · [Contract](../../lunette-contracts/errors.luau) · [Native error boundaries](../../../docs/dev/lua-api.md#errors)
