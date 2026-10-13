# Error overlay

`@lunette-plugins/desktop/errors` displays the latest error report on a quad during the `overlay` draw phase. The shipped desktop uses entry `desktop/errors`.

The entry requires `lunette/errors`, `lunette/frame`, and `lunette/theme`. [`config.luau`](config.luau) is the source of truth for position, width, line and column limits, and optional theme overrides. Errors from providers, callbacks, and the runtime are governed by the shared [Errors stream](../../../../docs/dev/lua-api.md#errors-stream) contract; report delivery and protection boundaries remain central. Tests: [`errors.luau`](tests/errors.luau) and [`lines.luau`](tests/lines.luau).

## Known gaps

This consumer renders the latest report supplied by the shared errors service. Error capture and protected-call boundaries are specified in [The Lua API](../../../../docs/dev/lua-api.md#errors-stream) and [Frame dispatch](../../../../docs/dev/lua-api.md#frame-dispatch).
