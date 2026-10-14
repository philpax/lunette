# Arrangement persistence

The `desktop/persistence` entry saves and restores panel poses, sizes, and tags. Windows match by application id and slot; a live window keeps its slot through provider outages. Monitor panels restore when their monitors appear.

Saving occurs after a drop and at quit, not on panel removal, which also occurs during outages and reloads. Unreadable files and newer formats are reported and never overwritten. Save errors do not veto quit.

[Options](config.luau) · [Contract](../../../lunette-contracts/arrangement.luau)

## Implementation reference

The [file-format implementation](private/format.luau) defines the saved representation. It is a source reference, not a supported author import; plugins save and restore through the arrangement service.
