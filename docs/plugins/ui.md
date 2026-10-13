# UI panels

Plugin consumers use `lunette/ui` for local VR controls without importing a provider implementation. The [UI contract](../../lua/lunette-contracts/ui.luau) owns types; the [UI provider](../../lua/lunette-plugins/ui/README.md) describes its implementation. Larger interfaces can remain Wayland applications.

## An example form

[`examples/ui/main.luau`](../../examples/ui/main.luau) inserts a complete form into the desktop. Its [form plugin](../../examples/ui/form.luau) declares UI, menu, and frame dependencies, creates an owner-scoped panel, keeps values inside activation, and draws the panel from a frame callback. A wrist-menu action opens it, and a text field uses the shared keyboard.

Run it with the [copy/check workflow](../users/desktop-configuration.md#copy-and-check-a-configuration), copying the example modules beside `main.luau`. New forms follow the same sequence: acquire a panel with the context as owner, register controls and a menu action, then register drawing. The panel's owner releases its controls, surface, captures, and focus on unload.

## Geometry and input

Panel dimensions are metres; control bounds use top-left, y-down logical coordinates. Bounds define input, regardless of what a hook draws. Overlaps, capture, cancellation, and owner identity follow the [panel and UI guarantees](../../lua/lunette-contracts/panels-and-ui.md#ui-geometry).

Hiding, resizing, or changing a control's bounds cancels held gestures without activation. Moving the panel's pose keeps captures. Hover does not transfer keyboard focus. Keep custom drawing within `visual.clip`; the provider does not enforce that clip for hooks.

## Titlebars

A titlebar's close callback decides whether to hide or destroy the panel; the titlebar does neither automatically. Consumers draw externally attached titlebars themselves. [Joined frames](../../lua/lunette-contracts/panels-and-ui.md#joined-frames) defines attachment lifetime and eligible surfaces.

## Text fields

Text fields accept valid single-line UTF-8 and edit whole grapheme clusters. Setting a value does not call `onChange`. Callback errors are reported but do not undo edits. Text shaping, bidirectional editing, and input-method composition are unsupported.

## Shared keyboard and menu actions

With `desktop/keyboard` present, field focus shows the shared keyboard without a direct keyboard-display dependency. Hiding it ends focus and retains the field text. Menu actions keep opening and closing a form reachable through VR controls; the [broker contract](../../lua/lunette-contracts/policy-services.md#brokers) defines their lifetime.

## Themes and drawing hooks

Appearance inherits from the current theme through provider, panel, and control overrides. Omitted fields follow later changes; zero is explicit. Theme changes retain values and focus. Geometry or font changes cancel affected gestures; colors alone do not.

A draw hook receives the visual snapshot and `base`; calling `base` keeps default drawing, and omitting it replaces drawing without changing hit bounds. The [UI guarantees](../../lua/lunette-contracts/panels-and-ui.md#ui-geometry) cover pass state; the [UI provider](../../lua/lunette-plugins/ui/README.md) records rendering limits.

## Ownership and replacement

Check `dead` before using retained handles. Panels and controls end when their owner or provider unloads. Inspection returns geometry without granting control of another plugin's panels. [Ownership and lifecycle](../../lua/lunette-plugin/ownership.md) defines caller-owned acquisition and service revocation.
