# Audio

Spatial audio is specified but not implemented. It constrains process handling, so the constraint is recorded here.

## Design

Spawned applications play audio through PipeWire to the default sink, unrelated to their panel's position. LÖVR bundles Steam Audio (`deps/phonon`), which provides HRTF spatialisation with occlusion, and every panel's pose is known. A video on a panel to the user's left should sound as if it comes from there.

The native layer enumerates a process's PipeWire nodes by pid, redirects them away from the default sink, and hands Lua a live PCM stream. Lua feeds that stream into a `lovr.audio` source placed at the panel's pose. Spatialisation, falloff, and per-application policy are Lua policy.

Audio routing depends on process attribution ([Compositor](compositor.md#attribution)): audio code must be able to ask which PipeWire nodes belong to a process handle, so the pid and token attribution has to remain a first-class part of the process registry.

Spatialisation is on by default, with a per-application opt-out offered by the default configuration. A flat passthrough mode always exists, because ambient stereo suits music better than a fixed source.

## Deliberately left open

Microphone and input capture for spawned applications are not addressed.

The feature is deferred because PipeWire node routing has many quirks and none of it is needed for a usable window manager.
