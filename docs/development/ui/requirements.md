# Requirements

## Capabilities

The toolkit provides:

- A retained tree of composable elements, built declaratively by components. A parent owns its children, and their lifetimes follow the plugin owner of their panel.
- Layout with row, column, stack, grid, and scroll containers, padding, gap, alignment, and fixed, flexible, and intrinsic sizing. Intrinsic sizes are measured from content, including text. A panel can size itself to its content.
- Text as a toolkit primitive: shaping, wrapping, alignment, clipping, ellipsis, styles from a typography scale, inline spans, and font fallback. No component draws text outside the toolkit.
- A standard widget set: text, button, toggle, checkbox, slider, stepper, segmented control, dropdown, list rows with secondary text and icons, virtualised list, text field and text area, tabs, collapsible section, separator, progress indicator, image, icon, tooltip, popover, context menu, and dialog.
- An overlay layer for dropdown menus, context menus, tooltips, and dialogs, with elevation, dismissal, and pointer capture. A closed dropdown occupies one row.
- State binding through components and observable stores. A component updates when the values it reads change, and the host updates only the nodes that changed.
- A visible reason for every disabled control, reachable by every interactor and by focus traversal.
- Theming through structured tokens: a spacing scale, a typography scale, colour roles with state layers, radii, elevation, density, motion, and feedback.
- Physical depth: elements are raised above the panel, separated from each other, and pressed in.
- Curvature: drawing and hit testing follow a cylindrical panel.
- Inspection of every node by id with its geometry, so tests address nodes rather than coordinates.

## Session requirements

Every session action is reachable through VR controls without a physical keyboard, mouse, or flatscreen interface. The toolkit meets this through pointer interaction and a focus traversal channel that a controller can drive.

Controller rays, tracked hands, and mouse and keyboard are supported equally well. A panel adapts to the input mode, for example by showing the wrist menu as a keyboard-summoned menu in front of the user in mouse and keyboard mode. A mouse cursor is an interactor like any other.

Shipped plugins use only public contracts, including the standard widgets. A third-party plugin can add an element kind, restyle an existing kind, adjust its behaviour, contribute to another plugin's panel through an outlet, or use a different authoring framework with the same widgets. [Extension](extension.md) describes each mechanism.

Every module is safe to require twice, and every resource belongs to a plugin context or a caller's owner, as the plugin runtime requires.

## Out of scope

- Composition layers for UI panels. [Rendering](rendering.md#composition-layers) records the reasons.
- Embedding an external UI engine that renders to a texture, such as an HTML renderer or a Rust GUI library. Its elements would sit outside the plugin and owner model.
- Bidirectional text editing and input-method composition. Shaping provides bidirectional display, but caret movement through mixed-direction text and preedit remain open in [Layout and text](layout-and-text.md#open-questions).
- A visual editor or a markup language for layouts. Components are Lua.
