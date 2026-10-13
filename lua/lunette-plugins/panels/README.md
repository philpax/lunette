# Panels

Creates window and monitor panels. The [desktop renderer](../desktop/render/README.md) draws them and offers pointer surfaces. Custom source renderers are responsible for their own window child surfaces.

Popups clip to the window panel and cannot receive pointer input outside it. Windows with visible child surfaces render in the scene instead of a composition layer. Granted layers remain rectangular and cannot be seen from behind; scene-rendered panels remain visible from behind.

[Options](config.luau) · [Panel contract](../../lunette-contracts/panels-and-ui.md) · [Shared rendering limits](../../../docs/development/native/rendering.md)
