# Audio analysis

The analyzer follows PCM sample positions rather than render-frame timing. The [contract](../../../lunette-contracts/audio-analysis.luau) defines profiles, snapshots, and capacity limits.

## Feature calculation

The analyzer applies a periodic Hann window, transforms each stereo channel independently, and averages normalized one-sided bin powers. RMS and peak use the unweighted input window, so time-domain level remains distinct from windowed spectral power. Coarse bass, mid, and treble powers sum the corresponding spectrum bands.

Spectral flux measures positive changes in bin magnitude. A relative denominator and threshold suppress steady noise; each coarse band has its own flux and onset threshold. This separates register-specific transients without claiming beat or tempo detection.

## Discontinuities

A stream-generation change, sample-position gap, invalid sample, or loss of active source state resets carry and onset history. Missing PCM is reported as a gap, not converted to silence. Publications contain only newly completed hops; an empty hop list does not replay an onset. The latest steady values clear when active history is interrupted.

These rules keep features tied to captured samples instead of render-frame timing. Consumers can measure publication age from sample positions without treating them as native capture timestamps.

The implementation is in [`features.luau`](../features.luau) and [`fft.luau`](../fft.luau). Synthetic-input tests do not establish live PipeWire or headset behavior. Live capture acceptance remains pending in [audio acceptance](../../../../docs/dev/audio.md#acceptance).
