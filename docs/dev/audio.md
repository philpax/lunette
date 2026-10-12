# Audio

## Non-routing capture

Native capture exposes the system output mix or an existing session process. It adds monitor streams and lunette-owned mixing links without changing application-to-device links, the default sink, or device volume. Capture never opens a microphone or substitutes another source after an outage. Spatial routing remains a separate deferred feature.

`crates/lunette-capture/src/audio/` owns capture mechanism and its source/state vocabulary. The public PCM boundary is 48,000 Hz, interleaved stereo F32. PipeWire performs rate conversion and stereo downmix before this boundary. The stream requests and validates the negotiated format. A rejected or different format reports `unsupported-format`; it is never reinterpreted as stereo. Lua sample copies encode each F32 little-endian regardless of host endianness. One frame contains two samples.

A source descriptor is a closed union of the system mix and a session `Process` handle. `lunette.processes()` lists registered processes, including adopted clients. `window.process` associates a window with its registered process when attribution is available. Lua cannot select a raw PID or adopt an arbitrary host process. Display names do not establish identity.

### Process attribution

The compositor records a PID and an opaque instance discriminator from the Linux process start time when registering a managed or adopted process. Exact PID matching and adopted liveness compare the recorded instance with a current observation. Observation failure does not transfer identity to a replacement process. A spawned child remains owned, its output remains collected, and it remains reaped even if its identity cannot be read.

An audio attribution request carries a request identifier, PipeWire connection generation, node serial, and observed process instance. The compositor resolves a direct live instance first, then the inherited authentication token of a spawned descendant. It observes the candidate instance before reading the environment and again afterward. Both observations must equal the requested instance, and the matched logical root must remain live. The token never leaves the compositor. Exit, access denial, or identity change produces an unresolved result. A pending reply is discarded if its request, source, node, or connection identity changed. The same node is not retried against a replacement PID instance.

A pending attribution delivery expires after the capture worker's injected retry interval, 500 ms by default. The next eligible bounded worker tick observes the same pinned process instance and issues a fresh request identifier. A dropped request or reply can therefore recover without replacing the node or process. Expired replies cannot complete a later attempt. Confirmed PID-instance replacement remains blocked for that node lifetime. Queue recovery, continued worker ticks, and process observation are prerequisites; a permanently full queue or stalled inspector has no finite recovery guarantee.

Native PipeWire clients report their PID through `pipewire.sec.pid`. The compatibility server marks Pulse clients with `client.api = 'pipewire-pulse'`; application display names do not identify that protocol. PulseAudio-compatible playback may instead report `application.process.id`. This second assertion is application metadata, not authentication. It requires corroboration with the current OS instance and the logical-process resolver. The public status preserves this provenance. Missing, ambiguous, inaccessible, or namespace-mismatched attribution remains unresolved. Automatic selection uses only a single resolved logical process and never uses application-name matching.

### Source state

The state union contains `starting`, `active`, `idle`, `unavailable`, and `ended`. `active` may contain silence. `idle` means no playback node is present. `unavailable` carries a closed reason and diagnostic detail. Reasons include no server, no default sink, invalid default metadata, permission denied, unsupported format, unresolved attribution, capacity exceeded, and graph failure. Recoverable outages preserve the source identity and may return to `starting` or `active`. `ended` means a closed handle or an invalid or ended process.

The public `Process.dead` field remains true before a queued spawn appears in a snapshot. Capture tracks pending, live, and failed-or-ended registration separately. A valid pending process stays `starting` until the spawn succeeds or produces a terminal outcome. A missing snapshot is not a spawn failure. An unreadable managed or adopted instance reports attribution unavailable instead of permitting a PID-only match.

### Publication and ownership

Capture is lazy and shared per source within a session. The first reader opens the stream; the last reader releases it and its owned graph objects. The default source limit is eight. Each process source mixes all attributed playback nodes into one internal stereo monitor. Original playback links remain intact. A silent selected process remains selected.

The frame thread publishes immutable complete PCM blocks once at the frame boundary. Repeated snapshots in the same frame do not drain queues. Retained blocks remain valid across frames. `copySamples()` returns a fresh Luau buffer, so consumers cannot alter native PCM or another consumer's copy. Blocks carry sequence, stream generation, frame count, format, sample-time position, and gap information. Cumulative sample timing is labelled as such when native timestamps are absent. Stream-generation changes reset timing.

Queues retain at most 250 ms of stereo frames. Publication snapshots committed occupancy and consumes only packets present at that cutoff, with a limit of 12,000 frames and 64 packets per source. Producers cannot extend one publication by replenishing the queue. Packet loss and deliberate history discard produce explicit gaps. Process callbacks use preallocated storage, publish samples and metadata atomically, and perform no allocation, logging, Lua calls, blocking locks, or waits.

The worker tracks the `default` metadata object's `default.audio.sink` name and the live sink's serial and connection generation. System capture targets that sink's monitor with fallback and implicit reconnection disabled. Each process source owns one non-autoconnecting `Stream/Input/Audio` null-sink adapter and non-lingering additive links from every attributed playback node. Explicit channel mapping folds left channels to FL, right channels to FR, and centre, mono, and LFE channels to both at unity gain. Unknown channel positions make the whole source unavailable. Capture validates the converted monitor's negotiated stereo format before accepting PCM. Registry observations and graph operations cross project-owned interfaces; recording implementations exercise the same reconciliation driver without opening a host connection.

## Lua providers

`lua/lunette-contracts/audio.luau` owns `lunette/audio` version 1 and its read-only service types. `@lunette-plugins/audio` provides it and requires only `lunette/frame`. Loading or activating the provider opens no capture. `service:open(owner, source)` acquires a reader for `{ kind = 'system' }` or `{ kind = 'process', process = handle }`. The handle is a registered session `Process`, not a PID or application name. `service:processes()` lists live logical processes with display labels and optional cached source status without acquiring readers.

A reader exposes `source`, `snapshot()`, and idempotent `close()`. Its owner releases it on deactivation. Several owners reading one source share capture and the same frame publication. Closing one reader leaves the other readers active. The provider polls in the `input` update phase before consumers. A snapshot contains `source`, `state`, `frameGeneration`, and `blocks`. The frame generation identifies publication, while each block's `generation` identifies the capture stream. Consumers read a snapshot repeatedly without draining it and use block sequence and generation to avoid processing retained data twice.

Each block contains `sequence`, `generation`, `frameCount`, `sampleRate`, `channels`, `startFrame`, `timing`, `gap`, `droppedFrames`, and `copySamples()`. The copied buffer contains `frameCount * channels` little-endian F32 samples, or `frameCount * channels * 4` bytes. `frameCount` counts complete stereo frames. `startFrame` is cumulative sample time within the stream generation, and `timing = 'sample-frames'` states that it is not a native capture timestamp. Consumers handle state changes and discontinuities explicitly rather than treating an empty publication as silent PCM.

## Lua analysis

Analysis, source-selection policy, smoothing, and visual response belong to Lua. The reusable audio and analysis providers remain independent of the backdrop. Analysis follows sample time and publishes completed FFT hops rather than render-frame estimates. Discontinuities reset carry and onset history. Source changes crossfade response features, not PCM. Per-band onsets separate percussive events by register, so a kick, a snare, and a hi-hat register in different bands. Beat and tempo detection are outside the contract.

`lua/lunette-contracts/audio-analysis.luau` owns `lunette/audio-analysis` version 1. `@lunette-plugins/audio-analysis` requires `lunette/frame` and `lunette/audio`. `service:open(owner, source, options?)` returns `{ kind = 'success', reader }`, `{ kind = 'invalid-options', detail }`, or `{ kind = 'capacity-exceeded', detail }`. Only `size` and `hop` are options. Sizes are 512, 1024, or 2048 samples, and hop is a quarter or half of the size. Omitted options resolve to size 2048 and hop 512. Equal source/profile readers share storage and work. At most two distinct profiles per source and eight per runtime are active. Reader ownership and idempotent close follow the raw-audio contract.

An analysis snapshot contains `source`, `profile`, `state`, `frameGeneration`, optional stream `generation`, optional `endFrame`, `gap`, optional `gapReason`, `droppedFrames`, `hops`, and optional `latest`. Snapshot `endFrame` is the exclusive cumulative end of the last processed PCM block within `generation`, including blocks that complete no hop. It is absent before the first processed block and remains unchanged when no new PCM arrives. Steady values contain `generation`, exclusive `endFrame`, `rms`, `peak`, `bassPower`, `midPower`, `treblePower`, and an eight-band `spectrum`. Each hop adds `flux`, `onset`, `bassOnset`, `midOnset`, and `trebleOnset`. A consumer computes a hop's sample-time delivery age from the snapshot and hop end positions only when their stream generations match. `latest` contains the last completed steady values in uninterrupted active history, with no flux or onset impulse. State loss and analysis resets clear `latest` until a fresh complete window. An active source can therefore have no `latest`. Continuous zero-hop publications retain steady values but never replay an onset. Consumers retain publications without mutating them.

The periodic Hann transform integrates stereo-averaged one-sided bin powers. Bin centres select bass from 30 Hz inclusive to 250 Hz exclusive, mid from 250 Hz inclusive to 2000 Hz exclusive, and treble from 2000 Hz inclusive to 10000 Hz exclusive. Power normalisation is `abs(FFT)^2 / (N * sum(window^2))`, doubled except at DC and Nyquist. RMS and peak use the complete unweighted stereo window. Flux sums positive square-root bin-power changes within the bands and divides by the previous magnitude sum with a 0.001 floor. Flux clamps to 0 through 1 and is zero below RMS 0.001 and on the first window after reset. Onset is `clamp((flux - 0.08) / 0.24, 0, 1)`. The spectrum's eight band powers have upper edges at 60, 120, 250, 500, 1000, 2000, 4000, and 10000 Hz above the 30 Hz floor. The coarse edges are spectrum edges, so spectrum bands 1 to 3 sum to bass, 4 to 6 to mid, and 7 and 8 to treble. A band with no bin centre at the profile's size, such as 30 to 60 Hz at size 512, has zero power. Band flux restricts the flux sums to one coarse band and divides by the largest of that band's previous magnitude sum, a tenth of the full-band previous magnitude sum, and 0.001. The full-band share keeps noise in a quiet band from registering as an event. Band onset is `clamp((bandFlux - 0.3) / 0.4, 0, 1)`. A single band's flux rests higher than the full-band flux under steady noise, which reaches about 0.35 in the mid band, so the band threshold is higher. The contract's comments and the pure analysis modules own these definitions.

Per-frame analysis accepts at most 12,000 frames and publishes at most 94 hops. Generation changes, sequence or sample-time discontinuity, capacity loss, invalid samples, and source-state interruptions reset carry, onset history, and the latest steady values. Gap metadata reports the reason and discarded frames. `examples/audio-backdrop/meter.luau` demonstrates raw and feature readers without importing a backdrop module. Its tests run the real providers without the desktop, a GPU, playback, or a live PipeWire server.

## Source-selection policy

The desktop backdrop base requires only `lunette/frame`. A definition-local factory holds its runtime controls, while optional children acquire audio, observe attention, and render controls through their own required contracts. Audio or analysis loss removes reactivity without withdrawing the environment. Panel or surface loss stops automatic selection, and UI or menu loss withdraws controls. An independent consumer does not require any of these backdrop children.

`sourceMode` is `system`, `application`, or `attention`. System mode reads the current default output mix. Application mode retains a selected live session process handle. Attention mode waits for dwell on an eligible window before selecting its process. Selection uses a supported eye-gaze ray or the tracked head ray, observes the nearest offered surface, and does not change focus or deliver input. Opening the controls freezes attention selection. Silence, unavailable attribution, and ended processes preserve the selected identity rather than selecting the system mix.

Runtime choices survive optional-provider reactivation while their configured values stay unchanged. They end at source reload and are not persisted. No process handle, PID, or application label is serialized as a source preference. `lua/lunette-plugins/desktop/backdrop/config.luau` owns configured defaults and bounds; the selection and child modules own the policy. [Desktop configuration](../guide/desktop-configuration.md#audio-backdrop) describes the controls.

## Deferred spatial routing

Spawned applications play audio through PipeWire to the default sink, unrelated to their panel's position. LÖVR bundles Steam Audio (`deps/phonon`), which provides HRTF spatialisation with occlusion, and every panel's pose is known. Future routing may redirect a process's playback to a `lovr.audio` source at the panel's pose. Spatialisation, falloff, and per-application policy belong to Lua. A flat passthrough mode remains necessary for ambient stereo.

Routing depends on instance-safe process attribution ([Compositor](compositor.md#attribution)). Non-routing capture does not implement routing or change where applications are heard.

## Acceptance

Live acceptance remains pending. A recorded operator check names the host distribution, PipeWire and compatibility-server versions, XR backend, headset, and test date. No automated result supplies these facts. The checks use generated tones or other operator-controlled signals without bundling copyrighted audio.

The capture check covers native PipeWire and PulseAudio-compatible playback, several playback nodes belonging to one logical process, pending spawn, process exit, sink changes, server restart, permission denial, attribution failure, and provider or source reload. It compares the host graph before capture, while readers are active, and after the last reader closes. Original playback links, the default sink, device volume, and audible playback remain unchanged. Two independent consumers share one source, and releasing either leaves the other active. Retained publications and copied buffers remain valid. Loss, generation changes, and attribution provenance appear in diagnostics.

Headset acceptance separately checks appearance, comfort, stereo presentation, tracking loss, enable and disable transitions, and frame-time comparisons at each quality. Offscreen raster tests and logic-headless plugin tests do not establish these properties. Neither capture nor headset acceptance is recorded as complete until the operator records the observations.

## Decisions

Capture and routing have separate contracts. The backdrop and independent analysis consumers need PCM without changing playback. Spatial routing has additional policy and host-graph risks and remains deferred.

Stereo downmix is explicit at the public capture boundary. PipeWire performs mixing and conversion so independently scheduled application callbacks are not summed in Lua or on the frame thread.

Audio and analysis have neutral contracts independent of the backdrop. Per-owner readers share capture and profile work without allowing one consumer to drain or mutate another consumer's publication. Requiring the visual consumer to obtain reusable features was rejected because independent plugins must work without it.

Application choice holds the exact session process instance and does not fall back on silence or unavailable attribution. Application-name and PID-only selection were rejected because names are ambiguous and PID reuse changes identity. Persistent source preferences remain deferred because a process handle cannot cross sessions.

Capture verification uses deterministic project-owned fakes and operator-driven live PipeWire checks. A private-server integration harness is excluded. Fake graph tests establish planned operations, not actual host linking, mixing, playback preservation, or cleanup.

## Known gaps

Live PipeWire graph acceptance and actual headset appearance, comfort, stereo presentation, and frame-time comparisons remain pending until recorded operator checks pass. Automated capture and raster tests do not establish these properties.

PulseAudio-compatible process metadata is not a security boundary. Restricted process observation, PID namespaces, proxies, and sandboxing may prevent attribution. These sources remain unavailable rather than selecting unrelated audio.

## Deliberately left open

Spatial playback routing, microphone capture, beat/BPM tracking, persistent source preferences, and a catalog of visual effects are not implemented by non-routing capture.
