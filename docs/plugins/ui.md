# UI panels

Plugins build in-session interfaces on the UI host, `lunette/ui-host`, without importing a provider implementation. The [host contract](../../lua/lunette-contracts/ui-host.luau) owns panels, kinds, visuals, and node handles. The [standard kinds](../../lua/lunette-contracts/ui-components.luau), `lunette/ui-components`, publish the controls in the default theme. The [React-like library](../../lua/lunette-plugins/ui/react/README.md), `@lunette-plugins/ui/react`, renders function components with hooks onto a host panel. The [UI design documents](../development/ui/README.md) describe the architecture.

## An example form

[`examples/ui/main.luau`](../../examples/ui/main.luau) inserts a complete form into the desktop. Its [form plugin](../../examples/ui/form.luau) requires the host, the standard kinds, and the menu, creates an owner-scoped panel, and mounts a component that keeps the form's values in hooks. It also registers a kind of its own, a pad that counts taps. A wrist-menu action shows the panel, the text field uses the shared keyboard, and the close button ends the field's focus before hiding the panel.

Run it with the [copy/check workflow](../users/desktop-configuration.md#copy-and-check-a-configuration), copying the example modules beside `main.luau`.

## Panels and presentations

`newPanel` takes a name, a size in metres, and a presentation. A world panel stays where it is placed, a follow panel trails the head, a dialog sits in front of a parent and can block it, and an attached panel sits above a target surface, as window titlebars do. A panel can be curved. Panels end with the owner that created them; check `dead` before using a retained handle. A panel's chrome comes from the standard `Panel` component: given a `title`, it shows the header band with an optional `detail`, a back button for `onBack`, a close button for `onClose`, and the buttons of a `HeaderActions` child. The grip grabs a world panel anywhere, and the trigger grabs it from the empty part of its header band, so every titled panel moves the same way, with a mouse as well.

## Kinds and visuals

An element names a kind. `registerKind` declares a kind's layout, focus policy, role, props schema, and event handler; `registerVisual` draws it through the host's drawing API, which clips to the node and follows the panel's curve. A visual that needs geometry the API does not offer draws a volume: the host calls the plugin's own draw function every frame with the pass placed on the node, and the plugin draws meshes with its own shaders. The host does not clip a volume, so it hides one that a scroll view cuts. A composite kind expands into other elements. The standard kinds are the reference implementation, and the [widget gallery](../../dev/plugins/ui-gallery/README.md) shows each of them.

## Geometry and input

Node coordinates are metres from the panel's top-left corner, with y down. Pointer capture, cancellation, focus, and inspection follow the [UI host guarantees](../../lua/lunette-contracts/panels-and-ui.md#ui-host). Focus traversal with the thumbsticks and controller buttons reaches every focusable node, so a panel built from standard kinds is usable without a keyboard or mouse.

## Text fields

Text fields accept single-line UTF-8 and edit whole grapheme clusters. A value set through props does not call `onChange`. With `desktop/keyboard` present, field focus shows the shared keyboard without a direct keyboard-display dependency; hiding the keyboard ends focus and keeps the text.

## Notifications and accessibility

`lunette/notifications` posts toasts that fade beside the panel a notification names as its anchor, or on a follow panel, and keeps a history. `lunette/accessibility` holds the text scale, high contrast, reduced motion, and haptics settings, which the host applies to every panel. Menu actions keep opening and closing a panel reachable through VR controls; the [broker contract](../../lua/lunette-contracts/policy-services.md#brokers) defines their lifetime.

## Outlets

An outlet is a named, typed point in another plugin's panel where a plugin contributes its own interface. A contract module declares it with `uiHost.outlet`, giving a name, a version, a props schema, and whether it is attributed; the owner places it with `c.Outlet`. A plugin contributes a component with `ui.contribute(context, outlet, component, { components = components })`, and the component receives the placement's props. The [host contract](../../lua/lunette-contracts/ui-host.luau) states the version, ordering, and attribution rules. The plugin manager's settings outlet, in [`@lunette-contracts/plugin-manager`](../../lua/lunette-contracts/plugin-manager.luau), shows a plugin's settings page in its Configure tab; the [widget gallery](../../dev/plugins/ui-gallery/settings.luau) contributes one.

Each placement renders the component separately, with its own state and effects. A component that shows content only for some props still calls its hooks on every render, so it returns nil after them rather than before. A contribution ends with its owner, and its errors are reported against it.

## Ownership and replacement

Panels, kinds, and visuals end when their owner or the host unloads. Inspection returns geometry and semantics without granting control of another plugin's panels. [Ownership and lifecycle](../../lua/lunette-plugin/ownership.md) defines caller-owned acquisition and service revocation.
