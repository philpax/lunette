# Input

The toolkit supports controller rays, tracked hands, and mouse and keyboard equally. Nodes never branch on modality. The interaction service turns physical input into interactors, arbitrates between the interactors of each source, and delivers semantic events to surfaces. The host routes each event through the panel's node tree. Keyboard and controller focus traversal is a separate channel that works without pointing.

The model belongs to the interaction contracts rather than to the toolkit, because window and monitor panels consume the same interactors.

## Sources and interactors

A source is a physical input device: the left hand, the right hand, or the mouse. A hand source is in one of two modes at any moment: it holds a controller, or it is tracked bare. LÖVR exposes one `hand/left` and one `hand/right` device whichever is in use, so a controller and a bare hand on the same side are one source, and their interactors arbitrate together. Where the runtime supports XR_EXT_hand_tracking_data_source, the mode comes from the `controller` field that `lovr.headset.getSkeleton` reports. Elsewhere, a hand source is in controller mode while the runtime reports a controller interaction profile for it, and in hand mode otherwise.

An interactor is one input mechanism of a source:

| Source mode | Interactors |
|---|---|
| Controller | A ray from the controller's aim pose, selected by the trigger for pressing and by the grip for grabbing; a grab sphere at the controller, selected by the grip; and an optional poke point at the controller's tip |
| Tracked hand | A poke point at the index fingertip, a pinch ray for distant targets, and a grab sphere at the pinch point for near targets |
| Mouse | A ray from the head through the cursor's position, selected by mouse buttons |

An interactor publishes its pose, its shape, a select progress from 0 to 1, and an attach pose. The select progress is the analog trigger, the grip, the pinch strength, or a mouse button's state. The attach pose is where manipulation applies: the ray's hit point with the ray's orientation, the fingertip, or the pinch point.

Tracked-hand interactors use the poses that the runtime computes through XR_EXT_hand_interaction, which LÖVR exposes through `lovr.headset.getHandPose(hand, 'poke')` and `getHandPose(hand, 'pinch')`. Pinch strength is the hand interaction profile's pinch value, which LÖVR binds to the trigger axis, so it is read with `getAxis(hand, 'trigger')`. `getHandPose` returns zeros when the pose is unavailable, whether because the runtime lacks the extension or because the pose is untracked. The interactors then fall back to the skeleton: the poke point is the index fingertip joint, the pinch point lies between the thumb and index fingertips, pinch strength comes from their distance, and the pinch ray starts at an estimated shoulder position and passes through the pinch point, which is the construction that Meta's Interaction SDK and MRTK use, because a ray from the hand alone shakes with every finger movement. `getSkeleton` allocates a table per joint, so the fallback reads it at most once per hand per frame.

The mouse ray starts at the head. Its projection model, host mouse capture, and release belong to #49. The toolkit needs only a ray interactor with buttons, modifiers, scroll, and a visible cursor.

Interactor shapes are an open set, as [Spatial model](spatial-model.md#hit-volumes) describes. A plugin can add a source or an interactor, such as a dwell interactor or a head pointer, as [Extension](extension.md#interaction-extension) describes.

## The interaction pass

The interaction service runs one interaction pass per frame. It collects samples from every interactor provider, such as the laser and hand-pointer plugins, runs the `beforePick` hooks, gathers the surfaces offered at that point, picks and arbitrates for every interactor, delivers events, and runs the `afterDelivery` hooks once. A surface that a commit in `beforePick` offers, such as a newly opened overlay, is therefore part of the same frame's picking, and every source's events are delivered against the same tree.

## Arbitration

The interaction service arbitrates the interactors of each source in two steps.

1. Hover candidates. Each interactor queries surfaces with its shape and finds its nearest hit. Registered `pick` hooks can adjust the choice, using the hits and a proximity query that returns the nodes within an angular radius of a ray that missed.
2. Selection. Near beats far. When a hand's poke point or grab sphere is within the near distance of a surface, the same hand's pinch ray is disabled, and it stays disabled until the hand leaves the hover exit distance. A source has at most one hovering interactor at a time. Between a hand's poke point and its grab sphere, the grab sphere hovers nodes that claim `grab` or `manipulate`, and the poke point hovers everything else; a rising pinch on the grab sphere takes over from an idle poke hover. The ray's visual follows the arbitration: a disabled ray is hidden.

Near beats far applies only to idle interactors. An interactor that holds a capture is never disabled by arbitration. A pinch-ray drag that brings the hand within the near distance continues as a ray drag until it ends.

Different sources never arbitrate against each other. Two hands, or a hand and the mouse, each hover and capture independently.

## Surfaces

The surface protocol answers interactor queries with hit records, as [Spatial model](spatial-model.md#hit-volumes) defines, and publishes the surface's shape in metres. A UI panel answers per node, at each node's drawn elevation and pose, and applies each node's clip, so a ray hits a raised button before the panel behind it, and a fingertip touches the raised button first. A hit record names the node and item, so the interaction service's hover stickiness and capture refer to nodes, not to coordinates.

Window and monitor panels answer ray queries and do not answer point or grab queries, so points do not interact with them. A touch path to Wayland clients is an open question.

## Routing

The host routes each pointer event along the hit path within the hit panel, from the panel root to the hit node:

1. Capture phase. The event visits each ancestor from the root down. An ancestor's `event` handler can stop it.
2. Target. The hit node, or its item, receives the event.
3. Bubble phase. The event visits each ancestor from the target up, until a handler stops it.

Gesture claims and the capture phase use this physical path only. A scroll box in the panel that opened a dropdown therefore cannot claim a drag that starts inside the dropdown, and the opener's handlers cannot stop presses in another panel. The semantic results of a gesture, `activate`, `context`, `change`, and `navigate`, and key events continue past the panel root along the logical path, so they bubble out of a menu into the dropdown that opened it, and out of a portal into the component that owns it. A press on a card that contains a button reaches the button first, and the card sees it only if the button lets it bubble. A captured gesture's events go to the capturing node without a capture phase.

Key and text events route from the focused node up through its focus scopes, as [Focus](#focus) describes.

The host skips any handler, callback, queued mount, scheduled render, or timer whose effective owner has ended, so work that outlives its plugin does not call into it.

## Gesture claims

A press does not decide on its own what the gesture is. Several nodes on the hit path may want the same movement: a slider wants horizontal drags, a list row wants a drag after a hold to reorder, the scroll box around them wants vertical drags, and the panel wants a grab. Kinds declare claims:

- drag along one axis or both, immediately or only after a hold;
- scroll along one axis or both;
- `axis`, the analog thumbstick or touchpad while the node is hovered, or focused and engaged;
- `transform`, the gesture of several captures on one node;
- `manipulate`, a manipulation session for the node itself, as [Manipulation](#manipulation) describes;
- `grab`, a manipulation session for a named target, such as the window panel that a titlebar belongs to.

A claim can be a function of the node, the hit item, the press, and the time held, evaluated when the gesture resolves. A canvas therefore claims a pan on its background and a move on the item under the press.

When a press begins, the deepest node on the hit path that accepts presses captures the interactor. The gesture resolves when the interactor moves past the drag threshold, or when a hold completes:

- The deepest node on the hit path whose claim covers the movement wins the gesture.
- If the winner is not the node that captured the press, the capturing node receives `cancel` with the reason `claimed`, and capture transfers to the winner. The transfer keeps the press's depth reference and frame, so a touch drag that a scroll box claims from a raised row continues with the same depth.
- A scroll box claims only the axes that no node beneath it on the hit path claims, so a horizontal slider inside a vertical list keeps horizontal drags, and a vertical drag on the slider scrolls the list.
- A drag-after-hold claim does not compete with movement before the hold completes, so a list whose rows reorder after a hold still scrolls with an immediate drag.

Hold, context, and drag-after-hold are ordered. Each kind declares its hold duration. A kind that consumes `hold`, such as a hold-to-confirm button, suppresses `context` for its presses. When a node on the hit path has a drag-after-hold claim, `context` fires on release after a hold without movement, as on touch platforms; otherwise it fires when the long-press duration elapses. The accessibility timing setting multiplies every one of these durations together, so their order never changes.

The drag threshold is measured along the surface for bent nodes, and in the scene for rigid nodes, so pulling a gizmo handle towards the viewer resolves too. A captured drag can become a drag session without losing its capture, through `node:promote(offers)`, so reordering a row within a list can continue as a drag to another panel. While any captured drag hovers near the edge of a scroll box on its hit path, the scroll box scrolls, so reordering and lasso selection reach content beyond the viewport.

A scroll gesture holds its scroll box until it ends. When the inner scroll box reaches its end during a gesture, the gesture does not pass to an outer box. The next gesture can.

## Manipulation

A manipulation session moves a target in space: a panel, a window, a node's own pose, or an object in the world. The interaction service owns sessions, so the toolkit, window panels, and #47's object manipulation share one implementation. A session has a target, constraints such as an axis, a plane, translation only, rotation only, or snapping, and the interactors that drive it. While a session is live, it takes key routing, so the mouse-and-keyboard chords that #49 describes, such as constraining to an axis by key during a grab, reach it rather than the focused window.

How the target follows its interactors, including whether translation and rotation are coupled, how far a hand's movement pushes a distant target, and how bare hands move a target in depth, is the manipulation policy that #47 defines. The toolkit fixes only which gesture starts a session, and what each session targets.

A node that claims `manipulate` starts a session for its own pose when a grab interactor presses it, so a volumetric preview, a gizmo, or a node-editor node can be grabbed and turned by hand or controller. A node that claims `grab` with a target starts a session for that target, so a titlebar in an attached panel moves its window panel. A press that no node claims becomes a panel grab when it moves past the drag threshold; panel grab is the lowest precedence. A controller's grip grabs, through its ray from a distance and through its grab sphere up close, and never presses a node. A tracked hand grabs within reach with its grab sphere, and beyond reach with its pinch ray on a grab handle or frame.

Resize frames, scale frames, and curvature handles are toolkit kinds on the panel's frame. They are drawn in an attached panel around the content panel, so the content's clip does not cut their hit volume. A window panel has two affordances, because #8 and #47 distinguish them: one scales the panel, and one resizes the client's content. A content resize frame emits resize proposals that the consumer applies, and it follows the size the client commits rather than the size it requested. Whether a content resize keeps the panel's size in metres or its pixel density is #8's decision.

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
| `drag-enter`, `drag-over`, `drag-leave`, `drop` | A drag session's interactor enters, moves over, or leaves the node, or drops on it |
| `transform` | Translation, scale, and rotation from several captures on a node that accepts them |
| `scroll` | A scroll delta in metres along the surface |
| `axis` | An analog two-axis value from a thumbstick or touchpad, for a node that claims it |
| `navigate` | A direction from focus traversal, for the focused node to use before focus moves |
| `change` | A child's value changed, bubbling with the child's key and value |
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

Drag positions are computed against the captured node's layout as it was when the drag started, its surface coordinates and transforms, composed with its panel's current pose. Content that reflows during the drag does not change the values a stationary interactor produces, a drag on a curved panel stays under the finger or ray, and a slider on a wrist panel keeps its thumb under the finger as the wrist moves. Drag deltas start from the pose at which the trigger lock released, so a drag does not jump when the lock lets go.

Hover is continuous as well as discrete. While an interactor hovers a node, the node's state holds a hover record per interactor, updated every frame without a render: the source, the local point, the signed distance for a point interactor or the angular offset for a ray, and the select progress. The shader reads the same values through bound parameters, as [Rendering](rendering.md#bound-parameters) describes, so a proximity glow follows the finger every frame.

Hold, long-press, drag-after-hold, and tooltip durations are multiplied by the accessibility timing setting.

Behaviour is the same for every interactor. A node reads press depth and hover distance only for visual feedback.

## Capture and cancellation

A node captures an interactor's button on press and keeps it through movement and release, even while another node or surface is hovered. Each button of an interactor captures independently, so a right press during a left drag is a separate press. A captured node refuses other interactors unless its kind accepts several captures.

A capture ends with `cancel` and a reason from the interaction contract's closed set, which the toolkit extends:

| Cause | Reason |
|---|---|
| The node is removed, re-keyed, or recreated by a kind override | `control-removed` |
| The node becomes disabled | `disabled` |
| The node's panel is hidden, or its overlay is dismissed | `hidden` |
| Another node on the hit path wins the gesture | `claimed` |
| A manipulation session takes the interactor | `grab` |
| The interactor's source stays untracked for longer than the tracking grace period, or is disposed | `tracking-loss` |
| The interaction provider is replaced | `provider-replaced` |
| A point interactor slides beyond the cancel distance while pressed, before any claim has won | `slid-off` |
| Escape or the dismissal action while the gesture is live | `dismissed` |

A move or relayout of the captured node does not cancel, and neither does a change of the panel's pose. A button whose capture was cancelled stays blocked until it is released, so a re-enabled node under a held trigger does not receive a press. Within the tracking grace period, a brief tracking loss neither cancels nor releases; when tracking returns, the slide-off check runs before the release check. After the grace period, the contract's quarantine applies: every button of the source stays blocked until a tracked sample reports it up. Source loss also releases every key that the source's route holds, as the keyboard routing contract requires.

## Near touch

A point interactor activates by depth. The default values are starting points for tuning in a headset, not values taken from a published source:

| Parameter | Default | Purpose |
|---|---|---|
| Hover entry distance | 30 mm in front of the surface | The node shows hover before contact |
| Hover exit distance | 50 mm | Hysteresis prevents flicker at the boundary |
| Activation depth | 2 mm into the surface, or 0.8 of the node's available press travel if that is less | Selection starts |
| Release gap | 3 mm of recoil from the deepest point | Selection ends |
| Re-arm gap | 3 mm of movement back towards the surface after a release | A new press can start |
| Drag threshold | 10 mm along the surface | A press becomes a drag only after this movement |
| Cancel distance | 30 mm along the surface while pressed | Sliding off a pressed control cancels it, until a claim wins |
| Unclamp depth | 20 mm beyond the surface | The fingertip proxy stops being held at the surface |
| Tracking grace period | 150 ms | A brief tracking loss neither cancels nor re-arms a press |

These are physical distances. They do not scale with the presentation's scale, because a fingertip's movement does not change when a panel is shown larger.

Depth is measured against the pressed node's rest surface: its elevation without hover lift or press travel, fixed when hover begins and kept for the whole gesture, including after a capture transfer. A press releases when the fingertip recoils from its deepest point by the release gap, or leaves the surface, so a finger pushed far through does not have to back all the way out, and jitter smaller than the gap neither releases nor re-presses. After a release, the next press arms when the fingertip moves back towards the surface by the re-arm gap, so fast repeated presses on a key work without a full retreat.

While the fingertip is in contact, the node's press travel follows its depth, clamped to the available travel, rather than animating towards a fixed target, so the face moves with the finger. A flat target with no travel, such as a row at base elevation, shows the press with its state layer and the fingertip proxy's contact ring instead.

A press requires the point to enter the hover zone from the front, moving towards the surface relative to the panel. Relative movement counts, so bringing a wrist panel to a still fingertip presses as moving the finger to the panel does. A point that appears inside the zone after a tracking loss longer than the grace period, or that enters it from the side or from behind, cannot press until it retreats beyond the hover exit distance.

lunette draws a fingertip proxy, as [Motion and feedback](motion-and-feedback.md#fingertip-proxy) describes. The proxy is held at the visual surface from first contact until the unclamp depth, so it does not appear to pass through the control. The clamp affects only the proxy, not tracking.

Targets for touch need more area than targets for rays. [Theming](theming.md#target-sizes) sets the token sizes.

## Ray robustness

Pressing a trigger moves the controller, and the ray moves with it. Wolf and colleagues attribute a large share of ray selection errors to this movement, as [Research](research.md#ray-pointing-research) describes. The interaction service applies these mitigations to every controller and pinch ray:

- An adaptive filter, the one-euro filter, smooths the ray while keeping fast movements responsive. Its parameters are part of the laser's configuration.
- The ray locks during a press. When the select progress passes the lock threshold while the ray hovers an offered surface and no grab is active, and the ray moved less than the unlock angle and the unlock distance since the previous frame, the ray holds the previous frame's pose. While locked, it releases when its total drift since the lock exceeds the unlock angle or the unlock distance, and after such a release it stays unlocked until the press ends. The release frame keeps the locked pose, so releasing does not move a click onto a neighbour. The limits are 3 degrees and 3 cm by default.
- Hover is sticky. Once a node is hovered, the ray keeps hovering it until the ray leaves the node by a small angular margin.
- A drag starts only after the ray moves past an angular threshold from the press position, which is at least the unlock angle.

A controller's trigger presses at the runtime's button threshold. Pinch strength is analog and often rests above zero, so a pinch has its own press and release thresholds with hysteresis. For a pinch, the lock arms at the pinch's press threshold and lasts until the pinch's pressed state ends at the release threshold, not until the select progress falls below the arming value. Noise around a threshold therefore neither double-activates nor spends the lock before the real pinch, and opening the fingers to release does not swing the ray off its target before the release registers.

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
- `pointer`: most focusable kinds, such as buttons, toggles, and sliders, become the panel's focused node when pressed but do not take session focus. Clicking a toggle in a settings panel therefore leaves typing going to the terminal the user was typing in. A press on such a node does not take focus away from a focused text field in the same panel or in the same overlay chain, so pressing a filter chip or a suggestion beside a search field leaves typing in the field.
- `none`: the kind never becomes focused, such as the virtual keyboard's keys. A panel built only from such kinds never takes session focus.

A panel takes session focus when traversal enters it, when a text-input node in it is pressed, or when it is summoned with focus. A presentation declares whether showing a panel takes focus. Hiding a panel releases its session focus, and the host restores the focus target that held session focus before the panel took it, if that target is still live and nothing else has taken focus since. Closing the summoned wrist menu therefore returns typing to the terminal. A panel that shows again restores its own focused node.

An overlay shares its opener's session focus target, as [Presentations](presentations.md#focus) describes. Key events go to the focused node of the innermost overlay in the chain that has one, and otherwise to the opener panel's focused node. Dialogs have their own focus target.

### Focus traversal

- Sequential traversal follows tree order. Tab and Shift-Tab move focus on a keyboard.
- Directional traversal moves to the nearest focusable node in a direction, as [Spatial model](spatial-model.md#directional-focus-traversal) defines. Arrow keys move focus on a keyboard.
- Activation triggers the focused node. Enter and Space activate on a keyboard. Holding the activation drives `hold`, so a hold-to-confirm button works without pointing.
- The context action opens the focused node's context menu. The Menu key and Shift-F10 invoke it on a keyboard.
- Dismissal closes the innermost overlay, pops a navigation stack, or leaves a text field. Escape dismisses on a keyboard.

On a controller, traversal applies to the panel that holds session focus, while the source's ray does not hover any surface and no panel is grabbed. The thumbstick navigates, the primary face button activates, the secondary face button dismisses, and a thumbstick click opens the context action. While the ray hovers a surface, the thumbstick scrolls as described above, and while a session manipulates a panel, it serves the session. A separate binding moves session focus to the next panel in the session, which includes the attached chrome of window panels, so a user whose focus is on a window reaches its close button without pointing. The bindings are defaults in the bindings service, so a configuration can remap them.

Value controls, such as sliders, steppers, knobs, and radio groups, use an engage mode on a controller. A focused value control lets directions pass, so the thumbstick moves focus past it. Activating it engages it: directions then adjust its value, as `navigate` events and as `axis` events for kinds that claim the axis, and dismissal or a second activation disengages it. A controller user therefore never gets trapped in a slider without a Tab key. On a keyboard, a direction goes to the focused node as a `navigate` event first, then bubbles through its focus scopes, and moves focus only if no node uses it, because Tab is available to leave.

Traversal is a public service on the host: `navigate(direction)`, `activate()` with press and release forms, `context()`, `dismiss()`, and `nextPanel()`. A plugin can drive it from other bindings, add a dedicated traversal mode, or connect switch access, without changes to the toolkit.

Every action that a pointer can take has a traversal path:

- A panel's frame offers Move, Rotate, Scale, Curve, and, for window panels, Resize content, in its context menu, each adjusted with the thumbstick until confirmed.
- Reorderable rows offer Move up, Move down, and Move to, which lists the drop targets that accept the row, in their context menus. Drag and drop between panels uses Move to.
- A table header's context menu offers Resize column, adjusted with the thumbstick.
- Read-only text offers Select all and Copy in its context menu, and text fields add Paste.
- Multi-select lists offer a selection mode in which activation toggles rows, because modifier keys are not available without a keyboard.
- Toast actions are also available from the notification history panel.

The recovery plugin's controls are reachable by ray only, because the recovery plugin does not depend on the toolkit's traversal.

The focused node shows a focus ring only while focus came from traversal, not from a pointer press, in the manner of the web's `:focus-visible`.

### Focus scopes and key routing

A focus scope is a node that groups focusable descendants. A key event goes first to the focused node, then bubbles through the scopes that contain it, and reaches traversal only if no node handles it. A slider handles left and right itself, a text field handles arrows for its caret, and traversal receives an arrow only when the focused node does not use it.

A roving group is a scope that is one stop for sequential traversal, with arrows moving within it. Radio groups, segmented controls, tab bars, toolbars, and tree views are roving groups. A scope remembers its last focused child, so returning to the scope or popping a navigation stack restores focus where it was.

A panel can register shortcuts, which receive a key before the focused node when their modifiers match. Ctrl-F focusing a search field is a shortcut.

Key-up and held keys need the revised focus contract, as [The virtual keyboard](#the-virtual-keyboard) describes, and the frame service's dispatch of key releases.

## Drag and drop

A drag session carries a payload from one node to another, including across panels. A node starts a session from a drag gesture, or promotes a captured drag into one, with typed offers: MIME types for data that may leave the session, and in-process values for data that stays inside it. While the session is live, the interactor keeps querying every surface, and the interaction service delivers `drag-enter`, `drag-over`, `drag-leave`, and `drop` to the surfaces and nodes under it. A node accepts a drop by declaring the offers it takes. The dragged ghost is a portal at popover elevation that follows the attach pose. It never answers hit queries, so it does not block the drop targets beneath it. Promoting an in-panel drag creates the ghost portal from the dragged node's appearance at that moment. A session ends when its source's owner ends, and its in-process values are released with it.

Drag sessions belong to the interaction contracts. A window surface can bridge a session to a Wayland drag, which needs a compositor-originated data source; that bridge is an open question.

## Disabled controls

A node with a `disabledReason` prop is disabled and shows the reason in a tooltip. The tooltip appears on ray hover, on point hover in front of the surface, and on focus through traversal, so it is reachable by every interactor and without pointing. Inspection reports the reason, so tests can assert it.

## The virtual keyboard

The virtual keyboard is a toolkit panel built from toolkit kinds. Typing by poking is the clearest use of near touch, and the keyboard gets depth, press travel that follows the finger, and hover in front of the surface from the toolkit. Its keys have the `none` focus policy, so poking a key never moves session focus away from the field it types into. Its layout follows the focused field's input hint.

A key sends a key-down when it is pressed and a key-up when it is released or its capture is cancelled. This needs a revision of the focus contract, which today delivers key activations rather than held keys: the revision adds key-up, key release on route loss, input hints on targets, and a session keymap that is not tied to a Wayland seat. Repeat follows the source:

- A Wayland client repeats held keys itself, from the repeat information that the compositor sends.
- For toolkit fields, the focus service repeats held keys from virtual sources, such as the keyboard panel, at the same delay and rate.
- Physical keys already arrive with LÖVR's repeat flag, so the focus service does not repeat them again.

The keyboard's paste key pastes from the session clipboard into the focused field. Its key layout is the keyboard plugin's data, and text entry into toolkit fields maps keys to text with the session keymap.

## Open questions

- A touch path from point interactors to Wayland clients, through the Wayland touch protocol or through emulated pointer events.
- A bridge from drag sessions to Wayland drags, which needs a compositor-originated data source.
- Whether gaze is an interactor. Eye tracking is not available on every headset, and gaze with pinch needs a different hover model.
- Whether `getHandPose`, `getSkeleton`, the hand interaction profile, and haptics work in an XR_EXTX_overlay session on the session's runtime.
- The near distance, the grab sphere's radius, the pinch thresholds, the recoil and re-arm gaps, and the one-euro filter parameters for tracked hands, which need tuning in a headset.
