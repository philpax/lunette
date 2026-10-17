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

The [theme provider](../../../lua/lunette-plugins/ui/theme/README.md) owns the session's theme, whose types are in the [theme contract](../../../lua/lunette-contracts/theme.luau), as named groups of tokens. It sits below the UI host, so surfaces outside the toolkit keep their appearance while the host is disabled. Surfaces drawn outside the toolkit, such as the virtual keyboard, the laser, the mouse cursor, and window outlines, take their colours from the same theme.

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
| Meta Horizon OS hand interaction | Roughly 2.5 to 3 degrees, 44 to 52 mm at 1 m | Same angular range |
| Android XR | 56 dp recommended, about 49 mm at 1 m, around a 48 dp visual affordance | Same |
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

The sizes are authored for a presentation's nominal viewing distance of 1 metre. Body text at 12 mm subtends about 0.7 degrees there. Microsoft gives 0.6 to 0.75 degrees as comfortable at 2 metres and 0.65 to 0.8 degrees at 45 centimetres, so body text is comfortable across that range. No role is smaller than 9 mm, about 0.5 degrees at 1 metre, which is at or above Microsoft's minimum legible size at both distances, 0.35 to 0.4 degrees at 2 metres and 0.4 to 0.5 degrees at 45 centimetres, and keeps distance field glyphs clear of their small-size artefacts. The minimum is angular: 0.5 degrees at the presentation's nominal viewing distance, after the accessibility text scale and the presentation scale. The host clamps every resolved text size to it when it resolves styles. A world panel moved far beyond its nominal distance keeps its physical size by default, so its text shrinks in the field of view; a presentation that keeps its angular size avoids that, as [Presentations](presentations.md#pose-policies) describes.

Light and thin weights are avoided at small sizes, because thin strokes vibrate in a headset. A theme uses at most two families: a UI family and a monospace family.

## Colours

The colour roles are grouped by purpose: surfaces (the panel, raised faces, sunken fields, and the sides of raised geometry), content on those surfaces, the header bands, an accent, and status colours for error, warning, and success. Interaction states are expressed first through depth: hover lifts a control, press sinks it, and selection raises it. A state layer, a small shift of a face's lightness that the box shader mixes into its fill, supplements depth, so a role needs no hovered and pressed variants of its own. Tonal fills, translucent washes of the accent over a surface, are not used, because they are the most recognisable mark of other platforms' design languages.

Themes avoid pure black and pure white. Pure white halates on headset displays, and Meta recommends light backgrounds no brighter than #DADADA. Pure black smears on some panels and becomes transparent on additive and passthrough displays. The contrast rules are in [Accessibility](accessibility.md#colour-and-contrast).

Disabled content uses reduced contrast together with a second cue, such as the absence of a hover state and the disabled reason tooltip, so that the state is not conveyed by colour alone.

### The accent

The accent is the user's choice, from a set of presets or any colour. The theme guards it rather than rejecting it: it adjusts the chosen colour's lightness until the accent has a contrast of at least 3 to 1 against the panel surface, and it chooses the accent's ink, the colour of text on the accent, from a dark and a light ink, adjusting the accent further until that ink has at least 4.5 to 1. The theme reports the colour it applied, so a settings panel can show the chosen and applied colours side by side.

## Elevation

Elevation separates elements in depth. The default values at scale 1:

| Level | Offset | Use |
|---|---|---|
| `base` | 0 mm | Panel body, headers, and flat content |
| `raised` | 3 mm above the parent | Buttons, toggles, tabs, fields, list rows, and other controls |
| `card` | 6 mm above the parent | Grouped content within a panel |
| `popover` | One `raised` step above the opener | Dropdown menus, context menus, and tooltips |
| `dialog` | 48 mm in front of its parent panel where it is shown over it | Modal dialogs |

Overlays stack one step at a time: a menu stands 3 mm above the dropdown that opened it, and a submenu 3 mm above its menu. A larger offset, such as Android XR's 32 dp for popups, detaches an overlay from its opener when seen from the side, which a headset user does see. The dialog value follows Android XR's 56 dp, about 49 mm, because a dialog is its own presentation rather than an attachment to a control.

Selected items stand taller than their unselected neighbours by about one millimetre, and a selected radio option by about two, so selection is visible as depth as well as colour.

The minimum separation between distinct elevations is 0.5 mm, and a node's own content draws 0.25 mm above its surface. Press travel is 2.5 mm, so a pressed raised control moves down to the minimum separation above the panel surface without becoming coplanar with it, and touch activation at 2 mm happens before the travel runs out. Hover lift is 1 mm. The control values follow StereoKit, whose controls have 10 mm of depth and activate at half of it, reduced because a desktop-density panel has many more controls than a StereoKit window.

Nothing sits at a negative elevation. Geometry behind a panel's face is hidden by the face, so a recessed well would need a hole in the panel. Text fields are therefore raised slabs with a darker, inset-shaded face, not wells.

Elevation is a stereo depth cue and replaces drop shadows, which read weakly in a headset. Content inside a scroll box is raised at most to `raised`, as [Rendering](rendering.md#depth) explains.

## The default theme

The default theme, lunette, combines the shape and motion of a piece of hardware with a cool night palette. It was chosen by comparing interactive mockups of three directions, with the panels viewed from the side to judge their depth.

### Shape and depth

- Panels have small corner radii, about 3 mm, and controls smaller ones, about 1.5 mm, with visible edges: a light top edge and a dark bottom edge on every face.
- Every raised control has a side, a skirt of the `side` colour that runs from its face down to the surface beneath it, so from the side a control reads as a key rather than a floating card. A toggle's thumb and a slider's handle stand proud of their tracks in the same way.
- Headers, separators, progress bars, and slider rails are square-cut; controls keep their small radius.

### Headers

- A panel's title bar is a band that fills its row, in a header colour tinted with the accent, with the title in the band's ink and a rule tinted with the accent beneath. Secondary text and indicators in a header take the band's ink, not the panel's muted ink.
- Section headers are bands of the same family with a lighter accent tint, labelled in uppercase in the UI face.
- A table's header row is a band of the same kind, so it reads as a header rather than a row.

### Marks and selection

- The accent appears as rules, small solid fills, and the colour of a few words, not as washes over surfaces.
- A selected segment or tab carries a square accent underline.
- A pressed filter chip and a selected row in a list, tree, or table take a solid accent fill with the accent's ink.
- A selected radio option shows a solid accent disc and stands taller than the other options.
- The current item in a menu carries a check.
- Edge bars at the start of a selected row are not used.
- Statuses, such as Running, Failed, and Playing, are plain words in the UI face, with colour only on those that matter. They are not boxed badges.

### Type

The UI face is IBM Plex Sans, and the monospace face is Iosevka, both under the SIL Open Font License. Monospace is used for code, identifiers, paths, and keyboard shortcuts, not for labels or statuses. Values read like an instrument's: tabular figures, with units and detent names as a muted suffix, such as `0.75 HIGH`.

### Palettes

The dark mode uses cool blue-grey surfaces lifted off black; the light mode uses the same cool bias, with a cool mid-tone panel and lighter key faces, and keeps dark header bands with light ink, so both modes share a frame. The starting values:

| Role | Dark | Light |
|---|---|---|
| Surface | #161c29 | #c9cfd9 |
| Raised face | #1e2638 | #e0e4eb |
| Sunken face | #111622 | #b9c0cc |
| Side | #0c111b | #98a1b0 |
| Ink | #e2e8f2 | #232c40 |
| Muted ink | #94a0b6 | #4b566a |
| Line | #2c364c | #a0a9b8 |
| Header band | #212a3c | #46526b |
| Header ink | #e8edf5 | #f4f7fb |
| Default accent | #9fd3e6 | #9fd3e6, darkened by the guard |

The light mode's raised faces go slightly past Meta's #DADADA recommendation, because faces at #DADADA on a grey panel read as dead. They are tuned in a headset.

### Motion and feedback

Motion is crisp: critically damped, about 120 ms, with no overshoot. Presses click and detents tick, as hardware does.
