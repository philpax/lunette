# Panel persistence

The `desktop/persistence` entry saves and restores two files. The arrangement holds placement: panel poses, sizes, and tags. The properties store holds each panel's curve, axis, input lock, and transform lock.

Windows match by application id and slot; a live window keeps its slot through provider outages. Monitor panels restore when their monitors appear, and two live mirrors of one monitor take distinct slots. A save keeps the saved entries of absent panels, such as a closed application or a monitor not yet mirrored, so they restore when the panel returns. The properties store does the same, keyed by a `PanelId`: a window application id plus slot, a monitor key plus slot, or a toolkit panel name. Only a top-level world toolkit panel joins the store; titlebars, dialogs, follow panels, and overlays stay out. A creator's explicit property wins over a stored one.

Saving occurs immediately after a committed curve or axis change and after either lock toggle, after a drop, and at quit, not on panel removal, which also occurs during outages and reloads. A curve preview does not save. Restoring does not trigger a save, so restoration cannot overwrite saved entries with partially restored state. Saves replace each file atomically through `lunette.saveFile`, and the properties store is written before the arrangement. Unreadable files and newer formats are reported and never overwritten. Save errors do not veto quit.

[Options](config.luau) · [Contract](../../../lunette-contracts/arrangement.luau) · [Properties contract](../../../lunette-contracts/panel-properties.luau)

## Implementation reference

The arrangement is version 3 and holds placement only. Version 1 and 2 readers still refuse it. A version 1 or 2 input lock migrates into the properties store before a version 3 arrangement may be written; a failed store write refuses the arrangement save, so the old file survives until the locks are saved. An older writer never sees the store file, so it cannot overwrite the properties.

The [file-format implementation](private/format.luau) defines the saved arrangement, and the [properties store](private/properties.luau) defines its own version 1 file, `panel-properties.saved`. They are source references, not supported author imports; plugins save and restore through the arrangement service.
