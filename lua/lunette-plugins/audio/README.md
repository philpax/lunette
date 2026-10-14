# Audio

Audio separates source capture from shared spectral analysis. Neither plugin changes routing or volume, and neither requires a visual consumer.

## Plugin leaves

- [Capture](capture/README.md) opens PCM readers for the system output mix or registered session processes.
- [Analysis](analysis/README.md) shares sample-time spectral analysis by source and profile. Discontinuities invalidate history rather than becoming silence.

The [audio contract](../../lunette-contracts/audio.luau) defines readers. The [analysis contract](../../lunette-contracts/audio-analysis.luau) defines feature publications. The [frame contract](../../lunette-contracts/frame.luau) supplies updates. [Native audio limits](../../../docs/development/native/audio.md) apply to both leaves.

[Shipped plugins and public imports](../README.md)
