# Audio diagnostics

This opt-in development consumer reports public audio and analysis snapshots through the development logging consumer. It keeps interval summaries, not PCM history, and uses no renderer or headset API.

The plugin is not installed or in the default development desktop. Enabling diagnostics merely by requiring the development configuration would open an unexpected reader. A configuration adds it explicitly and chooses an entry id.

| Requires |
| --- |
| `lunette/frame`, `lunette/audio`, `lunette/audio-analysis` |

[Options](init.luau) · [Analysis calculations](../../../lua/lunette-plugins/audio-analysis/docs/analysis.md) · [Audio provider](../../../lua/lunette-plugins/audio/README.md).

Live PipeWire graph acceptance remains pending; plugin tests do not establish live capture. See [audio acceptance](../../../docs/dev/audio.md#acceptance).
