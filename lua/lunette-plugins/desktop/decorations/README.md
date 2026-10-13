# Native panel titlebars

`@lunette-plugins/desktop/decorations` gives native window and monitor panels a shared UI titlebar when the panel has no chrome of its own. The shipped desktop uses entry `desktop/decorations`.

The entry requires `lunette/frame`, `lunette/panels`, and `lunette/ui`. [`config.luau`](config.luau) is the source of truth for the optional `style` override. The override uses the UI provider's titlebar style descriptor. The shared UI provider owns titlebar controls and joined-frame geometry; see [Joined frame attachments](../../../../docs/dev/lua-api.md#joined-frame-attachments) and [Joined flat frames](../../../../docs/dev/rendering.md#joined-flat-frames).

[Titlebar behavior](docs/titlebar-behavior.md) specifies close, move, and monitor recovery actions. [Desktop configuration](../../../../docs/guide/desktop-configuration.md#monitors-and-titlebars) remains the workflow guide. Tests: [`controls.luau`](tests/controls.luau).

## Deliberately left open

The duplicate-titlebar question, interaction limitation, alternatives, and hardware acceptance condition are recorded in [Titlebar behavior](docs/titlebar-behavior.md#deliberately-left-open).
