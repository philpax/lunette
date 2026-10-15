# Accessibility

Accessibility in the toolkit is a set of session settings that the host, the theme, and the interaction service consume, a semantic description of every node, and rules that keep every action reachable by more than one means. Kinds get most of it by using tokens and declaring a role.

## Settings

The accessibility service, `lunette/accessibility`, publishes the session's settings as a store:

| Setting | Effect |
|---|---|
| Reduced motion | Every motion role uses its substitute, following stops, and scroll inertia stops, as [Motion and feedback](motion-and-feedback.md#reduced-motion) describes |
| Text scale | Multiplies every typography role's size. Fixed-size panels scroll or wrap their content rather than clipping it |
| High contrast | Selects the theme's high-contrast token variant |
| Handedness | Selects the hand for the wrist presentation and the default hand for one-handed bindings |
| Haptics and sounds | Turn haptic and sound feedback off independently |
| Visual alternatives | Show the visual equivalent of every sound |
| Body profile | Eye height, seated or standing, and reach, which presentations use to place panels |

A text scale change relayouts every panel, and the minimum text size applies to the scaled size, multiplied by the presentation's scale.

## Roles and semantics

Every kind declares a role from the closed set in the contract vocabulary and a semantics function that returns its accessible name, value and range, and states such as checked, expanded, selected, and disabled. Composites take the role of their root kind unless they declare one. Items inside a node, such as edges in a graph, declare roles too.

Inspection reports roles and semantics. That gives assistive plugins what they need: a screen reader that speaks the focused node, switch access that steps through focusable nodes, and voice control that activates a node by its name. It also gives tests a way to find nodes by role and name rather than by id alone.

## One-handed use

A two-handed gesture is never the only path to an action:

- Panel scaling with two hands has a one-handed alternative through the resize frame.
- A canvas that zooms with two hands also zooms with the thumbstick, the wheel, or zoom controls.
- The wrist menu opens from a controller binding or a palm-up gesture on either hand, as well as from the other hand's touch.
- Every action reachable by pointing is also reachable through focus traversal on one controller.

## Colour and contrast

- Body text has a contrast ratio of at least 4.5 to 1 against its surface, and control boundaries, focus rings, toggle tracks, and state layers over the accent have at least 3 to 1.
- No state is conveyed by colour alone. Status colours come with an icon or a label, and the disabled state comes with its reason.
- The default accent and status colours remain distinguishable under the common forms of colour blindness.
- The theme contract includes a high-contrast variant.

A test checks every pair of text and surface tokens in each shipped theme against these ratios, so a theme cannot regress them.

## Target assistance

Users with tremor or limited precision benefit from targets that are easier to hit. The interaction service's `pick` hook lets a plugin implement a bubble cursor, magnetic snapping to targets, or a larger sticky margin, as [Extension](extension.md#interaction-extension) describes. A dwell interactor selects by holding still, using the same select progress that a trigger produces, and switch access drives the traversal service.

## Localisation

Layout mirrors for right-to-left text through an inherited direction, alignment is logical, and text styles carry a language tag, as [Layout and text](layout-and-text.md) describes. Directional focus traversal and slider orientation mirror with the layout. Bidirectional editing and input-method composition remain open, and until they exist a user of a right-to-left script cannot edit mixed-direction text in a toolkit field.

Interface text uses sentence case for labels and titles, and disabled reasons are full sentences that say what makes the control available.
