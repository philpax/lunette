# Desktop backdrop

Draws a head-centred sky and aurora before foreground content. It works without audio; optional audio response, attention selection, and controls can fail without removing the environment.

The audio response retains left and right energy in each frequency band. Sustained activity follows stereo balance relative to the head direction. Transient responses start toward their channel's side and retain their position during head turns. Centred and mono signals remain balanced. Frequency bands affect distinct curtain heights and textures. A smooth response curve preserves strength differences in loud passages without raising silence.

System mode reads the default output mix without changing routing or volume. Application mode selects an exact registered process; silence or unavailable attribution does not fall back to system audio. Attention mode uses gaze, or the head ray when eye tracking is unsupported, without changing focus or delivering input. Tracking loss retains the last selection.

Active beat responses finish before their animation slots are reused. A full frequency-band pool skips new visual beats without interrupting active responses in any band. Audio discontinuities reset invalid response history.

The Backdrop action in the Appearance menu group opens and closes the control panel, a component mounted on a [UI host](../../ui/host/README.md) panel with the [standard kinds](../../ui/standard/README.md). The controls need both providers and the menu; without them the environment still renders. The panel switches the backdrop and its audio reactivity, selects the audio source, pins the attended application or any listed application, sets response and motion on sliders with named intensity detents, and selects a diagnostic view. The pin button states why it is unavailable. The panel reads the backdrop's choices and the application list through stores, which sample native process, window, and audio state while the panel is open and change only when what the panel shows differs.

The panel's Response section shows what the backdrop responds to, drawn as [volumes](../../ui/host/README.md) that rise out of the panel. The sky model is the backdrop itself in miniature, drawn with the same shaders and aligned with the world rather than the panel. Its ground marks the head, the facing, the onset anchor with the range of facings that keeps it, each sector edge, and each live onset on its band's ring. The skyline stands a column for each channel of each spectrum band, shortened on the quieter side by the stereo balance. A cap marks the analysed level the column moves toward, and older rows recede toward the panel. A caption counts each band's occupied onset slots and the onsets that full pools skipped. The views draw and sample only while the panel is open.

The panel pauses automatic selection while open. Its toggles, source mode, presets, and diagnostic view are [saved settings](../../storage/README.md#saved-settings) of the `desktop/backdrop` entry, so they apply at the next start. A pinned application is a process, so it is not saved. Unavailable audio fades toward zero.

[Options](config.luau) · [Example](../../../../examples/audio-backdrop/main.luau) · [Audio limits and pending live acceptance](../../../../docs/development/native/audio.md)

Headset appearance, comfort, stereo-audio response, binocular presentation, and frame-time acceptance remain pending. Some OpenXR runtimes lack visibility events, so the environment may keep rendering until disabled.
