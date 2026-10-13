# UI rendering

The UI provider draws declared panel and control geometry in a caller's scene pass. Its contract keeps one logical geometry for input, drawing, and inspection; [UI panels in the Lua API](../../../../docs/dev/lua-api.md#ui-panels) defines that boundary. Shared rounded perimeter construction is specified in [rounded geometry](../../theme/docs/rounded-geometry.md).

## Content clips

A UI panel's backing uses the full rounded silhouette. Controls, text, and input use a rectangular content clip inside it. The clip does not change declared panel or control bounds, so input geometry and inspection stay stable. Existing overflow indicators continue to report content that does not fit.

Rounded control faces keep rectangular hit targets. Default faces clip their polygons to the content clip. Text and custom hooks receive the clip as the rectangle `visual.clip` and must respect it. The provider cannot enforce the clip on an arbitrary shader. The `Visual` and draw-hook types are owned by the [`lunette/ui` contract](../../../../lua/lunette-contracts/ui.luau).

Stencil and offscreen clipping are not used. The passes they require and their composition cost are the reason the provider uses a conservative rectangular clip. The cost is less content room near rounded corners. Controls retain rectangular hit targets because clipping them to the perimeter chords would remove usable area from small controls.

## Scene depth

Only opaque backing and outline geometry writes depth. Controls, details, and glyphs draw in painter order without writing depth. Offsets follow nesting: the backing sits 2 mm in front of its surface, control faces sit 1 mm further, contents sit 1 mm further, and glyphs sit 1 mm further. These offsets separate coplanar parts without accumulating depth across controls. Intersecting or nearly coincident panels can show draw-order artefacts within that range.

The UI draw hook wraps the default renderer and receives the same logical visual geometry. Each hook invocation restores pass state and transforms, including on error. Draw errors propagate to the frame boundary. Widget callback errors are reported with the control owner. Custom hook geometry is not automatically clipped; the hook must use `visual.clip`.

## Choice headers and text orientation

A choice's default header draws its label and selected value as `Label: value`, or whichever of the two is nonempty, centred vertically in the first row, with a chevron at its right edge that points down while closed and up while open. The chevron is drawn as strokes because LÖVR's default font has no arrow glyphs. Glyphs are y-up while logical coordinates are y-down, so the default renderer turns text half a turn about x, and a draw hook that draws its own text does the same.

## Titlebars

A shared UI titlebar draws its face, text, and actions in a separate pass supplied by its owner. It can attach to a supported surface through `attachFrame`. Joined-frame perimeter and outline geometry are specified in [panel rendering](../../panels/docs/rendering.md#joined-flat-frames), so the panel and UI pages share one geometry definition. The attachment contract and eligibility are specified in [the Lua API](../../../../docs/dev/lua-api.md#joined-frame-attachments).

An attached titlebar keeps its own face, text, and actions while the target owns the single joined outline. When the target is ineligible, the titlebar draws as a separate flat frame. The titlebar style schema and defaults are in [`titlebar-style.luau`](../titlebar-style.luau); UI provider configuration is in [`config.luau`](../config.luau).

## Decisions

UI geometry offsets controls, contents, and glyphs by 1 mm steps without depth writes, so coplanar parts do not conflict and depth does not accumulate across controls. Intersecting panels can show draw-order artefacts within that span; per-panel masks were not added.

Small VR controls use the replaceable `lunette/ui` provider so a configuration can replace control policy without importing a widget implementation. Larger interfaces remain Wayland clients.

## Known gaps

Geometry recorders do not rasterise edges, alpha, depth, or fonts. Offscreen graphics checks establish selected single-sample rasterization, blending, and cutout-depth properties for the production aurora on lavapipe, not UI rendering. Stereo seams, headset comfort, and runtime-specific visibility transitions still require manual headset checks. The shared [rendering specification](../../../../docs/dev/rendering.md#known-gaps) records these acceptance limits.
