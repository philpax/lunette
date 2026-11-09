# Focus

Routes keyboard input to native sinks or local receivers. Physical keypad digits require a host Num Lock and Shift snapshot; unsupported snapshots and keypad remappings are not guessed.

When the panels service is available, locked panel sinks refuse native focus. A lock change releases routed input and withdraws every matching native seat authority, including prior routes. Unlock does not restore focus. Panels service detach withdraws native focus before disconnecting; focus also operates without a panels provider.

[Contract](../../../lunette-contracts/focus.luau) · [Input protocol](../../../lunette-contracts/docs/input.md)
