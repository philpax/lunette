# Theme

Provides the session's theme: the lunette palette resolved for the dark or light mode, an accent colour, and the accessibility settings for text scale and high contrast. The accent is guarded rather than rejected: its lightness is adjusted until it has the contrast the palette needs against the panel surface.

The UI host lays out and draws every toolkit panel with this theme, and its `setMode`, `setAccent`, and `setAccessibility` methods change it. Surfaces drawn outside the toolkit, such as the virtual keyboard, the laser, the mouse cursor, and window outlines, read the same theme from this provider. The provider sits below the host, so those surfaces keep their appearance, and the controller rays keep working, while the host is disabled or broken.

The `mode` and `accent` [options](config.luau) choose the starting theme. [Contract](../../../lunette-contracts/theme.luau) · [Palette](private/palette.luau)
