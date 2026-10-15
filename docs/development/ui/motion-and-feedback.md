# Motion and feedback

Interfaces in a headset feel responsive when every change is continuous and every action is acknowledged. The host owns the clock, the animated state, and the feedback dispatcher, so every kind, standard or third-party, animates and gives feedback in the same way, and the accessibility settings apply to all of them.

## The animation clock

The host advances animations by the frame service's predicted display time, not by wall-clock time, so motion is smooth at any frame rate and matches what the user sees. A step after a stall, such as a paused frame loop, is clamped, and springs integrate in substeps, so a long frame never makes a spring overshoot. Tests substitute a clock that they step explicitly, so animations are deterministic.

## Animation channels

A node has animation channels:

- `transform`: the user transform's translation, rotation, and scale, as [Spatial model](spatial-model.md#composition) defines. Hit testing follows it. Layout transitions animate the separate layout transform, which only the host writes.
- `size`: an animated size that the box shader draws, with fixed corner radii and border widths, so a growing box keeps its shape. Children keep their own sizes.
- `opacity`, multiplied through descendants, as [Rendering](rendering.md#opacity) describes.
- `elevation`: an offset added to the node's elevation. Hover lift and press travel use it.
- `tint`: a colour mixed into the node's fills.
- `hover` and `press`: the state layer strengths that the box shader mixes into fills.
- `progress`: a general value from 0 to 1 that visuals bind to, such as an arc's sweep or a fill level.
- a few further general scalars, which visuals bind to through bound parameters.

A kind, a visual, or a component through a node handle sets a channel's target with a motion role:

```luau
node:animate('elevation', theme.elevation.hoverLift, 'emphasis')
```

The role selects a motion spec from the theme's motion tokens, and a caller can pass a spec that overrides the role's default. Every animation has a role, so the host can apply the reduced-motion substitute to every animation, whatever spec it passes. A spec is one of:

- A spring, with stiffness, damping, and mass. A spring that receives a new target keeps its current velocity, so a hover that ends during the hover-lift animation turns around smoothly instead of snapping back.
- A tween, with a duration and an easing curve, for motion that must take a fixed time.
- A loop, for continuous motion such as a spinner's rotation or an indeterminate progress sweep.

Channel values live in the per-node animation buffer that the shader reads, so an animation never rebuilds a panel's instance data and never renders a component. Visuals bind drawing parameters to channels, as [Rendering](rendering.md#bound-parameters) describes. Hover lift, press travel, and the state layers are ordinary channels that the host's interaction response sets for any kind that declares a `response`, so third-party kinds get the same feel as the standard kinds.

While a point interactor is in contact with a node, its press travel follows the fingertip's depth directly rather than animating, as [Input](input.md#near-touch) describes. A spring takes over when contact ends.

Inspection reports each channel's current value and target, so a test can assert either.

## Enter and exit

A node created with an `enter` spec starts from the spec's initial channel values and animates to its resting values. A node removed with an `exit` spec is marked exiting rather than removed:

- An exiting node keeps its last layout and runs its exit animation, and the host removes it when the animation ends.
- It is excluded from hit testing, focus traversal, and inspection's live set, and inspection reports it as exiting. It keeps its place in draw order.
- Re-adding an element with the same key and kind while its node is exiting revives the node. Its node state is reset, because the component that owns it was mounted again.

Kinds declare default enter and exit specs, so popovers, menus, tooltips, dialogs, toasts, and list rows fade and scale in and out without author code. Panels use the same specs when their presentation shows and hides them. Items that a virtualised kind dematerialises when they scroll out of view are not removed, and do not play exits.

An owner that unloads and a panel that is destroyed remove nodes immediately, without exit animations, so ownership cleanup stays prompt.

## Layout transitions

A node with `layoutTransition` animates from its previous rectangle to its new one after each relayout. Its position animates through its layout transform and its size through the `size` channel, so text and corners are never stretched, and a transition never fights a user transform such as a drag. A container that grows reveals its children through its animated clip. Layout itself stays exact. Hit testing during a transition follows the rule in [Spatial model](spatial-model.md#hit-volumes).

Reordered rows slide to their new places, an expanding section grows, and a content-sized panel animates its size change rather than jumping, which matters in VR, where a panel edge that jumps several centimetres at arm's length is conspicuous.

## Scroll physics

A scroll box owns its physics state:

- A drag scrolls the content directly. On release, the content continues with the drag's velocity and decays at a rate from the motion tokens.
- Overscroll beyond the content's ends is resisted and springs back on release.
- Optional snap points, such as page boundaries or item starts, catch the content as it settles.
- Thumbstick scrolling is smoothed, so the content does not move in steps.

The resting offset is clamped to the content, and the transient offset is not, so overscroll is possible. Scroll physics advances before picking, as [Architecture](architecture.md#data-flow) describes, so a list is hit where it is drawn during a fling.

## Feedback

Kinds report feedback by name rather than by device. `node:feedback('activate')` or `node:feedback('detent')` names an event, and a host dispatcher resolves it through the theme's feedback tokens, keyed by event and by the source's modality, to a haptic pattern, a sound, and a visual cue:

| Event | Class | Typical use |
|---|---|---|
| `hover` | Ambient | An interactor starts hovering an interactive node |
| `contact` | Confirmation | A fingertip touches a node |
| `press`, `release`, `activate` | Confirmation | A press starts and ends, and a control acts |
| `detent` | Confirmation | A slider passes a detent, or a stepper changes value |
| `boundary` | Confirmation | A scroll box or slider reaches its end |
| `invalid` | Confirmation | An action is refused, or a value fails validation |
| `drag-snap` | Confirmation | A dragged item snaps to a drop target |
| `hold`, `overscroll` | Continuous | A hold ramps up, or content is pulled past its end |

The dispatcher:

- Plays haptic patterns as sequences of pulses on the source's controller, because LÖVR's `vibrate` plays a single pulse, and scales continuous events with their progress.
- Plays sounds at the node's position through the audio service, so they are spatialised.
- Rate-limits ambient events per source.
- Never drops the first confirmation event in a burst, so every keystroke on the virtual keyboard is acknowledged. Identical confirmation events from one source in one frame coalesce into one, and `detent` has a minimum interval, so sweeping a slider across many detents gives distinct ticks rather than a continuous buzz. A new confirmation cuts off the previous one's haptic pattern.
- Gives every confirmation event its visual cue, even when its haptic or sound coalesced.
- Resolves feedback per modality. A bare hand has no actuator, so its tokens give visual cues for every event and sounds for contact and confirmation events only, not for hover.
- Gives every confirmation event a visual cue, and, with the accessibility setting for visual alternatives, gives every sound a visual equivalent.
- Honours the accessibility settings for haptics and sound.

## Fingertip proxy

lunette runs as an overlay session and cannot occlude the user's real hand against its panels, so the hand disappears behind a panel before it touches it. lunette therefore draws a fingertip proxy for each poke point as part of the standard interaction response:

- A small marker at the fingertip, which the near-touch clamp holds at the visual surface from first contact until the unclamp depth, as [Input](input.md#near-touch) describes.
- A contact shadow and a proximity ring on the surface beneath the fingertip, bound to the panel's interactor values, which grow and sharpen as the fingertip approaches and show contact on targets that have no press travel.

A full hand mesh is an open question, to be assessed with hand tracking on real hardware.

## Cursors and rays

The cursor for a ray is a ring at the hit point with a constant angular size. Hits are taken at the face as drawn, including hover lift and press travel, and the cursor draws a small fixed distance along the hit normal from that face, after the panel's opaque content, so it never hides under a lifted face or fights the depth of the face it sits on. The select ring is smaller than the hover ring, in the proportion that Meta's raycasting specification uses, and it shrinks as selection progresses. The ring sizes and proportions are theme tokens. A kind can set a cursor hint, such as text, grab, or snap to the node's bounds, which the interaction service uses to shape the cursor. The ray's visual follows arbitration, so a ray that near-beats-far has disabled is hidden.

## Reduced motion

Every motion role has a substitute. With reduced motion set, the host applies the substitute whatever spec the caller passed:

| Role | Use | Substitute |
|---|---|---|
| `enter`, `exit` | Nodes and panels appearing and disappearing | A short fade without scaling or sliding |
| `emphasis` | Attention, such as a pulse on a new notification | None |
| `layout` | Layout transitions | An immediate change |
| `spatial` | Panels moving through space, and following | A fade out and a fade in at the new place |
| `gesture` | Motion that follows input, such as drags and scroll inertia | Direct movement without inertia or overscroll |
| `continuous` | Spinners and indeterminate progress | A static indicator or a slow change |
| `feedback` | Hover lift and press travel | Unchanged, because they confirm input rather than move content |

Following presentations stop following and use the `spatial` substitute when their panel leaves the comfortable field of view, so content is never left behind out of view.

## Same-frame response

Every interactive kind shows hover and press in the frame whose input produced them, without waiting for a render, because hover and press are node state. Controlled kinds show the user's new value in the same frame, as [Authoring](authoring.md#controlled-values) describes.
