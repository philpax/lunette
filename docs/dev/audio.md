# Audio

## Non-routing capture

Native capture exposes the system output mix or an existing session process. It adds monitor streams and lunette-owned mixing links without changing application-to-device links, the default sink, or device volume. Capture never opens a microphone or substitutes another source after an outage. Spatial routing remains a separate deferred feature.

`crates/lunette-capture/src/audio/` owns capture mechanism and its source/state vocabulary. The public PCM boundary is 48,000 Hz, interleaved stereo F32. PipeWire performs rate conversion and stereo downmix before this boundary. The stream requests and validates the negotiated format. A rejected or different format reports `unsupported-format`; it is never reinterpreted as stereo. Lua sample copies encode each F32 little-endian regardless of host endianness. One frame contains two samples.

A source descriptor is a closed union of the system mix and a session `Process` handle. `lunette.processes()` lists registered processes, including adopted clients. `window.process` associates a window with its registered process when attribution is available. Lua cannot select a raw PID or adopt an arbitrary host process. Display names do not establish identity.

### Process attribution

The compositor records a PID and an opaque instance discriminator from the Linux process start time when registering a managed or adopted process. Exact PID matching and adopted liveness compare the recorded instance with a current observation. Observation failure does not transfer identity to a replacement process. A spawned child remains owned, its output remains collected, and it remains reaped even if its identity cannot be read.

An audio attribution request carries a request identifier, PipeWire connection generation, node serial, and observed process instance. The compositor resolves a direct live instance first, then the inherited authentication token of a spawned descendant. It observes the candidate instance before reading the environment and again afterward. Both observations must equal the requested instance, and the matched logical root must remain live. The token never leaves the compositor. Exit, access denial, or identity change produces an unresolved result. A pending reply is discarded if its request, source, node, or connection identity changed. The same node is not retried against a replacement PID instance.

Native PipeWire clients report their PID through `pipewire.sec.pid`. PulseAudio-compatible playback may instead report `application.process.id`. This second assertion is application metadata, not authentication. It requires corroboration with the current OS instance and the logical-process resolver. The public status preserves this provenance. Missing, ambiguous, inaccessible, or namespace-mismatched attribution remains unresolved. Automatic selection uses only a single resolved logical process and never uses application-name matching.

### Source state

The state union contains `starting`, `active`, `idle`, `unavailable`, and `ended`. `active` may contain silence. `idle` means no playback node is present. `unavailable` carries a closed reason and diagnostic detail. Reasons include no server, no default sink, invalid default metadata, permission denied, unsupported format, unresolved attribution, capacity exceeded, and graph failure. Recoverable outages preserve the source identity and may return to `starting` or `active`. `ended` means a closed handle or an invalid or ended process.

The public `Process.dead` field remains true before a queued spawn appears in a snapshot. Capture tracks pending, live, and failed-or-ended registration separately. A valid pending process stays `starting` until the spawn succeeds or produces a terminal outcome. A missing snapshot is not a spawn failure. An unreadable managed or adopted instance reports attribution unavailable instead of permitting a PID-only match.

### Publication and ownership

Capture is lazy and shared per source within a session. The first reader opens the stream; the last reader releases it and its owned graph objects. The default source limit is eight. Each process source mixes all attributed playback nodes into one internal stereo monitor. Original playback links remain intact. A silent selected process remains selected.

The frame thread publishes immutable complete PCM blocks once at the frame boundary. Repeated snapshots in the same frame do not drain queues. Retained blocks remain valid across frames. `copySamples()` returns a fresh Luau buffer, so consumers cannot alter native PCM or another consumer's copy. Blocks carry sequence, stream generation, frame count, format, sample-time position, and gap information. Cumulative sample timing is labelled as such when native timestamps are absent. Stream-generation changes reset timing.

Queues retain at most 250 ms of stereo frames. Publication snapshots committed occupancy and consumes only packets present at that cutoff, with a limit of 12,000 frames and 64 packets per source. Producers cannot extend one publication by replenishing the queue. Packet loss and deliberate history discard produce explicit gaps. Process callbacks use preallocated storage, publish samples and metadata atomically, and perform no allocation, logging, Lua calls, blocking locks, or waits.

The worker tracks the `default` metadata object's `default.audio.sink` name and the live sink's serial and connection generation. System capture targets that sink's monitor with fallback and implicit reconnection disabled. Each process source owns one non-autoconnecting `Stream/Input/Audio` null-sink adapter and non-lingering additive links from every attributed playback node. Explicit channel mapping folds left channels to FL, right channels to FR, and centre, mono, and LFE channels to both at unity gain. Unknown channel positions make the whole source unavailable. Capture validates the converted monitor's negotiated stereo format before accepting PCM. Registry observations and graph operations cross project-owned interfaces; recording implementations exercise the same reconciliation driver without opening a host connection.

## Lua analysis

Analysis, source-selection policy, smoothing, and visual response belong to Lua. The reusable audio and analysis providers remain independent of the backdrop. Analysis follows sample time and publishes completed FFT hops rather than render-frame estimates. Discontinuities reset carry and onset history. Source changes crossfade response features, not PCM. Beat and tempo detection are outside the contract.

## Deferred spatial routing

Spawned applications play audio through PipeWire to the default sink, unrelated to their panel's position. LÖVR bundles Steam Audio (`deps/phonon`), which provides HRTF spatialisation with occlusion, and every panel's pose is known. Future routing may redirect a process's playback to a `lovr.audio` source at the panel's pose. Spatialisation, falloff, and per-application policy belong to Lua. A flat passthrough mode remains necessary for ambient stereo.

Routing depends on instance-safe process attribution ([Compositor](compositor.md#attribution)). Non-routing capture does not implement routing or change where applications are heard.

## Decisions

Capture and routing have separate contracts. The backdrop and independent analysis consumers need PCM without changing playback. Spatial routing has additional policy and host-graph risks and remains deferred.

Stereo downmix is explicit at the public capture boundary. PipeWire performs mixing and conversion so independently scheduled application callbacks are not summed in Lua or on the frame thread.

Capture verification uses deterministic project-owned fakes and operator-driven live PipeWire checks. A private-server integration harness is excluded. Fake graph tests establish planned operations, not actual host linking, mixing, playback preservation, or cleanup.

## Known gaps

Live PipeWire graph acceptance and actual headset appearance, comfort, stereo presentation, and frame-time comparisons remain pending until recorded operator checks pass. Automated capture and raster tests do not establish these properties.

PulseAudio-compatible process metadata is not a security boundary. Restricted process observation, PID namespaces, proxies, and sandboxing may prevent attribution. These sources remain unavailable rather than selecting unrelated audio.

## Deliberately left open

Spatial playback routing, microphone capture, beat/BPM tracking, persistent source preferences, and a catalog of visual effects are not implemented by non-routing capture.
