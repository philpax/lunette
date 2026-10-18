# Presentations

A panel's presentation controls its placement policy. Application content remains a retained tree, so a caller can place the same component model in different panels without making each widget compute world poses.

## Pose policies

The host accepts the closed presentation values `world`, `follow`, `dialog`, and `attach`. The [host contract](../../../lua/lunette-contracts/ui-host.luau) owns their options. There is no public presentation registry, named pose-policy extension, or fallback from an unloaded presentation registration.

World panels stay at their supplied or initial pose until moved. Follow panels lazily follow the head. Dialog panels sit in front of their parent or the head and apply modality. Attached panels sit above a target surface and direct grabs to that target.

A caller can set a panel's pose explicitly, as the wrist-menu consumer does. Wrist and summoned placement are consumer policy rather than registered host presentations. There is no automatic angular-size preservation, presentation-scale system, or density transition protocol.

## Comfort

Panels need readable placement without continuous head locking. Following uses a threshold rather than tracking every small head movement. Touch-heavy content needs placement within reach and below sustained shoulder height. Those are constraints for consumers and headset tuning, not a guarantee that the host derives placement from a body profile.

## Density

Theme tokens determine the current control sizes. The host does not negotiate compact and comfortable density from a presentation's accepted interactors. A consumer that changes layout for a wrist or distant panel must pass that choice explicitly.

## Portals and overlays

The host's portal kind renders children into a separate overlay panel. It retains the logical relationship to the opener and can extend beyond the opener panel's bounds. It is not a general portal API for targeting any caller-owned panel or joining arbitrary focus orders.

### Positioning

An overlay anchors to its opener and supports the placement choices in the host contract, including width matching. Placement can flip when space requires it. This is not the full `xdg_positioner` model: the host does not derive a comfortable-field constraint region, body reach, or handedness-dependent placement.

A curved opener creates a flat overlay tangent to the curve at the overlay's centre, raised above its anchor. The overlay does not share a concentric cylindrical surface. Tooltips can opt out of hit testing so they do not block content behind them.

### Capture handoff

A portal can request handoff of a held ray press from its opener. The user can open a menu on press and release over an item to choose it. Releasing without choosing leaves the menu available for a separate click. A touch opener acts on release rather than transferring a fingertip already behind the overlay.

Handoff is an explicit portal behavior. It does not establish general node-to-node capture transfers or ancestor gesture arbitration, which remain deferred in [#69](https://github.com/philpax/lunette/issues/69). Creation and handoff occur at a scene-update commit, not a post-input commit in the same frame.

### Dismissal

Outside presses dismiss overlays, including presses reported outside toolkit surfaces. The opener belongs to the overlay chain so it can close an open menu without an immediate close-and-reopen cycle. Dismissal and owner cleanup also remove overlay content. Losing a press on which a handoff menu depends closes that menu.

### Focus

Overlay focus remains associated with its opener's panel rather than registering an independent session focus destination. Dialog panels are separate. The focus contract and host traversal implementation own key routing; suggestions and menus do not imply a general focus-scope registration API.

### Modality

A dialog is a panel with dialog presentation and optional parent. Panel modality blocks presses on its parent; session modality blocks other toolkit panels. A scrim marks blocked toolkit panels. Window panels and recovery controls remain outside this host-local blocking rule.

A dialog created on an owner survives removal of the particular opener node while that owner remains live. There is no `openDialog` element-mounting API: the caller creates and mounts the panel through the ordinary host and authoring contracts. The dialog's resource lifetime must not depend on a temporary menu item's component effect if it must survive that item's removal.

### Ids

Overlay node inspection follows the logical opener's keyed path. [Testing](testing.md#ids-and-inspection) records the addressing boundary.

## Notifications

The [notification contract](../../../lua/lunette-contracts/notifications.luau) owns posting, lifetime, actions, and history. Toast panels use follow placement and do not take focus. Actionable notifications also need a non-pointer path through their history or another accessible panel. A proposed notification behavior is not implied by the presentation name.

## World panels and arrangement

A grabbable world panel saves its resting pose under its name in the host's `placed` setting. A later panel with that name uses the saved pose. A caller that poses a panel every frame disables grabbing rather than allowing that placement to overwrite its pose policy. Forgetting `placed` in the runtime manager returns panels to their caller-supplied poses.

This setting is not a maintained arrangement of toolkit panels. Tagging, automatic reflow, shared layout membership, and saved size or curvature are not guaranteed by it. [#71](https://github.com/philpax/lunette/issues/71) tracks maintained arrangements. Any persistent format change needs the old-reader, new-reader, and old-writer compatibility policy, including an appropriate format version rather than silently dropping unfamiliar fields.

## Input modes

There is no session input-mode service in the current contracts. Consumers manage their own placement and visibility from the input available to them. The wrist menu's summon path is consumer behavior, not an automatic host transition between registered wrist and summoned presentations.

The host does not provide an atomic presentation-and-density switch that waits for capture to end. A consumer that hides, moves, or recreates a panel during input must preserve its own focus and capture workflow.

## Adapting content

The React-like library has no `usePresentation` hook. A component that needs placement-specific content receives explicit props or reads a consumer-supplied context or store. Ordinary widgets need no knowledge of the panel's world pose.

## Relation to window panels

Window and monitor panels belong to the panels service. Toolkit chrome can attach above their target surface and follows its movement and size. Attachment does not promise inherited curvature.

A window submitted as a composition layer does not depth-compose with scene content. Toolkit chrome therefore stays outside the layer's rectangle when depth ordering over the client matters. Curved windows render in the scene rather than as the session's quad layers.

## Open questions

- Comfortable wrist placement and follow behavior across seated, standing, controller, and tracked-hand use.
- Transfer between caller-controlled wrist placement and a movable world panel without losing local state.
- Maintained toolkit-panel arrangements in [#71](https://github.com/philpax/lunette/issues/71).
