# Theming

The default theme's source owns the token values. The values below are starting points, given with the guidance they were chosen from. They are tuned in a headset, and the theme source is the reference once it exists.

## Units

Sizes are authored in metres. A presentation scale multiplies a whole panel, and a scale of 1 shows authored sizes at their physical size.

Metres are the unit because touch is physical. A fingertip needs a target of a physical size regardless of where the panel is, and a poke activation depth is a physical distance. Metres are also the unit of every other spatial quantity in the session: panel sizes, poses, reach, and panel radii.

Angular sizes, such as degrees or distance-independent millimetres, are the unit of most published XR design guidance, because legibility and ray targeting depend on the angle a target subtends at the eye. They are not used as the authoring unit for three reasons. An angular size has no meaning without an assumed viewing distance, and panels move. Legibility at a given angle also depends on the headset's pixels per degree, so angular guidance is not portable across headsets either. And authors reason about physical objects more easily than about angles.

Angular guidance is used to choose defaults instead. At 1 metre, 1 degree is 17.5 millimetres, and 1 distance-independent millimetre is 1 millimetre. The default tokens assume a world panel viewed at about 1 metre with a scale of 1, so the angular figures from published guidance convert directly into token values. A summoned panel placed further away uses a scale above 1, so that its angular size matches a world panel at 1 metre.

Two constraints apply to every presentation:

- A ray target must subtend enough angle at its viewing distance. This constraint grows with distance, so far presentations scale up.
- A touch target must have enough physical size for a fingertip. This constraint does not change with distance, so a touch presentation does not scale below 1, and touch parameters such as activation depth never scale.

The comfortable density in [Target sizes](#target-sizes) satisfies the touch constraint at scale 1.

## Token structure

The UI tokens are part of the global theme contract, [`lua/lunette-contracts/theme.luau`](../../../lua/lunette-contracts/theme.luau), and keep its structure of named groups.

| Group | Tokens |
|---|---|
| Spacing | A scale of named steps: `xs`, `sm`, `md`, `lg`, `xl`, `2xl`, `3xl` |
| Typography | Roles: `caption`, `body`, `label`, `title`, `headline`, `code`, each with family, size, weight, and line height |
| Colours | Surface, content, accent, and status roles, state layers, and a high-contrast variant |
| Radii | `control`, `card`, `panel`, `full` |
| Elevation | `base`, `raised`, `card`, `popover`, `dialog`, the minimum separation, and the press travel and hover lift distances |
| Density | `compact` and `comfortable` variants of control heights and minimum target sizes |
| Motion | Specs for the roles enter, exit, emphasis, layout, spatial, gesture, continuous, and feedback, each a spring, a tween, or a loop with a reduced-motion substitute, and the scroll friction and overscroll constants |
| Feedback | A haptic pattern, a sound, and a visual cue for each named feedback event and modality |
| Cursor | The hover and select ring sizes, their proportion, and the cursor's offset along the hit normal |

Components and kinds refer to tokens by name. A theme change that changes a size relayouts the affected nodes, and one that changes only colours redraws them without relayout. A dense panel such as the plugin manager requests the compact density rather than overriding individual sizes, and its presentation decides whether it gets it, as [Presentations](presentations.md#density) describes.

## Target sizes

| Guidance | Ray and mouse | Touch |
|---|---|---|
| Microsoft Mixed Reality | At least 1 degree, stated at 2 m, which is 35 mm there | 2 degrees at 45 cm, which is about 16 mm |
| Meta Horizon OS hand interaction | A minimum collider size of 2.5 to 3 degrees, 44 to 52 mm at 1 m | Same angular range |
| Android XR | 48 dp minimum and 56 dp recommended, about 42 and 49 mm at 1 m | Same |
| Apple visionOS | 60 points including padding. Points have no fixed physical size, so the figure is not converted | Same |

The default control heights are 36 mm for the compact density and 48 mm for the comfortable density.

A node's hit volume extends beyond its visible bounds into the spacing around it, by up to half the gap to its neighbours, so that adjacent targets meet without overlapping, following Meta's guidance on invisible hit slop. Hit slop is part of the node's hit volume, so a visual override cannot change it, and it never extends beyond the node's clip. Spacing between targets is at least `sm`.

Published guidance spans a factor of three and depends on display resolution, so these values are tuned in a headset.

## Typography

The default type scale at scale 1:

| Role | Size | Use |
|---|---|---|
| `caption` | 10 mm | Secondary text, hints, status |
| `body` | 12 mm | Paragraphs and list rows |
| `label` | 12 mm, medium weight | Control labels |
| `title` | 16 mm | Panel and section titles |
| `headline` | 22 mm | Large headings |
| `code` | 11 mm, monospace | Identifiers, paths, and diagnostic text |

The sizes are authored for a presentation's nominal viewing distance of 1 metre. Body text at 12 mm subtends about 0.7 degrees there. Microsoft gives 0.6 to 0.75 degrees as comfortable at 2 metres and 0.65 to 0.8 degrees at 45 centimetres, so body text is comfortable across that range. No role is smaller than 9 mm, about 0.5 degrees at 1 metre, which is at or above Microsoft's minimum legible size at both distances, 0.35 to 0.4 degrees at 2 metres and 0.4 to 0.5 degrees at 45 centimetres, and keeps distance field glyphs clear of their small-size artefacts. The minimum is angular: 0.5 degrees at the presentation's nominal viewing distance, after the accessibility text scale and the presentation scale. The host clamps every resolved text size to it when it resolves styles, and world panels keep their angular size as they move, so text stays legible at any distance.

Light and thin weights are avoided at small sizes, because thin strokes vibrate in a headset. A theme uses at most two families: a UI family and a monospace family.

## Colours

The colour roles are grouped by purpose: surfaces at each elevation, content on those surfaces, an accent, and status colours for error, warning, and success. Interaction states are state layers: a translucent overlay of the content colour at a fixed opacity for hover, press, focus, and drag, in the manner of Material Design. State layers keep the theme small, because a role needs no hovered and pressed variants of its own.

Themes avoid pure black and pure white. Pure white halates on headset displays, and Meta recommends light backgrounds no brighter than #DADADA. Pure black smears on some panels and becomes transparent on additive and passthrough displays. The contrast rules are in [Accessibility](accessibility.md#colour-and-contrast).

Disabled content uses reduced opacity together with a second cue, such as the absence of a hover state and the disabled reason tooltip, so that the state is not conveyed by colour alone.

## Elevation

Elevation separates elements in depth. The default values at scale 1:

| Level | Offset | Use |
|---|---|---|
| `base` | 0 mm | Panel body and flat content |
| `raised` | 3 mm above the parent | Buttons, toggles, and other controls |
| `card` | 6 mm above the parent | Grouped content within a panel |
| `popover` | 24 mm above the opener | Dropdown menus, context menus, and tooltips |
| `dialog` | 48 mm in front of its parent panel where it is shown over it | Modal dialogs |

The minimum separation between distinct elevations is 0.5 mm, and a node's own content draws 0.1 mm above its surface. Press travel is 2.5 mm, so a pressed raised control moves down to the minimum separation above the panel surface without becoming coplanar with it, and touch activation at 2 mm happens before the travel runs out. Hover lift is 1 mm. The popover and dialog values follow Android XR's elevations of 32 dp and 56 dp. The control values follow StereoKit, whose controls have 10 mm of depth and activate at half of it, reduced because a desktop-density panel has many more controls than a StereoKit window.

Elevation is a stereo depth cue and replaces drop shadows, which read weakly in a headset. Content inside a scroll box is raised at most to `raised`, as [Rendering](rendering.md#depth) explains.

## Visual language

The default theme uses generous spacing, hierarchy through type and elevation, one accent colour, and rounded shapes. Interactive elements respond to hover with a state layer and a lift, to press with travel and a darker state layer, and to activation with feedback. Controls look pressable: they are raised and have a defined boundary, while static content is flat.
