# Motion and feedback

Interfaces in a headset feel responsive when every change is continuous and every action is acknowledged. The host owns the clock, the animated state, and the feedback dispatcher, so every kind, standard or third-party, animates and gives feedback in the same way, and the accessibility settings apply to all of them.

## The animation clock

The host advances animations by the frame service's predicted display time, not by wall-clock time, so motion is smooth at any frame rate and matches what the user sees. Tests substitute a clock that they step explicitly, so animations are deterministic.

## Animation channels

A node has animation channels: offset in three dimensions, scale, opacity, elevation offset, tint, and a few general scalars that visuals can read. A kind, a visual, or a component through a node handle sets a channel's target:

```luau
node:animate('elevation', theme.elevation.hoverLift, theme.motion.hover)
```

A channel moves towards its target by a motion spec:

- A spring, with stiffness, damping, and mass. A spring that receives a new target keeps its current velocity, so a hover that ends during the hover-lift animation turns around smoothly instead of snapping back.
- A tween, with a duration and an easing curve, for motion that must take a fixed time.

Channel values live in the per-node animation buffer that the shader reads, so an animation never rebuilds a panel's instance data and never renders a component. Hover lift, press travel, and focus-ring growth are ordinary channels that the standard kinds set, so third-party kinds use the same mechanism. A kind that needs continuous animation, such as a spinner or an indeterminate progress bar, sets a looping tween on a channel.

Inspection reports each channel's current value and target, so a test can assert either.

## Enter and exit

A node created with an `enter` spec starts from the spec's initial channel values and animates to its resting values. A node removed with an `exit` spec is marked exiting rather than removed:

- An exiting node keeps its last layout and runs its exit animation, and the host removes it when the animation ends.
- It is excluded from hit testing, focus traversal, and inspection's live set, and inspection reports it as exiting.
- Re-adding an element with the same key while its node is exiting revives the node.

Kinds set default enter and exit specs, so popovers, menus, tooltips, dialogs, toasts, and list rows fade and scale in and out without author code. Panels use the same specs when their presentation shows and hides them.

An owner that unloads and a panel that is destroyed remove nodes immediately, without exit animations, so ownership cleanup stays prompt.

## Layout transitions

A node with `layoutTransition` animates from its previous rectangle to its new one after each relayout, through its offset and scale channels. Layout itself stays exact, and hit testing uses the final rectangle, so a press made during a transition lands where the node is going. Reordered rows slide to their new places, an expanding section grows, and a content-sized panel animates its size change rather than jumping, which matters in VR, where a panel edge that jumps several centimetres at arm's length is conspicuous.

## Scroll physics

A scroll box owns its physics state:

- A drag scrolls the content directly. On release, the content continues with the drag's velocity and decays at a rate from the motion tokens.
- Overscroll beyond the content's ends is resisted and springs back on release.
- Optional snap points, such as page boundaries or item starts, catch the content as it settles.
- Thumbstick scrolling is smoothed, so the content does not move in steps.

The resting offset is clamped to the content, and the transient offset is not, so overscroll is possible. Reduced motion removes inertia and overscroll.

## Feedback

Kinds report feedback by name rather than by device. `node:feedback('activate')` or `node:feedback('detent')` names an event, and a host dispatcher resolves it through the theme's feedback tokens to a haptic pattern, a sound, and a visual cue for the node's source:

| Event | Typical use |
|---|---|
| `hover` | An interactor starts hovering an interactive node |
| `press`, `activate` | A press starts, and a control acts |
| `detent` | A slider passes a detent, or a stepper changes value |
| `boundary` | A scroll box or slider reaches its end |
| `invalid` | An action is refused, or a value fails validation |
| `drag-snap` | A dragged item snaps to a drop target |

The dispatcher:

- Plays haptic patterns as sequences of pulses on the source's controller, because LÖVR's `vibrate` plays a single pulse.
- Plays sounds at the node's position through the audio service, so they are spatialised.
- Rate-limits each source, so typing on the virtual keyboard does not stack pulses and sounds.
- Gives every sound a visual equivalent, such as a pulse of the node's tint, for users who cannot hear it.
- Substitutes visual and sound cues for haptics when the source is a bare hand, which has no actuator.
- Honours the accessibility settings for haptics and sound.

The cursor for a ray is a dot at the hit point with a constant angular size, and it shrinks as selection progresses. A kind can set a cursor hint, such as text, grab, or snap to the node's bounds, which the interaction service uses to shape the cursor.

## Reduced motion

Every motion token has a role: enter, exit, emphasis, layout, spatial, or gesture. With reduced motion set, each role uses its substitute, which is a crossfade or an immediate change. Kinds do nothing to support it beyond using motion tokens. Following presentations stop following, and scroll inertia and overscroll stop.

## Same-frame response

Every interactive kind shows hover and press in the frame whose input produced them, without waiting for a render, because hover and press are node state. Controlled kinds show the user's new value in the same frame, as [Authoring](authoring.md#controlled-values) describes.
