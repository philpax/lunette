# Theming

The [theme provider](../../../lua/lunette-plugins/ui/theme/README.md) owns the session's theme. Its [contract](../../../lua/lunette-contracts/theme.luau), schema, and checked source own token groups, defaults, and supported mutations. Token tables are not duplicated here.

## Units

Sizes are authored in metres. Touch activation, fingertip movement, panel poses, and reach are physical quantities, so the authoring unit does not depend on an assumed viewing distance.

Angular guidance still informs legibility and ray targeting. At 1 metre, 1 degree spans about 17.5 mm. That conversion needs a viewing distance, and headset pixels per degree also affect legibility. A physical panel moved farther away becomes smaller in the field of view. The host does not automatically scale it to preserve angular size or clamp text against a presentation's nominal distance.

A consumer must preserve both sufficient physical target size for touch and sufficient angular size for distant rays. Enlarging a panel does not change the physical poke activation and recoil distances.

## Token structure

Kinds resolve shared appearance through theme tokens instead of hard-coding one palette and control size. Spacing and typography changes can require layout; colour changes require drawing updates. A theme remains available to surfaces outside the toolkit, including keyboard drawing, rays, cursors, and panel outlines.

A caller that changes mode or accent requires the theme service explicitly. The host exposes `theme()` only to read the effective toolkit appearance: the current theme normally and the base theme during default appearance. It does not duplicate the theme's mutation methods.

## Target sizes

Published target guidance differs substantially. Microsoft gives a 1-degree ray minimum and a larger touch target. Meta and Android XR recommend larger angular targets. [Research](research.md#xr-design-guidance) records the original guidance and conversions.

Those figures inform the checked token values rather than defining independent defaults here. Real-headset evaluation remains necessary. The host does not negotiate target density from a presentation or automatically expand every hit volume halfway into the surrounding gap.

## Typography

UI and monospace roles establish hierarchy without per-panel font selection. Light strokes at small sizes can vibrate in a headset, so themes need adequate weight as well as size. Text scale can change wrapping and panel dimensions; fixed-size layouts must leave a scrolling or wrapping path.

The host does not enforce the proposed angular minimum. Readability at a panel's actual distance remains the responsibility of the theme and consumer. Native shaping and fallback do not remove this constraint.

## Colours

Colour roles distinguish surfaces, content, headers, accents, and status. Depth supplements hover and press state. Status and disabled states also need labels, icons, or reasons so colour is not the only cue.

Pure white can halate, and pure black can smear or become transparent on additive displays. Translucent text surfaces also depend on the application or passthrough behind them. [Accessibility](accessibility.md#colour-and-contrast) states the contrast requirements and their verification boundary.

### The accent

The theme adjusts an accent to preserve contrast against its surface and selects contrasting ink. The theme service owns the chosen and applied colour state. A settings consumer can show both when the applied colour differs. This adjustment belongs to the theme rather than a second host-side accent setting.

## Elevation

Elevation separates faces in stereo and provides hover lift and press travel. Distinct surfaces and a node's own content need small positive separations to avoid depth fighting. Press travel must not make a control coplanar with its parent. The actual distances belong to theme source.

Overlays stay near their opener rather than using a large popup offset that appears detached from the side. Dialogs need more separation because they are independent panels. Large scrolling regions should not be raised as whole slabs solely to distinguish their contents.

Geometry behind an opaque panel face is hidden. A truly recessed field needs an opening in that face; a darker field fill alone does not establish such geometry. Themes and visuals must agree about whether a control is raised or recessed.

## The default theme

The standard visual language uses restrained corner rounding, header bands, visible face edges, and depth response. The accent marks selection and a small number of controls rather than tinting every surface. These choices distinguish content hierarchy without relying on drop shadows, which are weak depth cues in a headset.

### Shape and depth

Raised controls use visible sides so oblique views do not show an unsupported floating face. Header and separator treatment stays distinct from control faces. Exact radii, edge colours, and side depth belong to the standard visuals.

### Headers

Header bands establish hierarchy through a shared surface and ink rather than unrelated label colours. Secondary text within a header must use that header's contrast context.

### Marks and selection

Selection uses more than colour where possible, including position, depth, and explicit marks. Statuses remain readable words rather than requiring a user to interpret a decorative colour or shape.

### Type

The bundled UI and monospace families serve different reading tasks. Monospace suits identifiers, paths, code, and shortcuts rather than every value or label. Font files and licensing belong in [CREDITS.md](../../../CREDITS.md).

### Palettes

Light and dark palettes retain a shared visual hierarchy. Source owns their exact colours. Headset evaluation needs both frontal and oblique views because contrast, depth, and edge treatment change together.

### Motion and feedback

The host uses theme timing for its motion channels and standard interaction response. It does not expose a complete token-driven sound, haptic-pattern, and shader-binding dispatcher. [Motion and feedback](motion-and-feedback.md) states the implemented boundary.
