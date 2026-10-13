# Native audio capture

## Non-routing capture

Capture exposes the system output mix or a registered session process. It adds monitor streams and owned mixing links without changing application playback links, the default sink, or device volume. It never opens a microphone or substitutes a source after an outage. The [native reader boundary](lua-api.md#audio-capture) and [audio provider](../../../lua/lunette-plugins/audio/README.md) specify ownership; signal processing belongs in Lua.

`crates/lunette-capture/src/audio/` owns the mechanism. The PCM boundary is 48,000 Hz, interleaved stereo F32. PipeWire converts and downmixes before publication. Capture validates negotiation and rejects incompatible formats rather than reinterpreting them. Lua copies encode F32 little-endian.

### Process attribution

A source names a logical session process, never a raw PID or display name. Attribution pins the OS process instance, PipeWire connection generation, and node serial. Resolution accepts a live registered instance or corroborated inherited spawn token. The compositor observes the instance before and after reading its environment; replacement, access denial, or exit leaves attribution unresolved. Tokens stay in the compositor.

Native PipeWire PID assertions and PulseAudio-compatible application metadata have different provenance. A Pulse compatibility server's PID does not identify its client. Application metadata requires OS-instance and logical-process corroboration and is not authentication. Missing, ambiguous, inaccessible, or namespace-mismatched identity remains unresolved; name matching never substitutes for it.

Replies apply only to their original request and identities. Expired requests can retry against the same pinned instance, but a confirmed replacement stays blocked for that node lifetime. Recovery depends on continued worker ticks, queue progress, and process observation; it has no unconditional time bound.

### Source state and publication

A source can be starting, active, idle, unavailable, or ended. Active PCM may be silent. A process is idle only when no attributed playback exists and no unresolved node could belong to it. Recoverable outages retain source identity. A pending spawn stays starting; a missing frame snapshot alone does not end it. Ended sources never select replacements.

Readers share capture per source. The first opens it, and the last releases its owned graph objects. Process capture mixes attributed nodes through additive links; original playback links remain intact. System capture follows the observed default sink with implicit fallback disabled. Registry info properties are authoritative only when their change mask includes properties; applying empty state-update dictionaries would erase sink identity.

Frame publication produces immutable complete blocks. Repeated reads in one frame do not drain again, and retained blocks survive reader close. Copies cannot alter native PCM or another reader's copy. Stream generations reset timing; sample positions are cumulative when native timestamps are absent. Loss and discarded history report gaps.

Queues and publication work are bounded. Publication consumes only packets committed at its cutoff, so replenishment cannot extend frame-thread work. Audio callbacks use preallocated storage and perform no allocation, logging, Lua calls, blocking locks, or waits. Exact capacity bounds belong in the implementation.

## Deferred spatial routing

Applications currently play through the host's default sink, independently of panel pose. Routing to spatialized LÖVR audio would change playback and adds attribution and host-graph risks. Position, falloff, and passthrough policy belong in Lua. Non-routing capture does not implement spatial routing, microphone capture, or beat tracking.

## Acceptance

Live PipeWire and headset acceptance remains pending. Deterministic graph fakes establish planned operations, not host linking, mixing, playback preservation, or cleanup. A private-server harness is not part of the verification strategy.

An operator record must name the distribution, PipeWire and compatibility-server versions, XR backend, headset, and date. Checks use operator-controlled signals. They must establish native and Pulse-compatible attribution, multiple playback nodes per logical process, spawn and exit behavior, recovery across sink and server changes, permission and attribution failures, and reload cleanup.

Graph comparisons before capture, during shared use, and after the final reader closes must show unchanged playback links, sink, volume, and audible playback. Independent readers must survive each other's release. Diagnostics must expose loss, generation changes, and attribution provenance. Retained blocks and copied buffers must remain valid. Automated results do not close these requirements.
