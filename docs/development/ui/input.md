# Input

The toolkit supports controller rays, tracked hands, and mouse and keyboard equally. Nodes never branch on modality. The interaction service turns physical input into interactors, arbitrates between the interactors of each source, and delivers semantic events to surfaces. The host routes each event through the panel's node tree. Keyboard and controller focus traversal is a separate channel that works without pointing.

The model belongs to the interaction contracts rather than to the toolkit, because window and monitor panels consume the same interactors.

## Sources and interactors

A source is a physical input device: the left hand, the right hand, or the mouse. A hand source is in one of two modes at any moment: it holds a controller, or it is tracked bare. LÖVR exposes one `hand/left` and one `hand/right` device whichever is in use, so a controller and a bare hand on the same side are one source, and their interactors arbitrate together. The mode comes from the `controller` field that `lovr.headset.getSkeleton` reports, with `controllerskeleton` set so that a held controller is distinguishable from a bare hand.

An interactor is one input mechanism of a source:

| Source mode | Interactors |
|---|---|
| Controller | A ray from the controller's aim pose, selected by the trigger, and a grab sphere at the controller, selected by the grip |
| Tracked hand | A poke point at the index fingertip, a pinch ray for distant targets, and a grab sphere at the pinch point for near targets |
| Mouse | A ray from the head through the cursor's projected position, selected by mouse buttons |

An interactor publishes its pose, its shape, a select progress from 0 to 1, and an attach pose. The select progress is the analog trigger, the grip, the pinch strength, or a mouse button's state. The attach pose is where manipulation applies: the ray's hit point with the ray's orientation, the fingertip, or the pinch point.

Tracked-hand interactors use the poses that the runtime computes through XR_EXT_hand_interaction, which LÖVR exposes through `lovr.headset.getHandPose(hand, 'poke')` and `getHandPose(hand, 'pinch')`. Pinch strength is the hand interaction profile's pinch value, which LÖVR binds to the trigger axis, so it is read with `getAxis(hand, 'trigger')`. `getHandPose` returns false when the runtime lacks the extension. The interactors then fall back to the skeleton: the poke point is the index fingertip joint, the pinch point lies between the thumb and index fingertips, pinch strength comes from their distance, and the pinch ray starts at an estimated shoulder position and passes through the pinch point, which is the construction that Meta's Interaction SDK and MRTK use, because a ray from the hand alone shakes with every finger movement. `getSkeleton` allocates a table per joint, so the fallback reads it at most once per hand per frame.

The mouse ray's projection model, host mouse capture, and release belong to #49. The toolkit needs only a ray interactor with buttons, modifiers, scroll, and a visible cursor.

Interactor shapes are an open set, as [Spatial model](spatial-model.md#hit-volumes) describes. A plugin can add a source or an interactor, such as a dwell interactor or a head pointer, as [Extension](extension.md#interaction-extension) describes.

## Arbitration

The interaction service arbitrates the interactors of each source in two passes each frame.

1. Hover candidates. Each interactor queries surfaces with its shape and finds its nearest hit. Registered `pick` hooks can adjust the choice, using the hits and a proximity query that returns the nodes within an angular radius of a ray that missed.
2. Selection. Near beats far. When a hand's poke point or grab sphere is within the near distance of a surface, the same hand's pinch ray is disabled, and it stays disabled until the hand leaves the hover exit distance. The ray's visual follows the arbitration: a disabled ray is hidden. A source has at most one hovering interactor at a time.

Near beats far applies only to idle interactors. An interactor that holds a capture is never disabled by arbitration. A pinch-ray drag that brings the hand within the near distance continues as a ray drag until it ends.

Different sources never arbitrate against each other. Two hands, or a hand and the mouse, each hover and capture independently.

## Surfaces

The surface protocol answers interactor queries with hit records, as [Spatial model](spatial-model.md#hit-volumes) defines. A UI panel answers per node, at each node's elevation and pose, and applies each node's clip, so a ray hits a raised button before the panel behind it, and a fingertip touches the raised button first. A hit record names the node and item, so the interaction service's hover stickiness and capture refer to nodes, not to coordinates.

Window and monitor panels answer ray queries and do not answer point or grab queries, so points do not interact with them. A touch path to Wayland clients is an open question.

## Routing

The host routes each pointer event along the hit path, from the panel root to the hit node:

1. Capture phase. The event visits each ancestor from the root down. An ancestor's `event` handler can stop it.
2. Target. The hit node, or its item, receives the event.
3. Bubble phase. The event visits each ancestor from the target up, until a handler stops it.

The hit path is the logical path. A node inside a portal has its logical parent's path above it, so an event bubbles out of a menu into the dropdown that opened it, and out of a portal into the component that owns it. A press on a card that contains a button reaches the button first, and the card sees it only if the button lets it bubble. A captured gesture's events go to the capturing node without a capture phase.

Key and text events route from the focused node up through its focus scopes, as [Focus](#focus) describes.

The host skips any handler or callback whose effective owner has ended, so a dispatch that unloads a plugin part-way through does not call into it.

## Gesture claims

A press does not decide on its own what the gesture is. Several nodes on the hit path may want the same movement: a slider wants horizontal drags, a list row wants a drag after a hold to reorder, the scroll box around them wants vertical drags, and the panel wants a grab. Kinds declare claims:

- drag along one axis or both, immediately or only after a hold;
- scroll along one axis or both;
- `axis`, the analog thumbstick or touchpad while the node is hovered or focused;
- `transform`, the gesture of several captures on one node;
- `grab`, which hands the capture to the interaction service to move a panel.

A claim can be a function of the node, the hit item, the press, and the time held, evaluated when the gesture resolves. A canvas therefore claims a pan on its background and a move on the item under the press.

When a press begins, the deepest node on the hit path that accepts presses captures the interactor. The gesture resolves when the interactor moves past the drag threshold, or when a hold completes:

- The deepest node on the hit path whose claim covers the movement wins the gesture.
- If the winner is not the node that captured the press, the capturing node receives `cancel` with the reason `claimed`, and capture transfers to the winner. The transfer keeps the press's depth reference and frame, so a touch drag that a scroll box claims from a raised row continues with the same depth.
- A scroll box claims only the axes that no node beneath it on the hit path claims, so a horizontal slider inside a vertical list keeps horizontal drags, and a vertical drag on the slider scrolls the list.
- A drag-after-hold claim does not compete with movement before the hold completes, so a list whose rows reorder after a hold still scrolls with an immediate drag.

Hold, context, and drag-after-hold are ordered by duration. Each kind declares its hold duration. A kind that consumes `hold`, such as a hold-to-confirm button, suppresses `context` for its presses.

The drag threshold is measured along the surface for bent nodes, and in the scene for rigid nodes, so pulling a gizmo handle towards the viewer resolves too. A captured drag can become a drag session without losing its capture, through `node:promote(offers)`, so reordering a row within a list can continue as a drag to another panel.

A scroll gesture holds its scroll box until it ends. When the inner scroll box reaches its end during a gesture, the gesture does not pass to an outer box. The next gesture can.

### Panel manipulation

Moving a panel is a gesture with the lowest precedence. A press on a panel's grab handle, on its frame, or on a part of its body that no node claims becomes a panel grab when it moves past the drag threshold. A controller's grip grabs a panel from anywhere on it, because it never presses a node. A tracked hand grabs a panel within reach with its grab sphere, by pinching near the panel's frame or grab handle, and a panel out of reach through its grab handle with the pinch ray.

A grabbed panel follows the grabbing interactor's attach pose in position and orientation. Distance changes with it: a hand moves the panel nearer or further by moving, a controller's thumbstick pushes and pulls while grabbing, and the mouse moves it with the wheel while a modifier is held.

Resize frames and curvature handles are toolkit kinds on the panel's frame. They are drawn in an attached panel around the content panel, so the content's clip does not cut their hit volume. A window panel has two resize affordances, because #8 and #47 distinguish them: one scales the panel, and one resizes the client's content. A content resize frame emits resize proposals that the consumer applies, and it follows the size the client commits rather than the size it requested.

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
| `hold` | Hold progress for a press that has not moved, from 0 to 1 over the kind's hold duration. Hold-to-confirm buttons act on this |
| `cancel` | A captured gesture ends without activation, with a reason |
| `drag-start`, `drag`, `drag-end` | A captured interactor moved past the drag threshold, or a drag-after-hold claim won |
| `transform` | Translation, scale, and rotation from several captures on a node that accepts them |
| `scroll` | A scroll delta in metres along the surface |
| `axis` | An analog two-axis value from a thumbstick or touchpad, for a node that claims it |
| `navigate` | A direction from focus traversal, for the focused node to use before focus moves |
| `focus`, `blur` | Focus moves to or from the node |
| `key`, `text` | Keyboard input to the focused node |

Every pointer event carries:

- the local position on the node, and the item id when the node publishes items;
- the interactor's source, its mode, and the button or action;
- the modifier keys held, from the keyboard focus route;
- the select progress;
- the world-space ray or point and the attach pose, so a gizmo or a manipulation handle can constrain movement in the scene;
- for point interactors, the press depth;
- for drags, the delta and a filtered velocity.

Drag positions are computed in the captured node's frame as it was when the drag started: on its surface at its elevation for a bent node, and in its frame for a rigid node. Content that reflows or a node that moves during the drag does not change the values a stationary interactor produces, and a drag on a curved panel stays under the finger or ray. Drag deltas start from the pose at which the trigger lock released, so a drag does not jump when the lock lets go.

Hover is continuous as well as discrete. While an interactor hovers a node, the node's state holds a hover record per interactor, updated every frame without a render: the source, the local point, the signed distance for a point interactor or the angular offset for a ray, and the select progress. The shader reads the same values through bound parameters, as [Rendering](rendering.md#bound-parameters) describes, so a proximity glow or a fingertip shadow follows the finger every frame.

Hold, long-press, and tooltip durations are multiplied by the accessibility timing setting.

Behaviour is the same for every interactor. A node reads press depth and hover distance only for visual feedback.

## Capture and cancellation

A node captures an interactor's button on press and keeps it through movement and release, even while another node or surface is hovered. Each button of an interactor captures independently, so a right press during a left drag is a separate press. A captured node refuses other interactors unless its kind accepts several captures.

A capture ends with `cancel` and a reason in these cases:

| Cause | Reason |
|---|---|
| The node is removed or re-keyed | `removed` |
| The node becomes disabled | `disabled` |
| The node's panel is hidden, or its overlay is dismissed | `hidden` |
| Another node on the hit path wins the gesture | `claimed` |
| The panel is grabbed | `grabbed` |
| The interactor's source stays untracked for longer than the grace period, or is disposed | `source-lost` |
| A point interactor slides beyond the cancel distance while pressed, before any claim has won | `slid-off` |
| Escape or the dismissal action while the gesture is live | `dismissed` |

A move or relayout of the captured node does not cancel, and neither does a change of the panel's pose. A button whose capture was cancelled stays blocked until it is released, so a re-enabled node under a held trigger does not receive a press. Source loss also releases every key that the source's route holds, as the keyboard routing contract requires.

## Near touch

A point interactor activates by depth. The default values are starting points for tuning in a headset, not values taken from a published source:

| Parameter | Default | Purpose |
|---|---|---|
| Hover entry distance | 30 mm in front of the surface | The node shows hover before contact |
| Hover exit distance | 50 mm | Hysteresis prevents flicker at the boundary |
| Activation depth | 2 mm into the surface | Selection starts |
| Release depth | 1 mm | Selection ends; a lower release than activation depth allows fast repeated presses |
| Drag threshold | 10 mm along the surface | A press becomes a drag only after this movement |
| Cancel distance | 30 mm along the surface while pressed | Sliding off a pressed control cancels it, until a claim wins |
| Tracking grace period | 150 ms | A brief tracking loss neither cancels nor re-arms a press |

These are physical distances. They do not scale with the presentation's scale, because a fingertip's movement does not change when a panel is shown larger.

Depth is measured against the pressed node's rest surface: its elevation without hover lift or press travel, fixed when hover begins and kept for the whole gesture, including after a capture transfer. While the fingertip is in contact, the node's press travel follows its depth, clamped to the available travel, rather than animating towards a fixed target, so the face moves with the finger. The activation depth is less than the available press travel, so the press registers before the face reaches the surface beneath it.

A press requires the point to enter the hover zone from the front, moving towards the surface relative to the panel. Relative movement counts, so bringing a wrist panel to a still fingertip presses as moving the finger to the panel does. A point that appears inside the zone after a tracking loss longer than the grace period, or that enters it from the side or from behind, cannot press until it retreats beyond the hover exit distance.

The hand's rendered fingertip is clamped to the visual surface from first contact, so the finger does not appear to pass through the control or the panel. The clamp is a visual change to the hand model and does not affect tracking.

Targets for touch need more area than targets for rays. [Theming](theming.md#target-sizes) sets the token sizes.

## Ray robustness

Pressing a trigger moves the controller, and the ray moves with it. Wolf and colleagues attribute a large share of ray selection errors to this movement, as [Research](research.md#ray-pointing-research) describes. The interaction service applies these mitigations to every controller and pinch ray:

- An adaptive filter, the one-euro filter, smooths the ray while keeping fast movements responsive. Its parameters are part of the laser's configuration.
- The ray locks during a press. When the select progress passes the lock threshold, and the ray moved less than the unlock angle and the unlock distance since the previous frame, the ray holds the previous frame's pose until release. Moving the ray beyond those limits releases the lock and resumes aiming. The release frame keeps the locked pose, so releasing does not move a click onto a neighbour. The limits are 3 degrees and 3 cm per frame by default, so the lock engages on almost every press.
- Hover is sticky. Once a node is hovered, the ray keeps hovering it until the ray leaves the node by a small angular margin.
- A drag starts only after the ray moves past an angular threshold from the press position, which is at least the unlock angle.

A controller's trigger presses at the runtime's button threshold. Pinch strength is analog and often rests above zero, so a pinch has its own press and release thresholds with hysteresis, and the trigger lock arms relative to the pinch's press threshold rather than at a fixed small value. Noise around a threshold therefore neither double-activates nor spends the lock before the real pinch.

The mouse ray is exempt from filtering and the trigger lock, because a mouse does not move when its button is pressed, and filtering would add cursor lag. The cursor and the ray draw from the latest pose.

Activation happens on release inside the pressed node, and release outside cancels, for every pointer interactor. A kind can act on `press` instead. The virtual keyboard's keys do, as described below.

## Scrolling

Scroll boxes accept four inputs:

- Thumbstick and touchpad deflection while the source's ray hovers the box, mapped to a scroll rate with a dead zone and acceleration.
- Mouse wheel and trackpad deltas.
- Drag-to-scroll, through the gesture claims above.
- The scroll box's thumb and track, as [Layout and text](layout-and-text.md#scrolling) describes.

Scroll events route along the hit path like other pointer events, so a node that claims scroll on an axis, such as a volume slider or a zoomable canvas, receives the wheel before the scroll box around it. A scroll event that no node claims goes to the innermost scroll box that can move in its direction when the gesture starts.

## Focus

Every focusable node takes part in focus traversal, and a panel has at most one focused node. Focus within a panel is separate from session focus, which decides where keyboard input goes. A kind declares one of three focus policies:

- `text`: the kind takes session focus when pressed, so the keyboard route moves to the panel and its focused field.
- `pointer`: most focusable kinds, such as buttons, toggles, and sliders, become the panel's focused node when pressed but do not take session focus. Clicking a toggle in a settings panel therefore leaves typing going to the terminal the user was typing in. A press on such a node does not take panel focus away from a focused text field in the same panel, so pressing a filter chip beside a search field leaves typing in the field.
- `none`: the kind never becomes focused, such as the virtual keyboard's keys. A panel built only from such kinds never takes session focus.

A panel takes session focus when traversal enters it, when a text-input node in it is pressed, or when it is summoned with focus. A presentation declares whether showing a panel takes focus. Hiding a panel releases its session focus, so typing never goes into an invisible field.

An overlay shares its opener's session focus target, as [Presentations](presentations.md#focus) describes. Key events go to the focused node of the innermost overlay in the chain that has one, and otherwise to the opener panel's focused node.

### Focus traversal

- Sequential traversal follows tree order. Tab and Shift-Tab move focus on a keyboard.
- Directional traversal moves to the nearest focusable node in a direction, as [Spatial model](spatial-model.md#directional-focus-traversal) defines. Arrow keys move focus on a keyboard.
- Activation triggers the focused node. Enter and Space activate on a keyboard. Holding the activation drives `hold`, so a hold-to-confirm button works without pointing.
- The context action opens the focused node's context menu. The Menu key and Shift-F10 invoke it on a keyboard.
- Dismissal closes the innermost overlay, pops a navigation stack, or leaves a text field. Escape dismisses on a keyboard.

On a controller, traversal applies to the panel that holds session focus, while the source's ray does not hover any surface and no panel is grabbed. The thumbstick navigates, the primary face button activates, the secondary face button dismisses, and a thumbstick click opens the context action. While the ray hovers a surface, the thumbstick scrolls as described above, and while a panel is grabbed, it pushes and pulls the panel. A separate binding moves session focus to the next toolkit panel, so a user whose focus is on a window can reach a panel without pointing. The bindings are defaults in the bindings service, so a configuration can remap them.

A direction goes to the focused node as a `navigate` event first, then bubbles through its focus scopes, and moves focus only if no node uses it. A focused slider therefore changes its value when the thumbstick is pushed sideways, a stepper steps, and a radio group moves its selection.

Traversal is a public service on the host: `navigate(direction)`, `activate()` with press and release forms, `context()`, `dismiss()`, and `nextPanel()`. A plugin can drive it from other bindings, add a dedicated traversal mode, or connect switch access, without changes to the toolkit.

Every action that a pointer can take has a traversal path:

- A panel's frame offers Move, Resize, and Curve in its context menu, each adjusted with the thumbstick until confirmed.
- Reorderable rows offer Move up and Move down in their context menus.
- Multi-select lists offer a selection mode in which activation toggles rows, because modifier keys are not available without a keyboard.
- Toast actions are also available from the notification history panel.

The focused node shows a focus ring only while focus came from traversal, not from a pointer press, in the manner of the web's `:focus-visible`.

### Focus scopes and key routing

A focus scope is a node that groups focusable descendants. A key event goes first to the focused node, then bubbles through the scopes that contain it, and reaches traversal only if no node handles it. A slider handles left and right itself, a text field handles arrows for its caret, and traversal receives an arrow only when the focused node does not use it.

A roving group is a scope that is one stop for sequential traversal, with arrows moving within it. Radio groups, segmented controls, tab bars, toolbars, and tree views are roving groups. A scope remembers its last focused child, so returning to the scope or popping a navigation stack restores focus where it was.

A panel can register shortcuts, which receive a key before the focused node when their modifiers match. Ctrl-F focusing a search field is a shortcut.

## Drag and drop

A drag session carries a payload from one node to another, including across panels. A node starts a session from a drag gesture, or promotes a captured drag into one, with typed offers: MIME types for data that may leave the session, and in-process values for data that stays inside it. While the session is live, the interactor keeps querying every surface, and the interaction service delivers `drag-enter`, `drag-over`, `drag-leave`, and `drop` to the surfaces and nodes under it. A node accepts a drop by declaring the offers it takes. The dragged ghost is a portal at popover elevation that follows the attach pose. A scroll box auto-scrolls while a drag hovers near its edge. A session ends when its source's owner ends, and its in-process values are released with it.

Drag sessions belong to the interaction contracts. A window surface can bridge a session to a Wayland drag, which needs a compositor-originated data source; that bridge is an open question.

## Disabled controls

A node with a `disabledReason` prop is disabled and shows the reason in a tooltip. The tooltip appears on ray hover, on point hover in front of the surface, and on focus through traversal, so it is reachable by every interactor and without pointing. Inspection reports the reason, so tests can assert it.

## The virtual keyboard

The virtual keyboard is a toolkit panel built from toolkit kinds. Typing by poking is the clearest use of near touch, and the keyboard gets depth, press travel that follows the finger, and hover in front of the surface from the toolkit. Its keys have the `none` focus policy, so poking a key never moves session focus away from the field it types into. Its layout follows the focused field's input hint.

A key sends a key-down when it is pressed and a key-up when it is released or its capture is cancelled. The receiver repeats a held key: a Wayland client through the repeat information that the compositor already sends, and a toolkit field through the focus service, at the same delay and rate. The keyboard therefore never repeats a key itself, and a client never sees doubled repeats. The keyboard's paste key pastes from the session clipboard into the focused field.

Its key layout is the keyboard plugin's data. Text entry into toolkit fields goes through the session focus service, which maps keys to text with the session keymap, and does not depend on a Wayland seat.

## Open questions

- A touch path from point interactors to Wayland clients, through the Wayland touch protocol or through emulated pointer events.
- A bridge from drag sessions to Wayland drags, which needs a compositor-originated data source.
- Whether gaze is an interactor. Eye tracking is not available on every headset, and gaze with pinch needs a different hover model.
- Whether `getHandPose`, `getSkeleton`, and the hand interaction profile work in an XR_EXTX_overlay session on the session's runtime, and whether haptics do.
- The near distance, the grab sphere's radius, the pinch thresholds, and the one-euro filter parameters for tracked hands, which need tuning in a headset.
