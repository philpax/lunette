# Audio

This feature is deferred past v1 but specified now. Nothing here blocks a usable window manager, but the design constraint it imposes affects process handling, so it is documented while that machinery is built.

## The idea

Applications spawned by lunette play audio through PipeWire to the default sink, exactly as they would on a normal desktop: flat, stereo, centred in the user's head, unrelated to the panel's position.

LÖVR bundles Steam Audio (`deps/phonon`), which provides HRTF spatialisation with occlusion rather than simple panning. Every panel's pose is known to the system. A video playing on a panel to the user's left should sound like it originates there, and a terminal bell should come from the terminal.

## The mechanism

Native layer: enumerate a process's PipeWire nodes by pid, redirect them away from the default sink, and hand Lua a live PCM stream.

Lua: pipe that stream into a `lovr.audio` source parented to the panel's pose. Spatialisation, falloff, and per-application policy belong to Lua policy, not the native layer.

This reuses the process identity machinery from [Compositor](compositor.md#attribution). The pid plus auth-key attribution needs to be a first-class concept rather than a private detail, so audio code can ask which nodes belong to a given process handle.

## Defaults

Spatialisation is on by default, with an opt-out per application surfaced as a button or menu item in whatever framing the default config offers.

A flat passthrough mode always exists. Spatialising a video player serves the point of the feature; spatialising a music player is of limited value beyond an initial demonstration, after which ambient stereo is preferred.

## Out of scope

Microphone and input capture into spawned applications. Voice chat in a VR application running inside lunette is not addressed by this design.

## Why it is deferred

PipeWire node routing has a long tail of quirks, more so with per-application sinks, and none of it is required to put a terminal on a wall. It is specified now because it is the clearest evidence that this is a spatial computing environment rather than a screen-sharing application, and because deferring it should not mean discovering later that process identity was built in a way that makes audio routing awkward.
