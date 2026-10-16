# Mouse pointer

Drives one interaction pointer from the mouse while LÖVR's desktop window receives mouse input. The ray starts at the head and points through a cursor held as yaw and pitch offsets from the head's forward direction. With a headset session, mouse movement turns the cursor by the configured sensitivity, inside a cone around that direction, so the cursor follows the head as it turns. In the desktop simulator, the window shows the head's view, so the ray points through the window's own cursor instead, and keeps its aim while the [simulator](../simulator/README.md) holds the mouse to turn the head. The primary, secondary, and middle buttons press the pointer's left, right, and middle buttons, and the wheel scrolls the hovered surface. While a panel is carried, the wheel pushes it away or pulls it nearer.

The ray has no aim filter and no trigger lock, because a mouse does not move when its button is pressed. The mouse is a separate source, so it hovers and captures independently of the controllers.

The pointer and its own seat are made at the first mouse movement. A session without a mouse therefore has no extra seat and draws no cursor. The cursor is a sphere of constant apparent size at the hit point, or at the configured distance along the ray when the ray hits nothing. It draws in the theme's pointer colours unless the options set others.

The pointer reads mouse events only while the desktop window has input. Host mouse capture, which would take the mouse independently of window focus, is not implemented.

[Options](config.luau) · [Frame contract](../../../lunette-contracts/frame.luau) · [Interaction contract](../../../lunette-contracts/interaction.luau)
