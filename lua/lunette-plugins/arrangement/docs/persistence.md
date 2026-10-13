# Persistence behavior

The `desktop/persistence` entry keeps loaded arrangement state and window slots across activations that use the same file. Its rule source and monitor-arrival listener belong to each activation. The [format implementation](../format.luau) owns serialization and validation.

## Matching and slots

A window is matched by application id and slot, not by the identity of the old window. It holds its slot until it dies; a later window with the same application id can reuse a free slot. Slots are not allocated during every rule resolution, which would let previews consume them. Removing a panel does not free a slot, because outages can remove panels while their windows remain alive.

Saved monitor panels restore when their monitors appear. Unmatched saved entries are reported once per arrangement.

## Saving

Unreadable files and files from a newer format version are reported and never overwritten. The provider saves after a drop and at quit. It does not save on panel removal because removal also occurs during outages, reloads, and unloads. A quit-save failure is reported without vetoing quit.

The drops and frame contracts provide the notifications; [the arrangement contract](../../../lunette-contracts/arrangement.luau) defines the service.
