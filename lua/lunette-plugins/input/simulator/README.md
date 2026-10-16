# Simulator

Drives the simulated head from the desktop window while the headset has no session, in place of LÖVR's built-in simulator. Dragging with the look button, the secondary button by default, turns the head by the configured sensitivity. While the button is held, W, A, S, and D move the head along its view, Q and E move it up and down, shift moves faster, and control moves slower. Movement needs the button held so that typing into a focused window does not move the head.

The primary button belongs to the [mouse pointer](../mouse-pointer/README.md), which aims through the window's cursor in the simulator, so a click presses what is under the cursor. The simulated hands are not driven. With the plugin disabled, LÖVR's simulator runs instead: it turns the head with a primary-button drag and points the left hand at the cursor, with the secondary button as its trigger.

The plugin does nothing while a headset session runs.

[Options](config.luau) · [Frame contract](../../../lunette-contracts/frame.luau)
