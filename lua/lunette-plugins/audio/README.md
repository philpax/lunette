# Audio

Audio separates source capture from shared spectral analysis. [Capture](capture/README.md) opens PCM readers for the system output mix or registered session processes. [Analysis](analysis/README.md) shares sample-time spectral analysis by source and profile; discontinuities invalidate history rather than becoming silence. Neither plugin changes routing or volume, or requires a visual consumer.

The [audio contract](../../lunette-contracts/audio.luau) defines readers, the [analysis contract](../../lunette-contracts/audio-analysis.luau) defines feature publications, and the [frame contract](../../lunette-contracts/frame.luau) supplies updates. [Native audio limits](../../../docs/development/native/audio.md) apply to both leaves. [Shipped plugins](../README.md) defines public imports.
