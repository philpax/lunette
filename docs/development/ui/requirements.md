# Requirements

## Capabilities

The toolkit provides:

- A retained tree of composable elements, built declaratively by components or by another authoring framework. A parent owns its children, and their lifetimes follow the plugin owner of their panel or of the contribution that added them.
- Layout with row, column, stack, grid, and scroll containers, padding, gap, alignment, and fixed, flexible, and intrinsic sizing. Intrinsic sizes are measured from content, including text. A panel can size itself to its content.
- Text as a toolkit primitive: shaping, wrapping, alignment, clipping, ellipsis, styles from a typography scale, inline spans, links, font fallback, selection and copying of read-only text, and paste into fields. No component draws text outside the toolkit.
- A standard widget set:
  - Display: text, selectable text, Markdown, icon, image including SVG, live texture tile, badge, separator, progress indicator, spinner, and scroll indicator with a draggable thumb.
  - Actions: button, hold-to-confirm button, and grab handle.
  - Choices: toggle, checkbox, radio group, segmented control, dropdown, and slider with optional detents.
  - Values: stepper, number field, vector field, colour field, text field, text area, password field, and search field with suggestions, each with a validation state, an inline error, and an input hint for the virtual keyboard.
  - Collections: list rows with secondary text and icons, table rows with a shared column model, tree rows, and virtualised lists and grids whose items are components.
  - Structure: tabs, collapsible section, navigation stack with back, and resize, scale, and curvature handles.
  - Overlays: tooltip, popover, context menu, dialog, and toast.
- Portals and overlays for dropdown menus, context menus, tooltips, popovers, dialogs, and toasts, with anchoring, dismissal, capture handoff, and modality. A closed dropdown occupies one row.
- State binding through components and observable stores. A component updates when the values it reads change, and the host updates only the nodes that changed.
- A visible reason for every disabled control, reachable by every interactor and by focus traversal.
- Theming through structured tokens: a spacing scale, a typography scale, colour roles with state layers, radii, elevation, density, motion, and feedback.
- Physical depth: elements are raised above the panel, separated from each other, and pressed in.
- Node poses beyond layout: transforms, surface shapes, posed and attached placement, and anchors, as [Spatial model](spatial-model.md) defines.
- Animation: springs, tweens, and loops on node channels, enter and exit transitions, layout transitions, scroll physics, and shader-evaluated parameters for appearance that follows input every frame.
- Feedback through haptics, spatial sound, and visual cues, per modality, with rate limiting that never drops a confirmation.
- Accessibility settings, semantic roles, an event stream for assistive plugins, and a one-handed path for every action, as [Accessibility](accessibility.md) describes.
- A session clipboard and notifications, through platform-neutral services.
- Inspection of every node by id with its pose, role, and state, so tests address nodes rather than coordinates.

## Session requirements

Every session action is reachable through VR controls without a physical keyboard, mouse, or flatscreen interface. The toolkit meets this through pointer interaction, panel manipulation that hands, controllers, and the mouse can perform near and far, and a focus traversal channel that a controller can drive, through which every pointer action is also reachable. A two-handed gesture is never the only path to an action.

Controller rays, tracked hands, and mouse and keyboard are supported equally well. A panel adapts to the input mode, for example by showing the wrist menu as a menu summoned in front of the user in mouse and keyboard mode. A mouse cursor is an interactor like any other.

Shipped plugins use only public contracts, including the standard widgets. A third-party plugin can add an element kind, restyle an existing kind, adjust its behaviour, replace it, contribute to another plugin's panel through an outlet, add an interactor, a shape, or a presentation, or use a different authoring framework with the same widgets. [Extension](extension.md) describes each mechanism.

Every module is safe to require twice, and every resource belongs to a plugin context or a caller's owner, as the plugin runtime requires.

The session stays operable in VR when the toolkit fails. The compiled-in safe mode loads no plugin roots and does not depend on the toolkit. A failure of the toolkit's own plugins after startup is reported by a recovery plugin that does not depend on them and offers reload and safe-mode controls, as [Architecture](architecture.md#errors) describes. Protected panels, such as the plugin manager, stay usable whatever overrides, themes, or replacement components are active.

## Out of scope

- Composition layers for UI panels. [Rendering](rendering.md#composition-layers) records the reasons.
- Embedding an external UI engine that renders to a texture, such as an HTML renderer or a Rust GUI library. Its elements would sit outside the plugin and owner model.
- A visual editor or a markup language for layouts. Components are Lua.

Bidirectional text editing and input-method composition are not provided by the first implementation. Shaping provides bidirectional display, and layout mirrors for right-to-left text, but caret movement through mixed-direction text and preedit remain open in [Layout and text](layout-and-text.md#open-questions). Until they exist, a user of a right-to-left script cannot edit mixed-direction text in a toolkit field, which is a gap in the session requirement for those users.
