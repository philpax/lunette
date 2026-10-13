# Audio analysis provider

The provider turns shared PCM readers into sample-time FFT features for independent consumers. It selects no source and depends on no visual plugin.

| Provides | Requires |
| --- | --- |
| [`lunette/audio-analysis`](../../lunette-contracts/audio-analysis.luau) | [`lunette/audio`](../../lunette-contracts/audio.luau), `lunette/frame` |

Consumers choose a window and hop profile when opening a reader; readers with the same source and profile share analysis work. Use newly completed `hops` for transients and `latest` for steady levels. `latest` can be absent until a full window completes, including after a gap. See [analysis](docs/analysis.md) for calculations and discontinuities, and [the contract](../../lunette-contracts/audio-analysis.luau) for profiles and capacity limits.
