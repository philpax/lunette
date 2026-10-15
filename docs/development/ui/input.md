# Input

The toolkit supports controller rays, tracked hands, and mouse and keyboard equally. Nodes never branch on modality. The interaction service turns physical input into interactors, arbitrates between the interactors of each source, and delivers semantic events. Keyboard and controller focus traversal is a separate channel that works without pointing.

The model belongs to the interaction contracts rather than to the toolkit, because window and monitor panels consume the same interactors.

## Sources and interactors

A source is a physical device: the left controller, the right controller, the left hand, the right hand, or the mouse. An interactor is one input mechanism of a source. Each interactor is either a ray or a point.

| Source | Interactors |
|---|---|
| Controller | A ray from the controller's aim pose, selected by the trigger |
| Tracked hand | A point at the index fingertip for poking, and a ray for pinching at a distance |
| Mouse | A ray from the head through the cursor's projected position, selected by mouse buttons |

An interactor publishes its pose, its shape, a select progress from 0 to 1, and an attach point. The select progress is the analog trigger, the pinch strength, or a mouse button's state. The attach point is where manipulation applies: the ray's hit point or the fingertip.

Tracked hands come from LÖVR's `lovr.headset.getSkeleton`. The poke point is the index fingertip joint. The pinch ray starts at an estimated shoulder position and passes through a point between the thumb and index finger, which is the construction that Meta's Interaction SDK and MRTK use, because a ray from the hand alone shakes with every finger movement. Pinch strength is derived from the distance between the thumb and index fingertips.

The mouse ray's projection model, capture, and release belong to #49. The toolkit needs only a ray interactor with buttons, scroll, and a visible cursor.

## Arbitration

The interaction service arbitrates the interactors of each source in two passes each frame.

1. Hover candidates. Each interactor finds its nearest target: a ray by casting against surfaces, and a point by testing proximity to surfaces.
2. Selection. Near beats far. When a hand's poke point is within the near distance of a surface, the same hand's pinch ray is disabled, and it stays disabled until the point leaves the hover exit distance. A source has at most one hovering interactor at a time.

The near distance is a tuning value. Disabling the ray while the hand is near prevents a poke and a pinch from acting on the same element, which is the conflict that MRTK's interaction modes and StereoKit's per-interactor minimum distance both address.

Different sources never arbitrate against each other. Two hands, two controllers, or a hand and the mouse each hover and capture independently.

## Surfaces

The surface protocol has a point query beside `raycast`. A surface that supports touch implements `proximity(point)`, which returns the nearest hittable location, its surface-local coordinates, and the signed distance from the point to the surface along its normal. Window and monitor panels leave it unimplemented, so points do not interact with them. A touch path to Wayland clients is an open question.

A UI panel answers both queries per node, at each node's elevation, and applies each node's clip. A ray therefore hits a raised button before the panel behind it, and a fingertip touches the raised button first.

## Semantic events

The host delivers these events to nodes:

| Event | Meaning |
|---|---|
| `hover-enter`, `hover-leave` | An interactor starts or stops hovering the node |
| `press` | Selection starts on the node and the node captures the interactor |
| `release` | Selection ends, with `inside` saying whether the interactor is still over the node |
| `activate` | A press and release inside the node, without a drag. Buttons act on this |
| `cancel` | A captured gesture ends without activation, with a reason |
| `drag-start`, `drag`, `drag-end` | A captured interactor moved past the drag threshold, with panel-local positions and deltas |
| `scroll` | A scroll delta in metres along panel-local axes |
| `focus`, `blur` | Keyboard focus moves to or from the node |
| `key`, `text` | Keyboard input to the focused node |

Every pointer event carries the panel-local position, the interactor's source, the select progress, and, for point interactors, the press depth. A node reads press depth only for visual feedback, such as pressing a button in as far as the fingertip pushes. Behaviour is the same for every interactor.

A captured node refuses other interactors unless its kind declares that it accepts several. The plugin manager's graph canvas declares it, so a two-handed gesture can zoom it.

## Near touch

A point interactor activates by depth. The defaults follow Meta's Interaction SDK, scaled by the presentation's scale:

| Parameter | Default | Purpose |
|---|---|---|
| Hover entry distance | 30 mm above the surface | The node shows hover before contact |
| Hover exit distance | 50 mm | Hysteresis prevents flicker at the boundary |
| Activation depth | 5 mm into the surface | Selection starts |
| Release depth | 2 mm | Selection ends; a lower release than activation depth allows fast repeated presses |
| Drag threshold | 10 mm tangential | A press becomes a drag only after this movement |
| Cancel distance | 30 mm tangential while pressed | Sliding off a pressed control cancels it |

The hand's rendered fingertip is clamped to the surface while pressing, so the finger does not appear to pass through the panel. The clamp is a visual change to the hand model and does not affect tracking.

Targets for touch need more area than targets for rays. [Theming](theming.md#target-sizes) sets the token sizes.

## Ray robustness

Pressing a trigger moves the controller, and the ray moves with it. Studies of ray pointing attribute a large share of selection errors to this movement. The interaction service applies these mitigations to every ray interactor:

- A low-latency adaptive filter, the one-euro filter, smooths the ray while keeping fast movements responsive.
- Hover is sticky. Once a node is hovered, the ray keeps hovering it until the ray leaves the node by a small angular margin.
- Press latching. A press targets the node that was hovered a few frames before the select progress started to rise, rather than the node under the ray at the moment of the press.
- A drag starts only after the ray moves past an angular threshold from the press position.

Activation happens on release inside the pressed node, and release outside cancels, for every interactor.

## Scrolling

Scroll boxes accept three inputs:

- Thumbstick and touchpad deflection, mapped to a scroll rate with a dead zone and acceleration.
- Mouse wheel and trackpad deltas.
- Drag-to-scroll: a press inside a scroll box that moves past the drag threshold along the scroll axis scrolls the content, with inertia after release. A press that moves less activates the control under it.

Scroll events go to the innermost scroll box that can still move in the scroll direction.

## Focus traversal

Every focusable node takes part in focus traversal. A panel has one focused node at most.

- Sequential traversal follows tree order. Tab and Shift-Tab move focus on a keyboard.
- Directional traversal moves to the nearest focusable node in a direction, measured from layout geometry. Arrow keys move focus on a keyboard.
- Activation triggers the focused node. Enter and Space activate on a keyboard.
- Dismissal closes the innermost overlay or leaves a text field. Escape dismisses on a keyboard.

A controller can drive the same channel, so a VR user can operate a panel without pointing. The controller bindings for traversal are an open question, because the thumbstick already scrolls, pushes, and pulls panels.

The focused node shows a focus ring only while focus came from traversal, not from a pointer press, in the manner of the web's `:focus-visible`. A pointer press on a focusable node focuses it without showing the ring.

A panel registers with the session focus service as one focus target. Key and text input reaches the panel's focused node. A text-input node sets `wantsKeyboard`, and the keyboard display shows the shared virtual keyboard while it is focused.

## Disabled controls

A node with a `disabledReason` prop is disabled and shows the reason in a tooltip. The tooltip appears on ray hover, on point hover above the surface, and on focus through traversal, so it is reachable by every interactor and without pointing. Inspection reports the reason, so tests can assert it.

## Feedback

Hover, press, and activation produce feedback through tokens: a highlight, a haptic pulse on the source's controller, and an optional sound at the hit point. Haptic feedback applies only to sources with an actuator. The cursor for a ray is a dot at the hit point with a constant angular size, and it shrinks while selection progresses.

## The virtual keyboard

The virtual keyboard is a toolkit panel built from toolkit kinds. Typing by poking is the clearest use of near touch, and the keyboard gets depth, press travel, hover above the surface, and focus handling from the toolkit. Its key layout is the keyboard plugin's data.

## Open questions

- Controller bindings for focus traversal, and how they coexist with thumbstick scrolling and panel push and pull.
- A touch path from point interactors to Wayland clients, through the Wayland touch protocol or through emulated pointer events.
- Whether gaze is an interactor. Eye tracking is not available on every headset, and gaze with pinch needs a different hover model.
- The near distance and the one-euro filter parameters, which need tuning in a headset.
