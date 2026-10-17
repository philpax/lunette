# Input

The host accepts rays through the surfaces and interaction services, and tracked fingertip touch through its touch router. Keyboard and controller traversal form a separate focus channel. Kinds receive semantic events rather than implementing their own device polling. The [host contract](../../../lua/lunette-contracts/ui-host.luau) and [shared input guarantees](../../../lua/lunette-contracts/docs/input.md) own event types and routing contracts.

## Sources and interactors

Rays share the session's surface protocol with window and monitor panels. A fingertip near a host panel reports its hand as near, so that hand's idle ray stands down. Different hands remain independent.

A general interactor model with grab spheres, transferable gesture claims, and shared manipulation sessions is a deferred requirement in [#69](https://github.com/philpax/lunette/issues/69). Those terms do not name implemented host registration APIs. The mouse projection and capture policy belongs to the mouse input work rather than to a toolkit-specific ray model.

## The interaction pass

The frame service orders scene updates before pointing. The host commits scheduled trees in its scene update. Ray delivery and tracked-touch updates then route against that committed tree. A component state change during pointing schedules the next scene update, not a post-delivery commit. [Architecture](architecture.md#data-flow) states the timing boundary.

## Arbitration

The implemented near-versus-far rule stands down an idle hand ray while that hand is near a toolkit panel. A ray capture continues until its ordinary end; proximity does not transfer it to touch. There is no general arbitration between poke points, grab spheres, and manipulation claims.

Pick hooks and angular proximity queries remain deferred in [#70](https://github.com/philpax/lunette/issues/70). Assistance that selects a target a ray missed cannot rely on a public host proximity query.

## Surfaces

A host panel offers its visible surface for ray picking and converts surface coordinates to node hits. The host checks node bounds and clipping ancestors, preferring raised targets and then later siblings. The current protocol does not provide arbitrary interactor-shape registration or addressable custom hit items within a node.

Window and monitor panels use the surface interaction protocol, but the toolkit's fingertip router does not provide touch input to Wayland clients. A complete touch bridge remains open.

## Routing

A pointer targets the deepest eligible node. Kind handlers can call `base` to continue default processing and bubbling. Keys and text reach the focused node and can bubble to its ancestors. The host does not expose a DOM-style capture-phase handler or a gesture arena across the hit path.

Scroll events include the pointer's local position. This lets a canvas interpret scrolling around the cursor without polling device state. A callback or handler runs through the protected-call boundary so its error does not stop other panels.

## Gesture claims

A kind can declare a drag axis. After movement passes the threshold, the captured node receives drag events. That declaration does not compete with ancestor claims or transfer the press to a scroll container.

[#69](https://github.com/philpax/lunette/issues/69) tracks the richer required model. A slider inside a scroll box needs an unambiguous winner by movement axis. A drag-after-hold must leave immediate scrolling available before its hold completes. A transfer must cancel the previous target and preserve the press reference so raised controls do not jump in depth. These remain requirements, not current guarantees.

## Manipulation

Grabbable panels use the session's existing panel-grab path, including a trigger handle such as a titlebar. The surface answers `triggerGrabs` from the current hit coordinates before a primary-button press is delivered, so a press does not depend on a preceding hover update. Attached chrome directs a grab to its target. This does not establish general node manipulation, shared constraint sessions, grab spheres, or multi-capture transforms.

[#69](https://github.com/philpax/lunette/issues/69) tracks those input mechanisms. One-handed alternatives and the distinction between scaling a panel and resizing client content remain product constraints. A two-handed gesture cannot be the sole way to perform a session action.

## Semantic events

The host contract declares the current event union. It includes hover, press, release, activation, cancellation, drags, scrolling, changes, focus, keys, and text. It does not promise general hold progress, drag-and-drop sessions, multi-capture transforms, analog-axis claims, or per-frame proximity records.

Dragging retains the captured node, but the host does not freeze that node's original layout frame. A consumer must not assume reflow leaves drag coordinates unchanged. Hover and press response are retained node state and do not require a component render.

## Capture and cancellation

A press captures the pressed node. Release activates only that node, only inside it, and only when the gesture has not become a drag. Cancellation never activates. The host currently accepts the primary ray button for node presses and allows one capture per node; it does not expose independent multi-button or multi-interactor captures on one control.

A pointer cancellation from the interaction service reaches a live captured node with its reason. Removing the node ends capture without a release or cancellation event to the removed node. A relayout or panel-pose change does not by itself cancel capture.

When a kind registration changes, the host remakes its nodes and matches replacements by path and kind name. Focus, matching declared state fields, hover, and the active press or drag carry to the replacement. A same-path, same-kind override therefore preserves capture, and release ends the gesture on the remade node. Unmatched removed nodes do not keep capture.

The interaction service owns tracking-loss cancellation and held-button quarantine. The host does not extend that service's closed reason set with a separate cancellation table for unimplemented claims or manipulation.

## Near touch

Touch uses physical distances and hysteresis. Entry from the front arms a poke. Contact past the activation depth presses, recoil releases, and movement back towards the surface re-arms a repeated press. A short tracking loss retains the gesture; after the grace period the router cancels it and requires front entry again. These rules prevent jitter or reacquisition inside a panel from creating an unintended press.

The current touch constants belong to the [poke implementation](../../../lua/lunette-plugins/ui/host/private/poke.luau). They need headset tuning and are not copied defaults here. Their distances remain physical rather than scaling with a panel. A fingertip proxy supplies contact feedback, as [Motion and feedback](motion-and-feedback.md#fingertip-proxy) describes.

## Ray robustness

The laser filters controller motion and locks a sufficiently steady ray while a trigger press begins. Unlock thresholds prevent that lock from blocking a deliberate drag. The mouse does not need trigger-motion filtering. The [laser provider](../../../lua/lunette-plugins/input/laser/README.md) owns the configuration and precise lock behavior.

Trigger-induced movement is a measured source of selection errors. [Research](research.md#ray-pointing-research) records why the lock needs testing against moving as well as stationary presses. Sticky node margins and target selection through proximity hooks are not current host guarantees; [#70](https://github.com/philpax/lunette/issues/70) tracks that extension.

## Scrolling

Ray scroll input routes to the hit node and can bubble through its ancestors. Standard scroll controls also expose visible scrolling affordances and node-handle requests. Drag-to-scroll that competes with a descendant's drag axis needs the deferred gesture resolution in [#69](https://github.com/philpax/lunette/issues/69).

## Focus

Panel focus is separate from session focus. Focusing a text control by a press, traversal, or a focus request takes session focus and shows the shared keyboard. Leaving that text focus ends its keyboard request. Pointer-focus controls can become the panel's focused node without redirecting typing away from a client window. A `none` control, such as a virtual keyboard key, does not take focus. Hover alone never takes focus.

### Focus traversal

Tab and arrows move focus when the focused node does not consume them. Enter and Space activate or engage a value control, and Escape dismisses. Controller traversal applies while no ray points at a host panel. An engaged value control uses directions to adjust its value and permits dismissal to return to navigation. The host exposes traversal requests for other bindings and switch access.

A complete non-pointer path for panel transforms, reordering, drop targets, and other complex operations remains a session requirement. The existence of traversal does not establish that every proposed context-menu alternative is implemented. [#69](https://github.com/philpax/lunette/issues/69) owns the input work that affects those paths.

### Focus scopes and key routing

Keys reach the focused node before ancestor handlers. A text field can consume caret movement while another control leaves an arrow for traversal. The current node and mount contracts do not provide the proposed general roving-group and panel-shortcut registration system. The [focus contract](../../../lua/lunette-contracts/focus.luau) owns held-key delivery and route loss.

## Drag and drop

The session's drop service is separate from host node drags. A drag event does not create typed offers, a ghost portal, or cross-panel drop targets. Promoting a captured node drag and sharing manipulation with other surfaces remain part of [#69](https://github.com/philpax/lunette/issues/69). Bridging a session drag to Wayland also needs a compositor-originated data source.

## Disabled controls

Standard controls use a disabled reason to explain unavailable actions. The reason belongs in semantics and inspection as well as visible help. Prop validation and disabled rendering do not by themselves guarantee that every state change cancels an already-held gesture; kinds must preserve their input invariants when props change.

## The virtual keyboard

The keyboard service is independent of the toolkit host and draws its own keys. A caller places and draws it. Its keys preserve the focused destination, and key ownership and release follow the focus contract. It is not a toolkit panel that inherits all host kinds, depth response, or input-hint layouts automatically.

The [keyboard guide](../../../lua/lunette-plugins/input/keyboard/README.md) and [shared keyboard guarantees](../../../lua/lunette-contracts/panels-and-ui.md#keyboards) own that workflow. A complete text-entry path remains required without a physical keyboard.

## Open questions

- Shared claims, grab spheres, manipulation, and non-pointer alternatives in [#69](https://github.com/philpax/lunette/issues/69).
- Pick hooks and proximity assistance in [#70](https://github.com/philpax/lunette/issues/70).
- Touch input and drag-and-drop bridging to Wayland clients.
- Gaze selection and the hover behavior it requires.
- Near-touch and tracking behavior across runtimes and real headset hardware.
