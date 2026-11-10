# Panels

Creates window and monitor panels. The [desktop renderer](../renderer/README.md) draws them and offers pointer surfaces. Custom source renderers are responsible for their own window child surfaces.

Popups clip to the window panel and cannot receive pointer input outside it. Windows with visible child surfaces render in the scene instead of a composition layer. Granted layers remain rectangular and cannot be seen from behind; scene-rendered panels remain visible from behind.

A panel's curve can change at runtime. The surface maps rays to planar source pixels with the shared [curved-surface](../graphics/curved-surface.luau) library, and a commit notifies while a preview does not. A curved window takes a cylinder composition layer only where the headset reports `layerCurve`; otherwise it releases the layer and draws in the scene. The layer, the hit test, and the scene mesh share one half-turn clamp, so a width past the limit wraps once and stays consistent between them. A transform lock refuses pointer grabs, titlebar trigger drags, and two-handed resizes, including size, while owner placement, rules, and restore still apply. The locks are independent: the input lock leaves spatial grabs available, and the transform lock leaves content interactive.

[Options](config.luau) · [Panel contract](../../../lunette-contracts/panels-and-ui.md) · [Shared rendering limits](../../../../docs/development/native/rendering.md)
