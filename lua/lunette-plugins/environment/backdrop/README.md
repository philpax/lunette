# Desktop backdrop

Draws a head-centred sky and aurora before foreground content. It works without audio; optional audio response, attention selection, and controls can fail without removing the environment.

The audio response retains left and right energy in each frequency band. Sustained activity follows stereo balance relative to the head direction. Transient responses start toward their channel's side and retain their position during head turns. Centred and mono signals remain balanced. Frequency bands affect distinct curtain heights and textures. A smooth response curve preserves strength differences in loud passages without raising silence.

System mode reads the default output mix without changing routing or volume. Application mode selects an exact registered process; silence or unavailable attribution does not fall back to system audio. Attention mode uses gaze, or the head ray when eye tracking is unsupported, without changing focus or delivering input. Tracking loss retains the last selection.

Active beat responses finish before their animation slots are reused. A full frequency-band pool skips new visual beats without interrupting active responses in any band. Audio discontinuities reset invalid response history.

The Appearance panel pauses automatic selection while open. Runtime choices reset on source reload and process selections do not persist across sessions. Unavailable audio fades toward zero.

[Options](config.luau) · [Example](../../../../examples/audio-backdrop/main.luau) · [Audio limits and pending live acceptance](../../../../docs/development/native/audio.md)

Headset appearance, comfort, stereo-audio response, binocular presentation, and frame-time acceptance remain pending. Some OpenXR runtimes lack visibility events, so the environment may keep rendering until disabled.
