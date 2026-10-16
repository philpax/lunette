# Presentations

A presentation places, scales, and summons a panel, and selects the interaction policy that applies to it. The component tree does not know its presentation unless it asks. One tree can therefore appear as a wrist menu operated by poking, and as a menu summoned in front of the user and operated with a mouse and keyboard.

## Pose policies

A presentation is a registered value, not a closed set of names. A registration declares:

- A name, namespaced like kind names, such as `lunette/wrist` or `example/palm-menu`, and unique among live presentations, so configuration can refer to it.
- A pose source: an anchor, as [Spatial model](spatial-model.md#anchors) defines, or a function or store that returns a pose each frame, with constraints such as a distance band, lazy following with a threshold, or billboarding.
- A visibility rule, such as hiding a wrist panel when its hand is not tracked, or showing a hand menu while the palm faces the user. A visibility rule has a grace period at least as long as the tracking grace period, so a finger that briefly occludes the wrist from the headset's cameras while poking the wrist menu does not hide it.
- A scale, which multiplies the panel's authored size, and a nominal viewing distance, which the minimum text size is measured at. [Theming](theming.md#units) explains how scale relates to viewing distance.
- A density, which selects token variants for target sizes, as [Density](#density) describes.
- The interactors it accepts, and whether points can touch it.
- Whether showing the panel takes session focus.
- Whether the user can grab, move, resize, and curve the panel.

`host:registerPresentation(context, registration)` registers a presentation and returns it. Configuration names presentations, and a name that is not registered is reported when a panel uses it, rather than failing activation. When a panel's presentation ends, because its owner unloads or fails, the panel moves to `lunette/summoned` and the host reports it, so the wrist menu does not vanish with a faulty third-party presentation. The standard presentations register through the same call and are available as `host.presentations`, under the `lunette/` names:

| Presentation | Pose source | Typical interactors | Examples |
|---|---|---|---|
| `world` | A world pose, moved by the user | Rays and mouse; touch when within reach | Plugin manager, backdrop controls, UI example |
| `wrist` | The forearm of the configured hand, hidden when it is not tracked. A palm-up variant shows an affordance when the palm faces the user, and a pinch on it confirms | Touch from the other hand; rays | Wrist menu |
| `summoned` | In front of the head when shown, then fixed in the world until dismissed | Rays, mouse, and keyboard | Wrist menu in mouse and keyboard mode, quick launcher |
| `attached` | Relative to another panel, sharing its surface shape | Inherited from the parent panel | Titlebars, window decorations, toolbars, orbiters |
| `anchored` | Relative to a node in another panel, positioned as described in [Portals and overlays](#portals-and-overlays) | Inherited from the opener's panel | Dropdown menus, tooltips, context menus |
| `follow` | Lazily following the head within a band at the edge of the view, without taking focus | Rays and mouse | Toasts |
| `dialog` | In front of the head when shown, like `summoned`, keeping its logical parent | Rays, mouse, keyboard, and touch when within reach | Dialogs and confirmations |

A world panel keeps its physical size by default as the user moves it, because #47 and #8 treat moving and scaling as separate operations. A presentation can opt into keeping its angular size instead, in which case its scale is the larger of 1 and its distance divided by its nominal viewing distance, so a panel brought within reach never shrinks below its authored size.

A third-party plugin registers its own presentations, such as a palm-up hand menu, a near menu that tags along, or a dock on a curved shelf, and they compose with the rest of the toolkit in the same way.

## Comfort

Presentations place panels within comfortable ranges:

- A summoned panel appears slightly below eye level, inside a distance band, and facing the user. It is not locked to the head.
- Touch presentations sit within reach and below the shoulder, because touch-heavy panels at shoulder height tire the arm. Panels beyond reach default to rays.
- Opening and closing a panel scales and fades it in place, rather than moving it across the field of view.
- Following motion is lazy and thresholded. With reduced motion set, a following panel that leaves the comfortable field of view fades out and fades in again at its new place rather than moving.

The user's eye height, whether they are seated or standing, and their reach come from the accessibility settings, as [Accessibility](accessibility.md#settings) describes.

## Density

A presentation sets the minimum density its interactors need: touch presentations require the comfortable density, and ray and mouse presentations allow the compact one. A panel can request the compact density, such as the plugin manager does, and gets it only where its presentation allows. A dense panel shown on a touch presentation therefore becomes comfortable, rather than presenting targets too small to poke.

## Portals and overlays

A portal renders an element into another panel while keeping its logical parent. The logical parent provides context to the portal's content, and events that bubble out of the portal continue to the logical parent. Overlays are portals into panels that the host creates: menus, popovers, and tooltips with the `anchored` presentation, and dialogs with the `dialog` presentation. A multi-panel application can portal into any panel it owns. A portal's content takes its context from its logical parent, and its density and presentation from the panel it renders into. A portal that is not an overlay declares whether it joins its logical parent's focus order. Overlays are separate panels, as menus and popups are separate windows in desktop toolkits, so they can extend beyond the panel that opened them.

### Positioning

An overlay is positioned in the manner of Wayland's `xdg_positioner`:

- An anchor rectangle, which is the opener node's bounds by default.
- An anchor edge or corner on that rectangle, and a gravity that says which way the overlay extends from it.
- An offset.
- Constraint adjustment: when the overlay would leave its constraint region, it flips to the opposite side, slides along the edge, or shrinks and scrolls, in that order of preference.

The constraint region is the comfortable field of view and reach for world and summoned panels; the space beside the wrist, away from the hand, for wrist panels; and the parent panel's bounds for overlays that must stay within it, such as a tooltip on a dense panel. With the accessibility handedness setting, overlays prefer the side away from the pointing hand.

An overlay inherits its parent panel's surface shape: the same axis and centre, at the overlay's elevation. Its elevation is relative to the opener node: popovers, menus, and tooltips stand one `raised` step above the opener. On a presentation that accepts touch, an overlay opens beside its opener rather than over it, so it does not cover the control under the finger that opened it. Tooltips do not answer hit queries, so they never block what is behind them.

The host offers an overlay's surface to the interaction service in the commit that creates it, so a capture can transfer to it in the same frame.

### Capture handoff

A press on an opener, such as a dropdown button, can open its overlay while the press is still held. The host then transfers the interactor's capture from the opener to the overlay, so the user can drag onto an item and release to choose it, as with desktop menus. Releasing over the opener without moving leaves the overlay open for a separate click. The interaction service's rule that a pressed surface keeps its capture until release has this one exception, which the portal requests. Gesture claims follow the physical path within the hit panel, so a press-drag-release menu inside a scroll box does not scroll the box. Handoff applies to ray interactors only. A touch press opens the overlay on release, because a fingertip pressed into the opener is behind the overlay and would reach its items from behind.

### Dismissal

An overlay chain closes from the innermost overlay outwards. An overlay closes when:

- the user presses anywhere outside the chain, including on empty space or another panel, which the interaction service reports through a session-level outside-press observer. The opener counts as part of the chain, so pressing an open dropdown's button closes it rather than closing and reopening it;
- the user presses Escape or the dismissal action;
- its opener is removed, disabled, or hidden;
- the source that opened it loses tracking while the overlay depends on it, such as a press-drag-release menu.

A capture inside a dismissed overlay ends with `cancel` and the reason `hidden`. A tooltip closes when hover or focus leaves its opener.

### Focus

An overlay other than a dialog shares its opener's session focus target, so it does not register its own. Opening an overlay through traversal or the keyboard moves focus into it, and closing it returns focus to the opener. Opening it through a pointer leaves focus where it was. A search field with a suggestions overlay keeps focus in the field, while arrows move the active item in the overlay.

### Modality

A dialog is opened by handle, `host:openDialog(owner, element, { parent, modality })`, rather than by rendering it inside its opener's subtree. It keeps a logical parent for context and events, but its lifetime belongs to its owner and its handle, so it survives the context menu item, the virtualised row, or the wrist panel it was opened from: a "Remove plugin?" confirmation stays when the context menu that offered it closes, and a confirmation opened from the wrist menu stays when the wrist turns away. A dialog has the `dialog` presentation and registers its own session focus target, so it keeps keyboard input and traversal while its opener is hidden. Closing it returns focus to the target that held it before.

A dialog is modal. While it is open, interactors cannot press nodes in its parent panel, and traversal stays inside the dialog. A dialog can instead be session-modal, which blocks every other toolkit panel; the confirmation of session-level actions uses it. A session-modal dialog with a parent opens in front of that parent, as a modal one does, and one without a parent opens ahead of the head. Every panel that a dialog blocks is drawn under a dark scrim, so the reason it takes no presses is visible. Window panels, the default-appearance chord, and the recovery plugin stay usable under a session-modal dialog, and a session-modal dialog can always be dismissed.

### Ids

A node inside a portal has an id under its logical parent's path, as [Testing](testing.md#ids-and-inspection) describes, so tests address a menu item through the dropdown that opened it.

## Notifications

The notifications service, `lunette/notifications`, reports transient events to the user, such as a launch that failed or a mirror that became available. A plugin posts a notification with a severity, a title, an optional body, optional actions such as Retry, an optional progress that is determinate or indeterminate, an optional cancel action, an optional timeout, and whether it persists until acknowledged. The service returns a handle to update or withdraw it, so a launch shows "Launching" with progress and Cancel, then becomes a failure with Retry or disappears. Notifications belong to the posting owner and are withdrawn when it unloads. A plugin with no panel of its own asks the user a question through `notifications:prompt`, which the service presents as a dialog with the plugin's name, and which resolves to the user's choice.

The service shows notifications as toasts, stacked, with excess notifications queued rather than dropped. A notification can name the panel it concerns as its anchor; its toast then sits beside that panel and moves with it, and returns to the `follow` presentation if the panel ends. Other toasts use the `follow` presentation. The service keeps a history panel that the wrist menu opens. Toasts never take focus, and they accept rays only on themselves. A toast's timeout pauses while it is hovered and is multiplied by the accessibility timing setting. Every toast's actions are also available from the history panel, which takes focus normally, so they are reachable through focus traversal. The errors overlay remains a diagnostic surface for plugin errors. It is not the place for events that the user is expected to act on.

## World panels and arrangement

World panels take part in the session's panel management. They are surfaces that the user grabs and moves, layouts arrange them, tags select them, and the arrangement service saves and restores their pose and size. #48 adds curvature to the arrangement format, with a format version bump and a decision for old writers, after which curvature persists for every panel type.

## Input modes

The input mode service publishes the active input modes as a store: controllers, tracked hands, and mouse and keyboard, and any mode that a plugin's source registers, such as a head pointer or switch access. More than one mode can be active, such as tracked hands with a mouse. The service derives modes from tracking state and recent input, with hysteresis, so a single movement of the mouse during a poke does not switch modes.

A consumer chooses presentations per mode. The default desktop configuration mounts the wrist menu's component on the `wrist` presentation while a hand or controller is tracked, and shows the same tree on the `summoned` presentation in mouse and keyboard mode. A controller binding and a palm-up gesture on either hand also summon it. In one-handed mode, which the accessibility settings set, or which the session enters after the other hand has been absent for several seconds, the summon places the menu on the `summoned` presentation, operated by that hand's ray, rather than on a wrist that the same hand would have to touch. The choice of presentation is desktop policy, so a configuration can change it.

A panel moves between presentations with its tree mounted, so component state, scroll positions, caret positions, and partly typed text survive. A panel does not change presentation or density while an interactor holds a capture in it; the change waits until the capture ends. A panel that its presentation hides releases session focus, and the host restores the focus target that held it before, as [Input](input.md#focus) describes, so a hidden wrist panel never keeps the keyboard.

## Adapting content

A component reads its presentation through `ui.usePresentation()` when its content must differ, for example to show fewer items on the wrist. Most components do not need to, because density changes target sizes through tokens and scale changes the panel's physical size.

## Relation to window panels

Window and monitor panels are managed by the panels service, not by the toolkit. The titlebars and decorations attached to them are toolkit panels with the `attached` presentation, sharing the window panel's surface shape, so they curve with it.

A window panel realised as a composition layer is composited by the runtime without depth against the scene. Toolkit chrome and labels attached to such a window stay outside the window's rectangle, because content drawn in the scene over the window's area would be hidden or shown regardless of depth. A label that must sit over a window's content needs the window to render in the scene. lunette's window layers are quads, so a curved window panel renders in the scene.

## Open questions

- The wrist presentation's pose relative to the hand, which needs tuning in a headset for both controllers and tracked hands.
- Whether a panel can be torn off from one presentation into another while open, such as dragging a wrist menu into a world panel.
