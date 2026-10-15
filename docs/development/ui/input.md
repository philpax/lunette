# Input

The toolkit supports controller rays, tracked hands, and mouse and keyboard equally. Nodes never branch on modality. The interaction service turns physical input into interactors, arbitrates between the interactors of each source, and delivers semantic events to surfaces. The host routes each event through the panel's node tree. Keyboard and controller focus traversal is a separate channel that works without pointing.

The model belongs to the interaction contracts rather than to the toolkit, because window and monitor panels consume the same interactors.

## Sources and interactors

A source is a physical input device: the left hand, the right hand, or the mouse. A hand source is in one of two modes at any moment: it holds a controller, or it is tracked bare. LÖVR exposes one `hand/left` and one `hand/right` device whichever is in use, so a controller and a bare hand on the same side are one source, and their interactors arbitrate together.

An interactor is one input mechanism of a source:

| Source mode | Interactors |
|---|---|
| Controller | A ray from the controller's aim pose, selected by the trigger |
| Tracked hand | A poke point at the index fingertip, and a pinch ray for distant targets |
| Mouse | A ray from the head through the cursor's projected position, selected by mouse buttons |

An interactor publishes its pose, its shape, a select progress from 0 to 1, and an attach pose. The select progress is the analog trigger, the pinch strength, or a mouse button's state. The attach pose is where manipulation applies: the ray's hit point with the ray's orientation, or the fingertip.

Tracked-hand interactors use the poses that the runtime computes through XR_EXT_hand_interaction, which LÖVR exposes as `hand/left/poke`, `hand/left/pinch`, and the corresponding right-hand devices, with pinch strength from the same extension. Where the runtime lacks the extension, the poke point is the index fingertip joint from `lovr.headset.getSkeleton`, and the pinch ray starts at an estimated shoulder position and passes through a point between the thumb and index finger, which is the construction that Meta's Interaction SDK and MRTK use, because a ray from the hand alone shakes with every finger movement. `getSkeleton` allocates a table per joint, so the fallback reads it at most once per hand per frame.

The mouse ray's projection model, host mouse capture, and release belong to #49. The toolkit needs only a ray interactor with buttons, modifiers, scroll, and a visible cursor.

Interactor shapes are an open set, as [Spatial model](spatial-model.md#hit-volumes) describes. A plugin can add a source or an interactor, such as a dwell interactor or a head pointer, as [Extension](extension.md#interaction-extension) describes.

## Arbitration

The interaction service arbitrates the interactors of each source in two passes each frame.

1. Hover candidates. Each interactor queries surfaces with its shape and finds its nearest hit. The `pick` hook can adjust the choice.
2. Selection. Near beats far. When a hand's poke point is within the near distance of a surface, the same hand's pinch ray is disabled, and it stays disabled until the point leaves the hover exit distance. A source has at most one hovering interactor at a time.

Near beats far applies only to idle interactors. An interactor that holds a capture is never disabled by arbitration. A pinch-ray drag that brings the hand within the near distance continues as a ray drag until it ends.

Different sources never arbitrate against each other. Two hands, or a hand and the mouse, each hover and capture independently.

## Surfaces

The surface protocol answers interactor queries with hit records, as [Spatial model](spatial-model.md#hit-volumes) defines. A UI panel answers per node, at each node's elevation and pose, and applies each node's clip, so a ray hits a raised button before the panel behind it, and a fingertip touches the raised button first. A hit record names the node and item, so the interaction service's hover stickiness and capture refer to nodes, not to coordinates.

Window and monitor panels answer ray queries and do not answer point queries, so points do not interact with them. A touch path to Wayland clients is an open question.

## Routing

The host routes each pointer event along the hit path, from the panel root to the hit node:

1. Capture phase. The event visits each ancestor from the root down. An ancestor's `event` handler can stop it.
2. Target. The hit node, or its item, receives the event.
3. Bubble phase. The event visits each ancestor from the target up, until a handler stops it.

A press on a card that contains a button therefore reaches the button first, and the card sees it only if the button lets it bubble. A captured gesture's events go to the capturing node without a capture phase.

Key and text events route from the focused node up through its focus scopes, as [Focus](#focus) describes.

## Gesture claims

A press does not decide on its own what the gesture is. Several nodes on the hit path may want the same drag: a slider wants horizontal drags, a list row wants a long press to reorder, the scroll box around them wants vertical drags, and the panel wants a grab. Kinds declare their claims at registration: drag along one axis or both, scroll along one axis or both, and the transform gesture of several captures.

When a press begins, the deepest node on the hit path that accepts presses captures the interactor. When the interactor moves past the drag threshold, the host resolves the gesture:

- The deepest node on the hit path whose claim covers the direction of movement wins the drag.
- If the winner is not the node that captured the press, the capturing node receives `cancel` with the reason `claimed`, and capture transfers to the winner.
- A scroll box claims only the axes that no node beneath it on the hit path claims, so a horizontal slider inside a vertical list keeps horizontal drags, and a vertical drag on the slider scrolls the list.

A scroll gesture holds its scroll box until it ends. When the inner scroll box reaches its end during a gesture, the gesture does not pass to an outer box. The next gesture can.

### Panel manipulation

Moving a panel is a gesture with the lowest precedence. A press on a panel's grab handle, on its frame, or on a part of its body that no node claims becomes a panel grab when it moves past the drag threshold. A controller's grip button grabs a panel from anywhere on it, because it never presses a node. A tracked hand has no grip button, so panels that hands operate have a visible grab handle, and hands move panels through it. Resize frames and curvature handles are toolkit kinds on the panel's frame, so they are hit-tested, routed, and inspected like any other node.

Two-handed scaling of a panel and a kind that accepts several captures, such as a zoomable canvas, compete for the same pair of interactors. The kind wins inside its bounds, and the panel wins elsewhere.

## Semantic events

The host delivers these events to nodes:

| Event | Meaning |
|---|---|
| `hover-enter`, `hover-leave` | An interactor starts or stops hovering the node |
| `press` | Selection starts on the node and the node captures the interactor |
| `release` | Selection ends, with `inside` saying whether the interactor is still over the node |
| `activate` | A primary press and release inside the node, without a drag. Buttons act on this |
| `context` | The secondary action: a right mouse button press, a long press, or the controller's context binding. Context menus open on this |
| `hold` | Hold progress for a press that has not moved, from 0 to 1 over the hold duration. Hold-to-confirm buttons act on this |
| `cancel` | A captured gesture ends without activation, with a reason |
| `drag-start`, `drag`, `drag-end` | A captured interactor moved past the drag threshold |
| `transform` | Translation, scale, and rotation from several captures on a node that accepts them |
| `scroll` | A scroll delta in metres along local axes |
| `axis` | An analog two-axis value from a thumbstick or touchpad, for a node that claims it |
| `focus`, `blur` | Focus moves to or from the node |
| `key`, `text` | Keyboard input to the focused node |

Every pointer event carries:

- the local position on the node, and the item id when the node publishes items;
- the interactor's source, its mode, and the button or action;
- the modifier keys held, from the keyboard focus route;
- the select progress;
- the world-space ray or point and the attach pose, so a gizmo or a manipulation handle can constrain movement in world space;
- for point interactors, the press depth;
- for drags, the delta and a filtered velocity.

Drag positions are projected onto the plane of the captured node, fixed at the press, so a drag on a raised node does not jump by the node's elevation.

Hover is continuous as well as discrete. While an interactor hovers a node, the node's state holds a hover record per interactor, updated every frame without a render: the source, the local point, the signed distance for a point interactor or the angular offset for a ray, and the select progress. Visuals read it to draw a proximity glow, a fingertip shadow, or a highlight that follows the pointer.

Behaviour is the same for every interactor. A node reads press depth and hover distance only for visual feedback.

## Capture and cancellation

A node captures an interactor on press and keeps it through movement and release, even while another node or surface is hovered. A captured node refuses other interactors unless its kind accepts several captures.

A capture ends with `cancel` and a reason in these cases:

| Cause | Reason |
|---|---|
| The node is removed or re-keyed | `removed` |
| The node becomes disabled | `disabled` |
| The node's panel is hidden, or its overlay is dismissed | `hidden` |
| Another node on the hit path wins the gesture | `claimed` |
| The panel is grabbed | `grabbed` |
| The interactor's source loses tracking or is disposed | `source-lost` |
| A point interactor slides beyond the cancel distance while pressed | `slid-off` |
| Escape or the dismissal action while the gesture is live | `dismissed` |

A move or relayout of the captured node does not cancel, and neither does a change of the panel's pose. A node that moves under a captured interactor keeps the capture, and its drag positions follow it. Source loss also releases every key that the source's route holds, as the keyboard routing contract requires.

## Near touch

A point interactor activates by depth. The default values are starting points for tuning in a headset, not values taken from a published source:

| Parameter | Default | Purpose |
|---|---|---|
| Hover entry distance | 30 mm in front of the surface | The node shows hover before contact |
| Hover exit distance | 50 mm | Hysteresis prevents flicker at the boundary |
| Activation depth | 5 mm into the surface | Selection starts |
| Release depth | 2 mm | Selection ends; a lower release than activation depth allows fast repeated presses |
| Drag threshold | 10 mm along the surface | A press becomes a drag only after this movement |
| Cancel distance | 30 mm along the surface while pressed | Sliding off a pressed control cancels it |

These are physical distances. They do not scale with the presentation's scale, because a fingertip's movement does not change when a panel is shown larger.

Depth is measured against the node's rest surface: its elevation without hover lift or press travel, fixed when hover begins. Press travel moves the visual surface away from the fingertip, and measuring against it would release the node, raise it, and press it again in a loop.

A press requires the point to enter the hover zone from the front, moving towards the surface. A point that appears inside the zone after tracking loss, that enters it from the side or from behind, or that a moving panel brings into contact, cannot press until it retreats beyond the hover exit distance.

The hand's rendered fingertip is clamped to the visual surface while pressing, so the finger does not appear to pass through the panel. The clamp is a visual change to the hand model and does not affect tracking.

Targets for touch need more area than targets for rays. [Theming](theming.md#target-sizes) sets the token sizes.

## Ray robustness

Pressing a trigger moves the controller, and the ray moves with it. Wolf and colleagues attribute about 30 percent of ray selection errors to this movement, as [Research](research.md#ray-pointing-research) describes. The interaction service applies these mitigations to every controller and pinch ray:

- An adaptive filter, the one-euro filter, smooths the ray while keeping fast movements responsive. Its parameters are part of the laser's configuration.
- The ray locks during a trigger pull. When the select progress passes a small threshold, and the ray moved less than an unlock angle and an unlock distance since the previous frame, the ray holds that previous frame's pose until release. Moving the ray deliberately beyond those limits releases the lock and resumes aiming. The release frame keeps the locked pose, so releasing does not move a click onto a neighbour. Locking only a nearly stationary ray matters: a ray that is still moving towards its target when the trigger starts to move has not reached it yet.
- Hover is sticky. Once a node is hovered, the ray keeps hovering it until the ray leaves the node by a small angular margin.
- A drag starts only after the ray moves past an angular threshold from the press position.

The mouse ray is exempt from filtering and the trigger lock, because a mouse does not move when its button is pressed, and filtering would add cursor lag. The cursor and the ray draw from the latest pose.

Activation happens on release inside the pressed node, and release outside cancels, for every pointer interactor. A kind can act on `press` instead. The virtual keyboard's keys do, as described below.

## Scrolling

Scroll boxes accept three inputs:

- Thumbstick and touchpad deflection while the source's ray hovers the box, mapped to a scroll rate with a dead zone and acceleration.
- Mouse wheel and trackpad deltas.
- Drag-to-scroll, through the gesture claims above.

Scroll events route along the hit path like other pointer events, so a node that claims scroll on an axis, such as a volume slider or a zoomable canvas, receives the wheel before the scroll box around it. A scroll event that no node claims goes to the innermost scroll box that can move in its direction when the gesture starts.

## Focus

Every focusable node takes part in focus traversal, and a panel has at most one focused node. Focus within a panel is separate from session focus, which decides where keyboard input goes. A kind declares one of three focus policies:

- Text-input kinds take session focus when pressed, so the keyboard route moves to the panel and its focused field.
- Most focusable kinds, such as buttons, toggles, and sliders, become the panel's focused node when pressed but do not take session focus. Clicking a toggle in a settings panel therefore leaves typing going to the terminal the user was typing in.
- Non-focusing kinds, such as the virtual keyboard's keys, never become focused. A panel built only from them never takes session focus.

A panel takes session focus when traversal enters it, when a text-input node in it is pressed, or when it is summoned with focus. A presentation declares whether showing a panel takes focus. Toasts never do.

### Focus traversal

- Sequential traversal follows tree order. Tab and Shift-Tab move focus on a keyboard.
- Directional traversal moves to the nearest focusable node in a direction, as [Spatial model](spatial-model.md#directional-focus-traversal) defines. Arrow keys move focus on a keyboard.
- Activation triggers the focused node. Enter and Space activate on a keyboard.
- Dismissal closes the innermost overlay or leaves a text field. Escape dismisses on a keyboard.

On a controller, traversal applies to the panel that holds session focus, while the source's ray does not hover any surface and no panel is grabbed. The thumbstick moves focus directionally, the primary face button activates, and the secondary face button dismisses. While the ray hovers a surface, the thumbstick scrolls as described above, and while a panel is grabbed, it pushes and pulls the panel. The bindings are defaults in the bindings service, so a configuration can remap them.

Traversal is a public service on the host: `moveFocus(direction)`, `activateFocused()`, and `dismiss()`. A plugin can drive it from other bindings, add a dedicated traversal mode, or connect switch access, without changes to the toolkit.

The focused node shows a focus ring only while focus came from traversal, not from a pointer press, in the manner of the web's `:focus-visible`.

### Focus scopes and key routing

A focus scope is a node that groups focusable descendants. A key event goes first to the focused node, then bubbles through the scopes that contain it, and reaches traversal only if no node handles it. A slider handles left and right itself, a text field handles arrows for its caret, and traversal receives an arrow only when the focused node does not use it.

A roving group is a scope that is one stop for sequential traversal, with arrows moving within it. Radio groups, segmented controls, tab bars, toolbars, and tree views are roving groups. A scope remembers its last focused child, so returning to the scope or popping a navigation stack restores focus where it was.

A panel can register shortcuts, which receive a key before the focused node when their modifiers match. Ctrl-F focusing a search field is a shortcut.

## Drag and drop

A drag session carries a payload from one node to another, including across panels. A node starts a session from a drag gesture with typed offers: MIME types for data that may leave the session, and in-process values for data that stays inside it. While the session is live, the interactor keeps querying every surface, and the interaction service delivers `drag-enter`, `drag-over`, `drag-leave`, and `drop` to the surfaces and nodes under it. A node accepts a drop by declaring the offers it takes. The dragged ghost is a portal at popover elevation that follows the attach pose. A scroll box auto-scrolls while a drag hovers near its edge.

Drag sessions belong to the interaction contracts. A window surface can bridge a session to a Wayland drag, which needs a compositor-originated data source; that bridge is an open question.

## Disabled controls

A node with a `disabledReason` prop is disabled and shows the reason in a tooltip. The tooltip appears on ray hover, on point hover in front of the surface, and on focus through traversal, so it is reachable by every interactor and without pointing. Inspection reports the reason, so tests can assert it.

## The virtual keyboard

The virtual keyboard is a toolkit panel built from toolkit kinds. Typing by poking is the clearest use of near touch, and the keyboard gets depth, press travel, and hover in front of the surface from the toolkit. Its keys are non-focusing, so poking a key never moves session focus away from the field it types into. Keys act on `press`, not on activation, and repeat while held, as a physical keyboard's keys do. Its key layout is the keyboard plugin's data. Text entry into toolkit fields goes through the session focus service and does not depend on a Wayland seat.

## Open questions

- A touch path from point interactors to Wayland clients, through the Wayland touch protocol or through emulated pointer events.
- A bridge from drag sessions to Wayland drags, which needs a compositor-originated data source.
- Whether gaze is an interactor. Eye tracking is not available on every headset, and gaze with pinch needs a different hover model.
- Whether `getSkeleton` and the XR_EXT_hand_interaction actions work in an XR_EXTX_overlay session on the session's runtime.
- The near distance, the trigger lock thresholds for the pinch ray, and the one-euro filter parameters for tracked hands, which need tuning in a headset.
