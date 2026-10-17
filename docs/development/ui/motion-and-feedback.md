# Motion and feedback

Retained motion and interaction state let a control respond without re-running its component. The host owns that state and applies accessibility settings consistently to standard and third-party kinds that use the host response.

## The animation clock

Motion advances from the frame update's delta. The host uses a critically damped spring solution and theme timing. It does not expose a predicted-display-time clock or a public test-clock service. Deterministic tests advance frame deltas through the existing fixtures.

## Animation channels

Node channels animate scalar values. The host's hover lift, press travel, and opacity use retained state, and visuals can read channel values. Retargeting a spring retains velocity so rapid input changes do not abruptly restart motion.

Channels are not a public transform, size, tint, tween, or loop system. Values are read while Lua prepares drawing data; there is no native per-node animation buffer or shader expression registry. [Rendering](rendering.md#bound-parameters) records that cost boundary.

## Enter and exit

Kinds can request the supported fade transitions. Exit drawing can outlive a removed node's input participation, but owner cleanup and panel destruction release resources immediately. A consumer must not delay ownership cleanup to finish a visual effect.

The contract does not provide arbitrary initial-channel enter specifications or revival of a removed component with all former state. The standard kinds and host declarations own transition choices.

## Layout transitions

The host does not expose the proposed `layoutTransition` mechanism with independent position and size channels. A relayout updates geometry during commit. Consumers must not rely on automatically animated reordering, animated clip reveals, or hit testing against both drawn and final rectangles.

Layout-dependent animation also cannot rely on `useLayoutEffect`: that hook runs before host layout, as [Authoring](authoring.md#hooks) states.

## Scroll physics

Scroll offsets remain node state and are clamped to content after layout. The host does not provide general inertial scrolling, overscroll springs, snap points, or gesture arbitration between nested scroll boxes. A standard control or consumer can implement its own supported behavior, but must not assume those mechanisms follow from `overflow` alone.

## Feedback

The host supplies basic press response and detent feedback to held pointers, subject to the haptics setting. The node contract does not expose the proposed named event dispatcher with queued pulse patterns, spatial sounds, and visual alternatives for every confirmation.

An action still needs a visible result when sound or haptics are unavailable. Bare hands have no controller actuator. Consumer workflows therefore cannot depend on a vibration or sound as the only acknowledgement.

## Fingertip proxy

An overlay session cannot occlude a real hand against its panel. The host draws a fingertip contact cue so a poke remains visible when the underlying application or passthrough hand is hidden. Tracking and activation use the real fingertip sample; the cue does not replace input with a clamped pose.

A full hand mesh and richer proximity lighting remain separate work. The drawing contract has no arbitrary shader binding to nearby interactors.

## Cursors and rays

The interaction providers own ray and cursor rendering. A disabled idle ray follows near-touch arbitration, while an existing ray capture remains active. Cursor and hit geometry must remain consistent with raised controls. The provider's source owns sizes, filtering, and trigger-lock parameters rather than copied theme defaults here.

## Reduced motion

The host's reduced-motion setting snaps its motion channels to their targets, including hover lift and press travel. It does not implement the proposed per-role substitutes for spatial fades, inertial gestures, looping indicators, and layout transitions. Consumers with independent animation must consume the relevant accessibility setting explicitly.

## Same-frame response

Hover and press state change during input without a component render. The next draw can therefore reflect them directly. A callback that changes a component's structure or controlled props waits for the next scene-update commit. This distinction matters for menus, changing labels, and asynchronously applied values; the host does not run a second render after pointing.
