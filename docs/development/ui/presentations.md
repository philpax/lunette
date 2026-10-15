# Presentations

A presentation places, scales, and summons a panel, and selects the interaction policy that applies to it. The component tree does not know its presentation unless it asks. One tree can therefore appear as a wrist menu operated by poking, and as a menu summoned in front of the user and operated with a mouse and keyboard.

## Presentation kinds

| Kind | Placement | Typical interactors | Examples |
|---|---|---|---|
| World | A pose in the world, moved by the user | Rays and mouse; touch when within reach | Plugin manager, backdrop controls, UI example |
| Wrist | Attached to a tracked hand or controller, hidden when it is not tracked | Touch from the other hand; rays | Wrist menu |
| Summoned | Placed in front of the head when shown, then world-fixed until dismissed | Rays, mouse, and keyboard | Wrist menu in mouse and keyboard mode, quick launcher |
| Attached | Fixed relative to another panel | Rays and mouse | Titlebars, window decorations |
| Anchored | Positioned relative to a node in another panel, at a higher elevation | Inherited from the anchor's panel | Dropdown menus, tooltips, context menus |

A presentation has these properties:

- A pose policy: world-fixed, attached to a tracked device, attached to a panel, or anchored to a node.
- A scale, which multiplies the panel's authored size. [Theming](theming.md#units) explains how scale relates to viewing distance.
- A density, which selects token variants for target sizes: compact for rays and the mouse, comfortable for touch.
- The interactors it accepts, and whether points can touch it.
- Visibility rules, such as hiding a wrist panel when its hand is not tracked.
- Whether the user can grab, move, resize, and curve the panel.

Anchored presentations are created by the host for overlays. Overlays are panels in their own right, so they can extend beyond the edge of the panel that opened them and draw at popover or dialog elevation.

## World panels and arrangement

World panels take part in the session's panel management. They are surfaces that the user grabs and moves, layouts arrange them, tags select them, and the arrangement service saves and restores their pose, size, and curvature. Curvature persistence is part of the arrangement format and applies to every panel type.

## Input modes

An input mode service publishes the active input modes: controllers, tracked hands, and mouse and keyboard. More than one mode can be active, such as tracked hands with a mouse. The service derives modes from tracking state and recent input, and it publishes changes as a store.

A consumer chooses presentations per mode. The default desktop configuration mounts the wrist menu's component on a wrist presentation while a hand or controller is tracked, and binds a key that shows the same component on a summoned presentation in front of the head. The component is the same in both cases. The choice of presentation is desktop policy, so a configuration can change it.

## Adapting content

A component reads its presentation through `ui.usePresentation()` when its content must differ, for example to show fewer items on the wrist. Most components do not need to, because density changes target sizes through tokens and scale changes the panel's physical size.

## Relation to window panels

Window and monitor panels are managed by the panels service, not by the toolkit. The titlebars and decorations attached to them are toolkit panels with attached presentations. The toolkit draws them with the same shader, and they curve with the window panel they are attached to.

## Open questions

- Whether a summoned panel follows the head lazily after it is shown, or stays world-fixed until dismissed.
- The wrist presentation's pose relative to the hand, which needs tuning in a headset for both controllers and tracked hands.
- Whether a panel can move between presentations while open, such as tearing a wrist menu off into a world panel.
