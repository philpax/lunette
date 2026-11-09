# Arrangement persistence

The `desktop/persistence` entry saves and restores panel poses, sizes, tags, and input locks. Windows match by application id and slot; a live window keeps its slot through provider outages. Monitor panels restore when their monitors appear. A save keeps the saved entries of absent panels, such as a closed application or a monitor not yet mirrored, so they restore when the panel returns.

Saving occurs immediately after an input lock changes, after a drop, and at quit, not on panel removal, which also occurs during outages and reloads. Restoring a lock does not trigger a save, so restoration cannot overwrite saved entries with partially restored state. Saves replace the file atomically through `lunette.saveFile`. A failed save returns an error without confirming persistence and keeps the latest session capture for restore and retry, including entries whose panels later disappear. A directory-flush error can occur after the new file becomes visible, with its survival across a crash or power loss unconfirmed. Unreadable files and newer formats are reported and never overwritten. Save errors do not veto quit.

[Options](config.luau) · [Contract](../../../lunette-contracts/arrangement.luau)

## Implementation reference

Version 1 arrangements migrate with input unlocked. Version 2 records input locks and prevents older writers from overwriting them.

The [file-format implementation](private/format.luau) defines the saved representation. It is a source reference, not a supported author import; plugins save and restore through the arrangement service.
