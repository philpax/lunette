# Placement memory

The `desktop/placement-memory` entry remembers where the user leaves each surface that declares a placement key. Dropping such a surface saves its pose, and its width when it can be resized, in the entry's saved settings. The first time a surface with that key is offered in an activation, it returns to the saved placement, so it survives reloads and restarts.

Grabbable world panels from the [UI host](../../ui/host/README.md) use their panel name as the key, and the keyboard display's keyboard uses `desktop/keyboard`. Window and monitor panels have no key: [arrangement persistence](../persistence/README.md) saves them, matching windows by application id and slot. Forgetting the entry's saved settings in the runtime manager returns keyed surfaces to their owners' placement.

[Options](config.luau) · [Surface contract](../../../lunette-contracts/vocabulary.luau)
