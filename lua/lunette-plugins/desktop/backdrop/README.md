# Desktop backdrop

Draws a head-centred sky and aurora before foreground content. It works without audio; optional audio response, attention selection, and controls can fail without removing the environment.

System mode reads the default output mix without changing routing or volume. Application mode selects an exact registered process; silence or unavailable attribution does not fall back to system audio. Attention mode uses gaze, or the head ray when eye tracking is unsupported, without changing focus or delivering input. Tracking loss retains the last selection.

The Appearance panel pauses automatic selection while open. Runtime choices reset on source reload and process selections do not persist across sessions. Unavailable audio fades toward zero.

[Options](config.luau) · [Example](../../../../examples/audio-backdrop/main.luau) · [Audio limits and pending live acceptance](../../../../docs/dev/audio.md)

Headset appearance, comfort, stereo presentation, and frame-time acceptance remain pending. Some OpenXR runtimes lack visibility events, so the environment may keep rendering until disabled.
