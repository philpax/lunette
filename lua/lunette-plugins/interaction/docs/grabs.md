# Grabs

Grip starts a grab on a hit surface unless it is not grabbable. Surfaces can opt into trigger-grab or redirect a grab to another offered surface. Starting a grab cancels Lua pointer captures; native pressed sinks still receive their releases. After cancellation, a held trigger must be released and pressed again before it can start another gesture.

The panel keeps its pose relative to the controller, so controller movement moves the panel with it. Thumbstick deflection can move the panel along its local reach axis. A second pointer can scale the same surface; if that pointer releases, the first continues with an ordinary grab offset.

A grab emits one `lunette/drops` notification before clearing the pointer's carried surface. Listeners can inspect the carried surface during the notification, including when cleanup ends the grab.

## Decisions

Controller-relative movement is retained because upright-only movement proved less usable in headset testing.

## Known gaps

Input delivered to an overlay can also reach the underlying application. Input blocking remains unimplemented; see [Input](../../../../docs/dev/input.md#known-gaps).
