# Desktop backdrop

The backdrop draws a head-centred sky and aurora before foreground content. It renders without audio; optional children add audio response, process status, attention selection, and controls.

| Part | Requires |
| --- | --- |
| Base environment | `lunette/frame` |
| Audio response | [`lunette/audio-analysis`](../../../lunette-contracts/audio-analysis.luau), `lunette/frame` |
| Process status | [`lunette/audio`](../../../lunette-contracts/audio.luau), `lunette/frame` |
| Attention selection | `lunette/frame`, `lunette/panels`, `lunette/surfaces` |
| Runtime controls | `lunette/frame`, `lunette/ui`, `lunette/menu` |

[Options](config.luau) · [Example](../../../../examples/audio-backdrop/main.luau) · [Source selection](docs/source-selection.md) · [Rendering](docs/rendering.md) · [Audio response](docs/audio-response.md)

When controls are attached, the Appearance panel changes the backdrop and its response. Opening the panel pauses automatic attention selection. Runtime choices last until source reload and do not serialize process identity. Live PipeWire and headset acceptance remain pending; see [rendering gaps](docs/rendering.md#acceptance) and [audio acceptance](../../../../docs/dev/audio.md#acceptance).
