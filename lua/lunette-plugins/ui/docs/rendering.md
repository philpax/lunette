# UI rendering

The UI provider draws declared panel and control geometry in a caller's scene pass. Its contract keeps logical geometry shared by input, drawing, and inspection. Rounded perimeter construction is in [rounded geometry](../../theme/docs/rounded-geometry.md).

## Content clips

Panel backing follows the rounded silhouette, but controls, text, and input use a conservative rectangular clip. The clip does not change declared bounds or input geometry. Default control faces are clipped; custom hooks receive the clip as `visual.clip` and must enforce it on their own geometry and shaders.

Stencil and offscreen clipping would add pass requirements and composition cost. The rectangular clip leaves less room near rounded corners, but keeps small controls' hit targets usable.

## Scene depth

Opaque backing and outlines write depth. Controls, details, and glyphs draw in painter order without depth writes, using small nested offsets to separate coplanar parts. Intersecting or nearly coincident panels can still show draw-order artefacts.

A draw hook wraps the default renderer and receives the same visual geometry. Each invocation restores pass state and transforms, including on error. Draw errors propagate to the frame boundary; widget callback errors are reported with the control owner.

## Text and titlebars

The default choice header displays its label and selected value, with a chevron that indicates whether it is open. LÖVR's default font lacks arrow glyphs, so the chevron uses strokes. Logical coordinates are y-down while glyphs are y-up; the default renderer rotates text, and custom hooks that draw text must do the same.

A titlebar draws its face, text, and actions in a pass supplied by its owner. Joined-frame geometry is specified in [panel rendering](../../panels/docs/rendering.md#joined-flat-frames); the [shared panels and UI contract](../../../lunette-contracts/panels-and-ui.md) defines attachment eligibility.

## Decisions

One-millimetre offsets separate controls, contents, and glyphs without accumulating depth across controls. Per-panel masks are not used; intersecting panels can therefore show draw-order artefacts. Small controls retain rectangular hit targets instead of losing usable area to perimeter-chord clipping.

The replaceable `lunette/ui` provider lets configurations change control policy without importing a widget implementation. Larger interfaces remain Wayland clients.
