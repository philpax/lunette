# Routing and delivery

The shared [input protocol](../../../lunette-contracts/docs/input.md#keyboard-routes) defines focus ownership, native seat authority, source delivery, inverses, and physical batches.

The built-in provider's physical keypad policy uses the frame event's physical modifier snapshot. Num Lock without Shift produces numeric text; otherwise the keypad produces navigation keycodes. A keypad digit without a snapshot is refused rather than guessed. Host keypad remappings and backends without a physical modifier snapshot are unsupported. The snapshot is distinct from the ordinary modifier-name list: it represents physical Num Lock and Shift state at the host event boundary, which may not be available from every backend.
