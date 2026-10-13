# Audio provider

The audio provider exposes non-routing PCM readers for the system output mix and registered session processes. It does not change application-to-device links, the default sink, or device volume. Capture starts only when a consumer opens a reader.

The module is `@lunette-plugins/audio`. The shipped desktop entry id is `audio`. The provider supplies `lunette/audio` version 1 and requires `lunette/frame`. Its configuration is empty. The schema in [`config.luau`](config.luau) is the source of truth.

Consumers open `{ kind = 'system' }` or `{ kind = 'process', process = handle }`, where `handle` is a registered `lunette.Process`. A source cannot be selected by PID or application name. Readers are owner-scoped. The contract in [`lua/lunette-contracts/audio.luau`](../../lunette-contracts/audio.luau) is the source of truth for reader, snapshot, block, and source types.

See [audio readers](docs/readers.md) for provider lifecycle and publication behavior. The [central audio specification](../../../docs/dev/audio.md#non-routing-capture) owns shared capture guarantees, process attribution, state vocabulary, publication limits, and pending live acceptance. See [Lua audio capture](../../../docs/dev/lua-api.md#audio-capture) for the native API boundary. The [audio-backdrop meter](../../../examples/audio-backdrop/meter.luau) consumes raw and analysed audio without a backdrop dependency. The [audio provider tests](tests/provider.luau) exercise the provider without a live PipeWire server.

## Configuration and extension

The provider has no settings or hooks. A consumer selects its source when it opens a reader through `lunette/audio`. It can inspect registered process handles and labels through `service:processes()` without opening capture.

## Known gaps

Live PipeWire graph acceptance remains pending. The off-host provider tests do not establish host linking, mixing, playback preservation, or cleanup. See [audio acceptance](../../../docs/dev/audio.md#acceptance) for the operator checks.