# Laser provider

The laser provider creates hand-owned beams that read headset input, update interaction pointers, and draw pointer feedback. The shipped desktop entry id is `laser`.

- Module: `@lunette-plugins/laser` (`lua/lunette-plugins/laser/init.luau`)
- Provides: `lunette/laser` version 1.
- Requires: `lunette/interaction` version 2 and `lunette/theme` version 1.
- Configuration: `style`, `aim`, `triggerLock`, `buttons`, `readInput`, and `draw`. [`config.luau`](config.luau) and its linked schema modules are the source of truth for types and defaults. The callbacks wrap the default input reader and drawing implementation.
- Per-attachment options: seat and seat name, `aim`, `triggerLock`, pointer `tuning`, `style`, and optional input reader, as declared by [`lua/lunette-contracts/laser.luau`](../../../lua/lunette-contracts/laser.luau).
- Tests: [`tests/laser.luau`](tests/laser.luau), [`tests/draw.luau`](tests/draw.luau), [`tests/drag-icon.luau`](tests/drag-icon.luau).
- Filtering, trigger lock, and drag-icon drawing: [Aim and drag feedback](docs/aim-and-drag-feedback.md).
- Shared pointer, seat, and native drag guarantees: [Input](../../../docs/dev/input.md#seats) and [Drag and drop](../../../docs/dev/input.md#drag-and-drop).

The shipped `desktop/pointing` consumer attaches both hands using the `laser` entry's configuration. The provider catalogue and default composition are in [Standard plugins](../../../docs/dev/standard-plugins.md#contracts-and-providers) and its [default configuration](../../../docs/dev/standard-plugins.md#default-configuration). The consumer's update and drawing phases are described in [`desktop/pointing`](../desktop/pointing/README.md).
