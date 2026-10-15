# Accessibility

Accessibility in the toolkit is a set of session settings that the host, the theme, and the interaction service consume, a semantic description of every node, an event stream for assistive plugins, and rules that keep every action reachable by more than one means. Kinds get most of it by using tokens, declaring a role, and declaring the standard interaction response.

## Settings

The accessibility service, `lunette/accessibility`, publishes the session's settings as a store:

| Setting | Effect |
|---|---|
| Reduced motion | Every motion role uses its substitute, as [Motion and feedback](motion-and-feedback.md#reduced-motion) describes, including following, scroll inertia, and overscroll |
| Text scale | Multiplies every typography role's size. Fixed-size panels scroll or wrap their content rather than clipping it |
| High contrast | Selects the theme's high-contrast token variant |
| One-handed mode | Places summoned content on the `summoned` presentation, operated by the present hand's ray, rather than on a wrist |
| Handedness | Selects the hand for the wrist presentation, the default hand for one-handed bindings and traversal, and the side overlays open towards, away from the pointing hand |
| Timing | Multiplies hold, long-press, tooltip, and toast durations |
| Haptics and sounds | Turn haptic and sound feedback off independently |
| Visual alternatives | Show the visual equivalent of every sound |
| Body profile | Eye height, seated or standing, and reach, which presentations use to place panels |

The settings are edited in a settings panel that the wrist menu and the plugin manager open, so they are reachable in VR. The accessibility service persists the settings itself, in a versioned settings file that it reads at startup and writes on change, preserving fields it does not recognise, so a setting changed in VR survives a restart without editing the configuration. Default appearance keeps every accessibility setting, because the settings are not overrides. A text scale change relayouts every panel, and the minimum text size applies to the scaled size at the presentation's nominal viewing distance.

## Roles and semantics

Every kind declares a role from the closed set in the contract vocabulary and a semantics function that returns its accessible name, value and range, and states such as checked, expanded, selected, and disabled. Composites take the role of their root kind unless they declare one. Items inside a node, such as edges in a graph or links in text, declare roles too.

Inspection reports roles and semantics, and the accessibility service publishes an event stream of changes: focus moved, a value changed, a node appeared or disappeared, and announcements such as a posted notification, each with a politeness level. Assistive plugins use both: a screen reader speaks the focused node and announcements, switch access steps through focusable nodes, and voice control activates a node by its name. Tests find nodes by role and name as well as by id.

## One-handed use

A two-handed gesture is never the only path to an action:

- Panel scaling with two hands has a one-handed alternative through the resize frame.
- A canvas that zooms with two hands also zooms with the thumbstick, the wheel, or zoom controls.
- The wrist menu opens from a controller binding or a palm-up gesture on either hand, as well as from the other hand's touch. In one-handed mode, it opens on the `summoned` presentation, operated by the present hand's ray.
- Every action reachable by pointing is also reachable through focus traversal on one controller, as [Input](input.md#focus-traversal) lists.

## Colour and contrast

- Body text has a contrast ratio of at least 4.5 to 1 against its surface, and control boundaries, focus rings, toggle tracks, and state layers over the accent have at least 3 to 1. The ratios hold in every interaction state, including at full hover and press state-layer strength.
- Surfaces behind text are opaque, or at least as opaque as a theme minimum, because an overlay session composites panels over another application or over passthrough, and contrast against a translucent surface depends on what is behind it.
- No state is conveyed by colour alone. Status colours come with an icon or a label, and the disabled state comes with its reason.
- The default accent and status colours remain distinguishable under the common forms of colour blindness.
- The theme contract includes a high-contrast variant.

A test checks every pair of text and surface tokens in each shipped theme against these ratios, in each state, so a theme cannot regress them.

## Target assistance

Users with tremor or limited precision benefit from targets that are easier to hit. Owner-scoped `pick` hooks let a plugin implement a bubble cursor, magnetic snapping to targets, or a larger sticky margin, using the proximity query for rays that miss, as [Extension](extension.md#interaction-extension) describes. A dwell interactor selects by holding still, using the same select progress that a trigger produces, and switch access drives the traversal service.

## Localisation

Layout mirrors for right-to-left text through an inherited direction, alignment is logical, and text styles carry a language tag, as [Layout and text](layout-and-text.md) describes. Directional focus traversal and slider orientation mirror with the layout. Bidirectional editing and input-method composition remain open, and until they exist a user of a right-to-left script cannot edit mixed-direction text in a toolkit field.

Interface text uses sentence case for labels and titles, and disabled reasons are full sentences that say what makes the control available.
