# Environment

Environment renders background content without owning foreground panels or input policy. [Backdrop](backdrop/README.md) draws a head-centred sky and aurora independently of optional audio response and controls.

The [frame contract](../../lunette-contracts/frame.luau) orders drawing, the [panels contract](../../lunette-contracts/panels.luau) defines occupancy, and the [UI host contract](../../lunette-contracts/ui-host.luau) supplies appearance. Optional backdrop response uses the [audio](../../lunette-contracts/audio.luau) and [audio-analysis](../../lunette-contracts/audio-analysis.luau) contracts. [Shipped plugins](../README.md) defines public imports.
