# Audio analysis

The analysis provider consumes the raw audio contract and publishes sample-time features. The source-selection policy and visual response remain separate Lua responsibilities. The service API, immutable snapshot shape, ownership rules, sharing, capacity limits, and per-frame work limits remain in the central [audio specification](../../../../docs/dev/audio.md#lua-analysis) and the [`lunette/audio-analysis` contract](../../../lunette-contracts/audio-analysis.luau).

## Profiles and capacity

The provider accepts sample windows of 512, 1024, or 2048 samples. A hop is one quarter or one half of the window. The default window is 2048 samples, and the default hop is 512 samples. The sample rate is 48,000 Hz and input is interleaved stereo F32 PCM.

These are reader options, not provider configuration. The provider returns `invalid-options` for invalid option tables and `capacity-exceeded` when a requested distinct profile cannot be opened. Equal source and profile readers share storage and work. The contract defines the limit of two distinct profiles per source and eight per runtime. The per-frame analyzer accepts at most 12,000 frames and publishes at most 94 hops. These API guarantees remain central and are repeated here only to place the algorithm in context.

## FFT

`fft.luau` implements an in-place, forward, unnormalised radix-2 complex FFT. It reuses its real and imaginary arrays. It precomputes bit-reversed indices and sine/cosine twiddle tables, then performs the butterfly stages in place. The FFT module accepts positive power-of-two sizes up to 1,048,576; analysis profiles use only 512, 1024, and 2048.

## Window and spectral power

Each analysis window applies the periodic Hann function `0.5 - 0.5 * cos(2 * pi * index / N)`. The transform runs independently on the left and right channels. Each one-sided bin power is `abs(FFT)^2 / (N * sum(window^2))`, doubled except at DC and Nyquist. The analyzer averages the two channel powers. The transform itself is not normalised.

RMS and peak use the complete, unweighted stereo window. RMS is the square root of the sum of squared channel samples divided by `N * 2`. Peak is the largest absolute channel sample in the window.

Bin centres select three half-open bands at 48,000 Hz: bass is 30 Hz inclusive to 250 Hz exclusive, mid is 250 Hz inclusive to 2000 Hz exclusive, and treble is 2000 Hz inclusive to 10000 Hz exclusive. The provider sums the averaged one-sided bin powers in each band. A band with no bin centre at the selected profile size has zero power. For example, the 30 to 60 Hz spectrum band has zero power at size 512.

The eight spectrum bands have a 30 Hz floor and exclusive upper edges at 60, 120, 250, 500, 1000, 2000, 4000, and 10000 Hz. Spectrum bands 1 to 3 sum to bass power, bands 4 to 6 sum to mid power, and bands 7 and 8 sum to treble power. The coarse boundaries at 250 Hz and 2000 Hz are also spectrum boundaries.

## Spectral flux and onsets

For each selected bin, the analyzer compares the current square-root power with the previous square-root power. It sums only positive changes. Full-band flux divides that sum by the previous magnitude sum with a floor of 0.001, then clamps the result to 0 through 1. Flux is zero below RMS 0.001 and on the first complete window after reset. Full-band onset is `clamp((flux - 0.08) / 0.24, 0, 1)`.

Each coarse band also has its own flux. Its positive magnitude changes are restricted to bins in that band. Its denominator is the largest of that band's previous magnitude sum, one tenth of the full-band previous magnitude sum, and 0.001. The full-band share keeps noise in a quiet band from registering as an event. Band onset is `clamp((bandFlux - 0.3) / 0.4, 0, 1)`.

A single band's flux rests higher than the full-band flux under steady noise. The mid band reaches about 0.35 under steady noise, so the band threshold is higher than the full-band onset threshold. Separate band onsets let a kick, snare, and hi-hat register in their respective frequency ranges. Beat and tempo detection are outside the contract.

## Discontinuities and publication

The analyzer follows PCM sample positions rather than render-frame duration. A stream generation change, sequence or sample-time discontinuity, explicit gap, capacity loss, invalid sample, or interruption of active source state resets carry and onset history. The analyzer reports gaps and discarded frames. It does not turn missing PCM into silence.

Snapshots publish completed hops for the current publication only. Empty hop lists do not replay the last onset. The `latest` field retains the last completed steady values only while active history remains uninterrupted; a state loss or analysis reset clears it until another complete window. Snapshot `endFrame` is the exclusive end of the last processed PCM block, including blocks that complete no hop. Consumers calculate delivery age from matching stream generations and sample positions.

The contracts own the public fields and guarantees. [`features.luau`](../features.luau) and [`fft.luau`](../fft.luau) are the implementation source for the calculation.

## Tests

The FFT suite compares reusable transforms against a direct DFT oracle for sizes 1, 2, 4, 8, 16, 32, and 64, checks invalid sizes, and checks impulses, DC, and bin-centred tones at 512, 1024, and 2048. The feature suite compares powers, RMS, and peak with a separate direct DFT oracle, including stereo phase, boundary bins, impulses, and silence. Streaming and publication tests cover generation changes, discontinuities, invalid samples, bounded work, retained publications, and profile sharing. `examples/audio-backdrop/meter.luau` demonstrates raw and feature readers without importing a backdrop module. Its tests run the real providers without the desktop, a GPU, playback, or a live PipeWire server.

These tests use synthetic PCM. They do not establish live PipeWire capture or headset behavior. [Audio acceptance](../../../../docs/dev/audio.md#acceptance) records the pending operator checks.

## Decisions

The analysis provider remains independent of the backdrop. Consumers acquire readers through the neutral contracts, so disabling a visual effect does not withdraw PCM or analysis from other consumers. Per-owner readers share capture and profile work without allowing one consumer to drain or mutate another consumer's publication. Requiring the visual consumer to obtain reusable features was rejected because independent plugins must work without it. Capture and analysis remain lazy, so an unused provider does not open a host stream.

Analysis follows sample time and publishes completed FFT hops rather than render-frame estimates. This keeps the reported features tied to the captured samples and lets consumers measure publication age without inventing a capture timestamp.

The periodic Hann transform uses stereo-averaged one-sided bin powers. RMS and peak use the unweighted input window, so time-domain level remains distinct from windowed spectral power.

The eight-band spectrum shares boundaries with the coarse bass, mid, and treble bands. This makes the three coarse powers sums of complete spectrum bands. More detailed spectrum bands are retained for consumers without imposing a visual policy.

## Known gaps

Live PipeWire graph acceptance remains pending for the raw provider. The analyzer has no live audio or headset validation claim; its tests exercise pure analysis and the fake native boundary.

## Deliberately left open

Beat and tempo detection are outside the analysis contract. They are not implemented by the provider.