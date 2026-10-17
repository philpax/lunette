# Arrangement persistence

The `desktop/persistence` entry saves and restores panel poses, sizes, and tags. Windows match by application id and slot; a live window keeps its slot through provider outages. Monitor panels restore when their monitors appear. A save keeps the saved entries of absent panels, such as a closed application or a monitor not yet mirrored, so they restore when the panel returns.

Saving occurs after a drop and at quit, not on panel removal, which also occurs during outages and reloads. Saves replace the file atomically through `lunette.saveFile`. A failed save returns an error without confirming persistence and keeps the latest session capture for restore and retry, including entries whose panels later disappear. A directory-flush error can occur after the new file becomes visible, with its survival across a crash or power loss unconfirmed. Unreadable files and newer formats are reported and never overwritten. Save errors do not veto quit.

[Options](config.luau) · [Contract](../../../lunette-contracts/arrangement.luau)

## Implementation reference

The [file-format implementation](private/format.luau) defines the saved representation. It is a source reference, not a supported author import; plugins save and restore through the arrangement service.
