# Environment

Environment renders background content and guidance without owning foreground panels or input policy. [Backdrop](backdrop/README.md) draws a head-centred sky and aurora independently of optional audio response and controls. [Empty-desktop hint](empty-desktop-hint/README.md) shows guidance on a UI toolkit panel while no panels are registered, including hidden panels.

The [frame contract](../../lunette-contracts/frame.luau) orders drawing, the [panels contract](../../lunette-contracts/panels.luau) defines occupancy, the [UI host contract](../../lunette-contracts/ui-host.luau) presents the hint, and the [theme contract](../../lunette-contracts/theme.luau) supplies appearance. Optional backdrop response uses the [audio](../../lunette-contracts/audio.luau) and [audio-analysis](../../lunette-contracts/audio-analysis.luau) contracts. [Shipped plugins](../README.md) defines public imports.
