# Audio response

The optional response child maps public audio-analysis features to the backdrop model. The analysis provider defines the transforms and feature values in [analysis](../../../audio-analysis/docs/analysis.md).

## Feature mapping

Coarse bass, mid, and treble levels set separate curtain geometry and altitude zones. Spectrum levels colour the hem, body, and rays. The response does not normalize each frame to its own peak, so silence remains dark and absolute level remains meaningful. A screen-wide brightness response was rejected because it obscures spatial variation and makes level changes abrupt.

Onsets create localized waves: bass heaves and flashes the hem, mid ripples through the body, and treble lifts nearby rays. Each band has its own wave pool so frequent treble events cannot evict a bass response. The per-band colours and actions keep simultaneous registers distinct; one loudness-driven colour ramp merged them.

The response follows sample time rather than render-frame estimates. It processes each publication once and never replays an onset from an empty publication. A source change crossfades features, not PCM; unavailable or ended input settles toward zero without choosing another source. Generation changes and analysis gaps clear onset history.

Onsets use a quantized head-facing anchor and deterministic offsets derived from sample position and band. This keeps events in view without chasing every head movement, while keeping replayed publications spatially stable. The previous fixed front for application audio and -z anchor for system audio was replaced because it made the environment face one direction.

Steady levels attack more slowly than onset effects. Fast level changes flickered the ray tops, so transients use onset waves instead. See [rendering acceptance](rendering.md#acceptance) and [audio acceptance](../../../../../docs/dev/audio.md#acceptance); live capture and headset checks remain pending.
