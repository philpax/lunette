# Routing and delivery

[Keyboard routing](../../../../docs/dev/input.md#keyboard-routing) specifies route ownership, native seat authority, and delivery. The provider's physical keypad policy uses the event's Num Lock and Shift snapshot: Num Lock without Shift produces numeric text; otherwise it produces navigation keycodes. A keypad digit without a modifier snapshot is refused rather than guessed.
