# Audio readers

The audio provider supplies `lunette/audio` version 1 and requires `lunette/frame`. The contract in [`lua/lunette-contracts/audio.luau`](../../../lunette-contracts/audio.luau) owns the source, state, snapshot, block, and reader types. The provider's empty configuration schema is in [`config.luau`](../config.luau).

## Reader lifecycle and publications

Loading or activating the provider opens no capture. `service:open(owner, source)` acquires a reader for `{ kind = 'system' }` or `{ kind = 'process', process = handle }`. The handle is a registered session `Process`, not a PID or application name. `service:processes()` lists live logical processes with display labels and optional cached source status without acquiring readers.

A reader exposes `source`, `snapshot()`, and idempotent `close()`. Its owner releases it on deactivation. Several owners reading one source share capture and the same frame publication. Closing one reader leaves the other readers active. Cleanup freezes an empty ended snapshot at the reader's last publication and detaches its shared capture state. Retaining a closed reader therefore retains no PCM blocks.

The provider polls in the `input` update phase before consumers. A snapshot contains `source`, `state`, `frameGeneration`, and `blocks`. The frame generation identifies publication, while each block's `generation` identifies the capture stream. Consumers can read a snapshot repeatedly without draining it. They use block sequence and generation to avoid processing retained data twice.

Each block contains `sequence`, `generation`, `frameCount`, `sampleRate`, `channels`, `startFrame`, `timing`, `gap`, `droppedFrames`, and `copySamples()`. The copied buffer contains `frameCount * channels` little-endian F32 samples, or `frameCount * channels * 4` bytes. `frameCount` counts complete stereo frames. `startFrame` is cumulative sample time within the stream generation, and `timing = 'sample-frames'` states that it is not a native capture timestamp. Consumers handle state changes and discontinuities explicitly rather than treating an empty publication as silent PCM.

The [central audio specification](../../../../docs/dev/audio.md#non-routing-capture) owns native capture, attribution, state, graph, queue, and live acceptance guarantees. In particular, live PipeWire graph acceptance remains pending. The [Lua audio capture API](../../../../docs/dev/lua-api.md#audio-capture) owns the native API boundary.

## Known gaps

The provider tests exercise owner-scoped sharing and publication behavior through the fake native boundary. They do not establish host graph linking, mixing, playback preservation, or cleanup. See [audio acceptance](../../../../docs/dev/audio.md#acceptance).