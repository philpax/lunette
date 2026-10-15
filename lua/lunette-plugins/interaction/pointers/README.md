# Interaction

Turns pointer samples into surface hits, input events, and spatial grabs. Grip moves a surface relative to the controller; the thumbstick changes reach, and a second pointer can scale it. Starting a grab cancels pointer gestures, so a held trigger must be released before another gesture.

Custom drive hooks can reuse public [picking and scrolling arithmetic](../picking.luau) without importing the pointer implementation. The hook still preserves the contract's capture, cancellation, and delivery guarantees.

[Options](config.luau) · [Contract](../../../lunette-contracts/interaction.luau) · [Input limits](../../../../docs/development/native/input.md#known-gaps)
