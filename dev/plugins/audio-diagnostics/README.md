# Audio diagnostics

The audio diagnostics plugin is an opt-in development consumer. It reports public audio and analysis snapshots through the development logging consumer. It retains no PCM history beyond the interval summary and uses no renderer or headset API.

The source module is `dev/plugins/audio-diagnostics/init.luau`. Its plugin definition name is `dev/audio-diagnostics`. It has no entry in the default development desktop in [`dev/main.luau`](../../main.luau), and therefore has no default desktop entry id. A configuration that inserts it chooses the entry id and must compose it alongside the `frame`, `audio`, and `audio-analysis` providers. The plugin requires all three contracts.

The schema in [`init.luau`](init.luau) is the source of truth. `enabled` defaults to false. `interval` defaults to 1 second and accepts 0.1 to 60 seconds. `source` is a callback that defaults to the system mix and can return a system or logical process source. The plugin exposes no additional settings or hooks.

Each report includes source identity, state, frame generation, attribution provenance, PCM format and sequence metadata, gaps and dropped frames, analysis profile and publication metadata, RMS, peak, band powers, spectrum in dBFS, and the latest onset values when available. Interval history preserves transient loss and generation changes until the next report.

See [audio diagnostics tests](tests/diagnostics.luau) for default-disabled behavior, reader cleanup, source identity, public metadata, and interval history. See the central [audio specification](../../../docs/dev/audio.md#lua-providers) for shared capture guarantees and [analysis specification](../../../lua/lunette-plugins/audio-analysis/docs/analysis.md) for analysis calculations.

## Known gaps

The plugin and its tests do not establish live PipeWire graph behavior. Live capture acceptance remains pending in [audio acceptance](../../../docs/dev/audio.md#acceptance).