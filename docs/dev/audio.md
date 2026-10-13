# Audio

## Non-routing capture

Native capture exposes the system output mix or an existing session process. It adds monitor streams and lunette-owned mixing links without changing application-to-device links, the default sink, or device volume. Capture never opens a microphone or substitutes another source after an outage. Spatial routing remains a separate deferred feature.

`crates/lunette-capture/src/audio/` owns capture mechanism and its source/state vocabulary. The public PCM boundary is 48,000 Hz, interleaved stereo F32. PipeWire performs rate conversion and stereo downmix before this boundary. The stream requests and validates the negotiated format. A rejected or different format reports `unsupported-format`; it is never reinterpreted as stereo. Lua sample copies encode each F32 little-endian regardless of host endianness. One frame contains two samples.

A source descriptor is a closed union of the system mix and a session `Process` handle. `lunette.processes()` lists registered processes, including adopted clients. `window.process` associates a window with its registered process when attribution is available. Lua cannot select a raw PID or adopt an arbitrary host process. Display names do not establish identity.

### Process attribution

The compositor records a PID and an opaque instance discriminator from the Linux process start time when registering a managed or adopted process. Exact PID matching and adopted liveness compare the recorded instance with a current observation. Observation failure does not transfer identity to a replacement process. A spawned child remains owned, its output remains collected, and it remains reaped even if its identity cannot be read.

An audio attribution request carries a request identifier, PipeWire connection generation, node serial, and observed process instance. The compositor resolves a direct live instance first, then the inherited authentication token of a spawned descendant. It observes the candidate instance before reading the environment and again afterward. Both observations must equal the requested instance, and the matched logical root must remain live. The token never leaves the compositor. Exit, access denial, or identity change produces an unresolved result. A pending reply is discarded if its request, source, node, or connection identity changed. The same node is not retried against a replacement PID instance.

A pending attribution delivery expires after the capture worker's injected retry interval, 500 ms by default. The next eligible bounded worker tick observes the same pinned process instance and issues a fresh request identifier. A dropped request or reply can therefore recover without replacing the node or process. Expired replies cannot complete a later attempt. Confirmed PID-instance replacement remains blocked for that node lifetime. Queue recovery, continued worker ticks, and process observation are prerequisites; a permanently full queue or stalled inspector has no finite recovery guarantee.

Native PipeWire clients report their PID through `pipewire.sec.pid`. The compatibility server marks Pulse clients with `client.api = 'pipewire-pulse'`; application display names do not identify that protocol. PulseAudio-compatible playback may instead report `application.process.id`. A Pulse client's `pipewire.sec.pid` is the compatibility server's own PID, so a Pulse stream without `application.process.id` has no PID assertion and stays unresolved. This second assertion is application metadata, not authentication. It requires corroboration with the current OS instance and the logical-process resolver. The public status preserves this provenance. Missing, ambiguous, inaccessible, or namespace-mismatched attribution remains unresolved. Automatic selection uses only a single resolved logical process and never uses application-name matching.

### Source state

The state union contains `starting`, `active`, `idle`, `unavailable`, and `ended`. `active` may contain silence. `idle` means no playback node attributed to the process is present, and no unattributed playback node may belong to it. A playback node may belong to the process until the compositor answers, for the node's current PID assertion and process instance, that the instance belongs to no process. A node without a PID assertion, or whose answer is pending or blocked, may belong to any process and makes a silent process source `unavailable` with `unresolved-attribution`. A retry keeps the previous answer until the next one arrives. `unavailable` carries a closed reason and diagnostic detail. Reasons include no server, no default sink, invalid default metadata, permission denied, unsupported format, unresolved attribution, capacity exceeded, and graph failure. Recoverable outages preserve the source identity and may return to `starting` or `active`. `ended` means a closed handle or an invalid or ended process.

The public `Process.dead` field remains true before a queued spawn appears in a snapshot. Capture tracks pending, live, and failed-or-ended registration separately. A valid pending process stays `starting` until the spawn succeeds or produces a terminal outcome. A missing snapshot is not a spawn failure. An unreadable managed or adopted instance reports attribution unavailable instead of permitting a PID-only match.

### Publication and ownership

Capture is lazy and shared per source within a session. The first reader opens the stream; the last reader releases it and its owned graph objects. The default source limit is eight. Each process source mixes all attributed playback nodes into one internal stereo monitor. Original playback links remain intact. A silent selected process remains selected.

The frame thread publishes immutable complete PCM blocks once at the frame boundary. Repeated snapshots in the same frame do not drain queues. Retained blocks remain valid across frames. `copySamples()` returns a fresh Luau buffer, so consumers cannot alter native PCM or another consumer's copy. Blocks carry sequence, stream generation, frame count, format, sample-time position, and gap information. Cumulative sample timing is labelled as such when native timestamps are absent. Stream-generation changes reset timing.

Queues retain at most 250 ms of stereo frames. Publication snapshots committed occupancy and consumes only packets present at that cutoff, with a limit of 12,000 frames and 64 packets per source. Producers cannot extend one publication by replenishing the queue. Packet loss and deliberate history discard produce explicit gaps. Process callbacks use preallocated storage, publish samples and metadata atomically, and perform no allocation, logging, Lua calls, blocking locks, or waits.

The worker tracks the `default` metadata object's `default.audio.sink` name and the live sink's serial and connection generation. Node, client, and port properties come from the registry global and from info events. An info event carries authoritative properties only when its change mask includes properties; PipeWire sends an empty dictionary with a state or parameter change, and the worker ignores it. Every worker tick plans the graph again from the current observations, so the system source recovers without reopening once the default sink names a live sink. System capture targets that sink's monitor with fallback and implicit reconnection disabled. Each process source owns one non-autoconnecting `Stream/Input/Audio` null-sink adapter and non-lingering additive links from every attributed playback node. Explicit channel mapping folds left channels to FL, right channels to FR, and centre, mono, and LFE channels to both at unity gain. Unknown channel positions make the whole source unavailable. Capture validates the converted monitor's negotiated stereo format before accepting PCM. Registry observations and graph operations cross project-owned interfaces; recording implementations exercise the same reconciliation driver without opening a host connection.

## Lua providers

`lua/lunette-contracts/audio.luau` owns `lunette/audio` version 1 and its read-only service types. The provider opens no capture until a reader is acquired. A reader belongs to its owner; readers for the same source share capture and one immutable frame publication. Closing one reader does not affect other readers, and repeated snapshots do not drain publications. A block's `copySamples()` returns a fresh little-endian F32 buffer. Its sequence, stream generation, frame count, sample position, and gap metadata let consumers handle retained data and discontinuities without treating missing PCM as silence. The [audio reader specification](../../lua/lunette-plugins/audio/docs/readers.md) records the reader and publication fields. [Audio provider](../../lua/lunette-plugins/audio/README.md) documents the plugin entry and source forms.

The raw PCM boundary is 48,000 Hz interleaved stereo F32. Publications retain at most 250 ms of stereo frames; one publication consumes at most 12,000 frames and 64 packets per source. The default source limit is eight. Capture ownership, format validation, timing, and native graph behavior remain specified under [non-routing capture](#non-routing-capture).

## Lua analysis

`lua/lunette-contracts/audio-analysis.luau` owns `lunette/audio-analysis` version 1. `service:open(owner, source, options?)` returns `{ kind = 'success', reader }`, `{ kind = 'invalid-options', detail }`, or `{ kind = 'capacity-exceeded', detail }`. Only `size` and `hop` are options. Equal source and profile readers share work. The contract accepts window sizes 512, 1024, or 2048 samples and quarter- or half-window hops; defaults are 2048 and 512. At most two distinct profiles per source and eight per runtime are active. Per-frame analysis accepts at most 12,000 frames and publishes at most 94 hops. Reader ownership and idempotent close follow the raw-audio contract.

An analysis snapshot contains `source`, `profile`, `state`, `frameGeneration`, optional stream `generation`, optional `endFrame`, `gap`, optional `gapReason`, `droppedFrames`, `hops`, and optional `latest`. Snapshot `endFrame` is the exclusive cumulative end of the last processed PCM block within `generation`, including blocks that complete no hop. It is absent before the first processed block and remains unchanged when no new PCM arrives. Steady values contain `generation`, exclusive `endFrame`, `rms`, `peak`, `bassPower`, `midPower`, `treblePower`, and an eight-band `spectrum`. Each hop adds `flux`, `onset`, `bassOnset`, `midOnset`, and `trebleOnset`. A consumer computes a hop's sample-time delivery age from the snapshot and hop end positions only when their stream generations match. `latest` contains the last completed steady values in uninterrupted active history, with no flux or onset impulse. State loss and analysis resets clear `latest` until a fresh complete window. An active source can therefore have no `latest`. Continuous zero-hop publications retain steady values but never replay an onset. Consumers retain publications without mutating them.

Analysis follows sample time, publishes completed hops, and resets carry and onset history on discontinuity. Beat and tempo detection are outside the contract. [Audio analysis](../../lua/lunette-plugins/audio-analysis/docs/analysis.md) specifies the FFT, window, spectral power, flux, and onset calculations. Its algorithm, thresholds, and rejected alternatives remain there.

## Deferred spatial routing

Spawned applications play audio through PipeWire to the default sink, unrelated to their panel's position. LÖVR bundles Steam Audio (`deps/phonon`), which provides HRTF spatialisation with occlusion, and every panel's pose is known. Future routing may redirect a process's playback to a `lovr.audio` source at the panel's pose. Spatialisation, falloff, and per-application policy belong to Lua. A flat passthrough mode remains necessary for ambient stereo.

Routing depends on instance-safe process attribution ([Compositor](compositor.md#attribution)). Non-routing capture does not implement routing or change where applications are heard.

## Acceptance

Live acceptance remains pending. A recorded operator check names the host distribution, PipeWire and compatibility-server versions, XR backend, headset, and test date. No automated result supplies these facts. The checks use generated tones or other operator-controlled signals without bundling copyrighted audio.

The capture check covers native PipeWire and PulseAudio-compatible playback, several playback nodes belonging to one logical process, pending spawn, process exit, sink changes, server restart, permission denial, attribution failure, and provider or source reload. It compares the host graph before capture, while readers are active, and after the last reader closes. Original playback links, the default sink, device volume, and audible playback remain unchanged. Two independent consumers share one source, and releasing either leaves the other active. Retained publications and copied buffers remain valid. Loss, generation changes, and attribution provenance appear in diagnostics.

## Decisions

Capture and routing have separate contracts. The backdrop and independent analysis consumers need PCM without changing playback. Spatial routing has additional policy and host-graph risks and remains deferred.

Stereo downmix is explicit at the public capture boundary. PipeWire performs mixing and conversion so independently scheduled application callbacks are not summed in Lua or on the frame thread.

Audio and analysis have neutral contracts independent of the backdrop. Per-owner readers share capture and profile work without allowing one consumer to drain or mutate another consumer's publication. Requiring the visual consumer to obtain reusable features was rejected because independent plugins must work without it. [Audio analysis decisions](../../lua/lunette-plugins/audio-analysis/docs/analysis.md#decisions) records why analysis follows sample time and uses the periodic Hann transform, stereo-averaged one-sided powers, and shared spectrum/coarse-band boundaries.

Attribution distinguishes a playback node that cannot belong to a process from one whose owner is unknown. The compositor's answer that an instance belongs to no process is the distinguishing fact, because the worker already obtains it for every node with a PID assertion. Reporting `unresolved-attribution` whenever any playback node in the graph was unattributed was rejected: a host application's stream then made every silent session process look unattributed. The answer holds only for the current assertion and instance, and the worker keeps asking, because the compositor can adopt a process after answering.

Info event properties are applied only when the change mask names them. Treating every info dictionary as authoritative cleared a sink's class and name on each state or parameter change, such as a latency change when another application starts a stream, and the system source then stayed unavailable until a reconnect.

Capture verification uses deterministic project-owned fakes and operator-driven live PipeWire checks. A private-server integration harness is excluded. Fake graph tests establish planned operations, not actual host linking, mixing, playback preservation, or cleanup.

## Known gaps

Live PipeWire graph acceptance remains pending until recorded operator checks pass. Automated capture tests do not establish host linking, mixing, playback preservation, or cleanup.

PulseAudio-compatible process metadata is not a security boundary. Restricted process observation, PID namespaces, proxies, and sandboxing may prevent attribution. These sources remain unavailable rather than selecting unrelated audio.

## Deliberately left open

Spatial playback routing, microphone capture, and beat/BPM tracking are not implemented by non-routing capture.
