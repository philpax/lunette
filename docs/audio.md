# Audio

**Deferred past v1, specified now.** Nothing here blocks a usable window manager, but the design constraint it imposes affects process handling, so it's worth knowing about while that's being built.

## The idea

Applications we spawn play audio through PipeWire to your default sink, exactly as they would on your desktop: flat, stereo, centred in your head, unrelated to where the panel is.

LÖVR bundles Steam Audio (`deps/phonon`), so it has real HRTF spatialisation with occlusion, not simple panning. We know every panel's pose. A video playing on a panel to your left should sound like it's to your left, and a terminal bell should come from the terminal.

## The mechanism

**Native:** enumerate a process's PipeWire nodes by pid, redirect them away from the default sink, and hand Lua a live PCM stream.

**Lua:** pipe that stream into a `lovr.audio` source parented to the panel's pose. Spatialisation, falloff, and per-application policy are `mullion`'s business.

This reuses the process identity machinery from [Compositor](compositor.md#attribution) — the pid plus auth-key attribution needs to be a first-class concept rather than a private detail, so audio can ask "which nodes belong to this process handle".

## Defaults

**Spatialisation is on by default**, with an easy opt-out per application surfaced as a button or menu item in whatever framing the default config offers.

A **flat passthrough mode always exists**. Spatialising a video player is the point; spatialising your music player is charming for about four minutes, and then you want ambient stereo.

## Out of scope

Microphone and input capture *into* spawned applications. Voice chat in a VR app running inside lunette is not a problem we're solving.

## Why it's deferred

PipeWire node routing has a long tail of quirks, doubly so with per-application sinks, and none of it is needed to put a terminal on a wall. It's specified because it's the strongest argument that this is a spatial computing environment rather than a screen-sharing app, and because deferring it shouldn't mean discovering later that process identity was built in a way that makes it awkward.
