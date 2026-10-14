# Environment

Environment renders background content and guidance without owning foreground panels or input policy.

## Plugin leaves

- [Backdrop](backdrop/README.md) draws a head-centred sky and aurora. Optional audio response and controls do not determine whether the environment remains available.
- [Empty-desktop hint](empty-desktop-hint/README.md) draws guidance while no panels are registered, including hidden panels.

The [frame contract](../../lunette-contracts/frame.luau) orders drawing. The [panels contract](../../lunette-contracts/panels.luau) defines the hint's occupancy check. The [theme contract](../../lunette-contracts/theme.luau) supplies appearance. Optional backdrop response uses the [audio](../../lunette-contracts/audio.luau) and [audio-analysis](../../lunette-contracts/audio-analysis.luau) contracts.

[Shipped plugins and public imports](../README.md)
