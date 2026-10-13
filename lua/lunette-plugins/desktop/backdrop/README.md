# Desktop backdrop

The desktop backdrop draws a head-centred sky and aurora before foreground scene content. It continues to render without audio, and its audio response, attention selection, and controls attach as independent children.

The module is `@lunette-plugins/desktop/backdrop`. Its shipped desktop entry id is `desktop/backdrop`. The base consumer requires `lunette/frame`. Its optional response child requires `lunette/audio-analysis` and `lunette/frame`; the audio provider is a dependency of analysis. Its optional process-status child requires `lunette/audio` and `lunette/frame`. Its optional attention child requires `lunette/frame`, `lunette/panels`, and `lunette/surfaces`. Its optional controls child requires `lunette/frame`, `lunette/ui`, and `lunette/menu`.

The module exports `definition`, `define(config)`, and `create(config?, attach?)`. The `attach` callback receives the base consumer's context, backdrop model state, controls, and resolved settings during activation. The backdrop schema and defaults in [`config.luau`](config.luau) are the source of truth for `enabled`, `reactive`, `sourceMode`, `dwell`, `fadeDuration`, `attackDuration`, `releaseDuration`, `crossfadeDuration`, `recoveryDuration`, `distance`, `quality`, `brightness`, `response`, `motion`, `palette`, and `diagnostic`.

See [rendering](docs/rendering.md) for geometry, rendering, graphics checks, and graphics acceptance gaps; [audio response](docs/audio-response.md) for the mapping from analysis features to visual motion; and [source selection](docs/source-selection.md) for system, application, and attention selection. The [audio-backdrop example](../../../../examples/audio-backdrop/main.luau) composes the shipped desktop with an independent meter. The [backdrop tests](tests/) cover source behavior, response, resources, and lifecycle. `make check-graphics` exercises the production renderer on lavapipe.

## Runtime controls

When the optional controls child is available, the session menu's Appearance group contains a Backdrop action. Its VR panel changes enabled state, audio reactivity, source mode, application selection, response and motion presets, and the diagnostic view. Opening the panel freezes attention selection. Closing it resumes attention selection.

Runtime choices survive child or provider reactivation while the corresponding configured values stay unchanged. They do not persist across source reload. The backdrop does not serialize process handles, PIDs, or application labels.

## Known gaps

Live PipeWire graph acceptance and headset appearance, comfort, stereo presentation, and frame-time comparisons remain pending. Offscreen raster tests do not establish those properties. Unsupported OpenXR visibility events can leave the main-session visibility observation false, so the background can remain eligible to render. See [backdrop rendering gaps](docs/rendering.md#known-gaps) and [audio acceptance](../../../../docs/dev/audio.md#acceptance).