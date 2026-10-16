# UI host

Provides `lunette/ui-host`: panels with root mount points, element kinds and visuals, layout through the native layout tree, pointer routing, and drawing through the toolkit shader. The [design documents](../../../../docs/development/ui/README.md) describe the architecture this provider implements.

A consumer creates a panel with `newPanel` and binds its `root` mount point, usually through the [React-like library](../react/README.md). Kinds come from `registerKind`, and visuals from `registerVisual`; the [standard kinds](../standard/README.md) are the reference. Element trees are reconciled by slot and kind, composite kinds expand into other elements, and node handles reach visuals, event handlers, and refs.

This version implements a subset of the design. Panels are flat, and pointer input arrives through the surfaces contract from the existing interaction service, so rays drive hover, press, drags, and scrolling, while focus, controller traversal, tracked hands, portals, and animation channels other than hover lift and press travel are not implemented. Clips are rectangles. Text is drawn line by line with LÖVR MSDF fonts made from the files that layout shapes with, and a line is stretched to its shaped width when the two disagree slightly. A font registration that ends removes the face from drawing but not from shaping, because the native layout fonts have no removal; text in that family is then measured with the old face and drawn with LÖVR's default font. Commits run once per frame in the scene update phase, so a change made during pointing renders on the next frame.

[Options](config.luau) · [Contract](../../../lunette-contracts/ui-host.luau)
