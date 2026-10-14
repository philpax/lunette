# Audio analysis

Turns shared PCM readers into sample-time spectral features without selecting a source or requiring a visual plugin. Readers with the same source and analysis profile share work.

Gaps clear analysis history rather than becoming silence. Steady levels remain unavailable until a full analysis window completes, including after a gap.

Publications retain immutable per-channel band powers alongside their arithmetic average. The per-channel values contain each channel's full power. Opposite channel phases do not cancel the combined power.

[Contract](../../../lunette-contracts/audio-analysis.luau) · [Reader example](../../../../examples/audio-backdrop/meter.luau)
