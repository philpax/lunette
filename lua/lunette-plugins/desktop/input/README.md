# Desktop input

The desktop input consumer routes physical key presses and committed text through a physical focus source. It handles bindings before delivery and requires no bindings provider. The shipped desktop entry id is `desktop/input`.

- Module: `@lunette-plugins/desktop/input` (`lua/lunette-plugins/desktop/input/init.luau`)
- Provides: none.
- Requires: `lunette/focus` version 2 and `lunette/frame` version 2.
- Configuration: none.
- Tests: [`tests/input.luau`](tests/input.luau).
- Built-in batch delivery and text blocking: [Physical delivery](docs/physical-delivery.md).
- Shared batch guarantees and known limits: [Physical input batches](../../../../docs/dev/input.md#physical-input-batches) and [Input known gaps](../../../../docs/dev/input.md#known-gaps).

The frame contract and focus contract define the service shapes. The source of truth for default composition and order is [`lua/lunette-desktop/init.luau`](../../../../lua/lunette-desktop/init.luau). The catalogue is in [Standard plugins](../../../../docs/dev/standard-plugins.md#default-configuration).
