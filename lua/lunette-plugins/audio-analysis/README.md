# Audio analysis provider

The audio analysis provider turns shared PCM readers into sample-time analysis snapshots. It publishes completed FFT hops, steady band powers, and separate bass, mid, and treble onset values. It does not select sources or depend on a visual consumer.

The module is `@lunette-plugins/audio-analysis`. The shipped desktop entry id is `audio-analysis`. The provider supplies `lunette/audio-analysis` version 1 and requires `lunette/audio` and `lunette/frame`. Its configuration is empty. The schema in [`config.luau`](config.luau) is the source of truth. Each reader selects its size and hop profile when it opens.

The contract in [`lua/lunette-contracts/audio-analysis.luau`](../../lunette-contracts/audio-analysis.luau) owns the service types, profile options, publication shape, and capacity guarantees. The raw audio contract in [`lua/lunette-contracts/audio.luau`](../../lunette-contracts/audio.luau) owns source and PCM block types. [Analysis](docs/analysis.md) specifies the transform and feature calculations. [Audio provider guarantees](../../../docs/dev/audio.md#lua-analysis) describes ownership, sharing, result kinds, and per-runtime limits.

## Configuration and extension

The provider has no settings or hooks. Consumers choose `size` and `hop` through `service:open(owner, source, options?)`. The accepted profiles and defaults are defined by the audio-analysis contract and documented in [the analysis specification](docs/analysis.md#profiles-and-capacity). Readers with the same source and profile share analysis work.

## Tests

The [analysis tests](tests/) cover the FFT against a direct DFT oracle, feature values against an independent spectral oracle, streaming discontinuities, publications, and profile sharing and validation.

## Known gaps

Live PipeWire graph acceptance remains pending for the raw audio provider. Analysis tests use synthetic PCM and do not establish live capture behavior. See [audio acceptance](../../../docs/dev/audio.md#acceptance).