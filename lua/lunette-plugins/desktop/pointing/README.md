# Desktop pointing

The desktop pointing consumer attaches left and right lasers, updates them against the offered surfaces, and draws their feedback after overlay UI. The shipped desktop entry id is `desktop/pointing`.

- Module: `@lunette-plugins/desktop/pointing` (`lua/lunette-plugins/desktop/pointing/init.luau`)
- Provides: none.
- Requires: `lunette/frame` version 2, `lunette/laser` version 1, and `lunette/surfaces` version 1.
- Configuration: none. Both hands use the configuration of the separate `laser` entry.
- Tests: [`tests/pointing.luau`](tests/pointing.luau).
- Phase ordering and decision: [Pointing phases](docs/pointing-phases.md).
- Shared pointer, laser, and frame contracts: [Input](../../../../docs/dev/input.md#surface-pointer-input) and [Frame dispatch](../../../../docs/dev/lua-api.md#frame-dispatch).

The source of truth for default composition and entry order is [`lua/lunette-desktop/init.luau`](../../../../lua/lunette-desktop/init.luau). The catalogue is in [Standard plugins](../../../../docs/dev/standard-plugins.md#default-configuration).
