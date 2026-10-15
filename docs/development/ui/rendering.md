# Rendering

## Drawing in the scene

Panels draw directly into the scene pass every frame. Every node is real geometry at its own depth, so elements are raised above the panel, separated from each other, and pressed in, and the eyes resolve that separation in stereo. Hands, controllers, and pointer rays depth-test against the panel and its elements.

Rendering a panel to an offscreen texture and drawing the texture is not used. It makes idle panels cheaper and gives real scissoring, but it flattens every element onto one plane, so depth, press travel, and separation between elements are lost. Rendering one texture per elevation level keeps coarse depth but not per-element depth or animated press travel, and every hover or press change re-renders a texture.

## Composition layers

UI panels do not claim composition layers. A composition layer is an OpenXR quad or cylinder that the runtime composites at its own rate, which gives sharper text because the image is resampled once. Layers are opaque, single-sided, and rectangular, they do not depth-composite with the hands, controllers, or rays drawn in the scene, and they require the panel to be a flat texture, which the depth requirement rules out. The layer budget is shared with window panels, and the session does not use layers by default.

## The toolkit shader

Every node draws through one toolkit shader. The shader takes geometry in panel-local coordinates and performs four steps.

1. It offsets the vertex along the panel normal by the node's elevation.
2. For a curved panel, it maps the vertex onto the cylinder. Panel-local x becomes an angle, and the elevation becomes a radial offset towards the viewer, so stacking and curvature compose.
3. It converts the y-down panel-local space into the panel's y-up pose.
4. In the fragment stage, it discards fragments outside the node's clip, and it evaluates the node's shape and border as a signed distance field.

### Shapes

A box is drawn as a quad, and the fragment shader computes a rounded-rectangle signed distance field from the box size and corner radii. The distance field gives the fill, the border, and antialiased edges in one draw, so rounded shapes need no tessellated meshes or mesh caches.

A box on a curved panel is drawn as a quad subdivided into vertical strips, so that the vertex stage can bend it. The strip count depends on the box's width and the panel's curvature, with a fixed upper bound. A box on a flat panel is one quad.

Glyphs are quads that sample the glyph atlas, as [Layout and text](layout-and-text.md#glyph-rendering) describes. Images are quads that sample their texture. Lines and other shapes in custom drawing nodes go through the drawing API below.

### Clipping

A clip is a rounded rectangle in panel-local coordinates. Every draw carries the clip of its nearest clipping ancestor: the panel, a scroll box, or a box with `overflow = 'clip'`. Nested clips intersect. Two axis-aligned rectangles intersect to a rectangle. A nested rounded clip is approximated by the intersection rectangle with the inner clip's radii, and the approximation differs from an exact intersection only where two rounded corners overlap.

The fragment shader evaluates the clip before the shape. Clipping in the shader has these properties:

- It follows the panel's pose, because the clip is in panel-local space. A framebuffer scissor is in screen space and cannot follow a posed panel.
- It clips at any elevation. A raised card inside a scroll box clips against the scroll box's rectangle, because the clip test uses panel-local x and y before elevation.
- It clips exactly at rounded corners, so content can use the full area of a rounded panel. Clipping geometry on the CPU against a conservative inner rectangle would waste the area near the corners.
- It needs no stencil buffer, which the session does not enable, and no extra pass.

Custom drawing nodes are clipped by the same shader, so a node cannot draw outside its clip.

Hit testing applies the same clip, so a node is not hittable outside its clip.

### Drawing API

Visuals and custom drawing nodes draw through the host's drawing API rather than through a LÖVR `Pass`. The API offers boxes with fill, border, and radii; rings; lines and polylines with width; text runs; images; and icons. Every primitive goes through the toolkit shader with the node's clip, elevation, and the panel's curvature. Visuals cannot change pass state, so no visual can leave the pass in a state that affects later drawing.

## Depth

Elevation is a node property in metres along the panel normal. Theme tokens name the levels: base, raised, card, popover, and dialog. [Theming](theming.md#elevation) gives their values. A node's elevation is relative to its parent's, so a raised button on a card sits above the card.

Opaque surfaces write depth. Text, icons, and translucent fills test depth but do not write it, and they draw after the opaque surfaces of their elevation level. Within one elevation level, siblings draw in tree order. Elevation levels are separated by millimetres or more, so depth precision does not cause fighting between levels.

Press travel moves a pressed control towards the panel by a token distance, and hover raises a control slightly. Both are node state, animated by the host, and they change no layout.

Scrollable content is not elevated above its scroll box, following Android XR's guidance, because moving raised content under a clip edge makes the clip visible as a cut through solid geometry.

Overlays such as popovers, menus, and dialogs draw at the popover and dialog elevations and are clipped by their own bounds rather than by the panel. A dropdown menu can therefore extend beyond the panel's edge.

## Curvature

A panel's curvature uses the model that window panels use in [`panels/service/private/shape.luau`](../../../lua/lunette-plugins/panels/service/private/shape.luau): a vertical cylinder of radius `1 / curve` with its centre on the viewer's side, and width measured along the arc. Drawing bends in the vertex shader. Hit testing intersects the ray with the cylinder at the node's elevation, which is a cylinder of smaller radius, and converts the hit to panel-local coordinates with the same mapping as `shape.hit`. The arrangement service persists each panel's curvature with its pose and size.

## Draw cost

Every visible node draws every frame. The host bounds that cost:

- The host keeps per-panel instance buffers of box, glyph, and image quads, and rebuilds them only when a node's layout, props, or visual state changes. A frame with no changes draws from the existing buffers.
- Boxes, glyphs, and images of one elevation level draw as instanced draws from those buffers, rather than as one draw call per node.
- Per-draw data such as the clip, elevation, colour, and radii lives in the instance data, so a change of clip does not split a batch.

## Open questions

- Translucent overlapping panels. Two intersecting panels with translucent fills can show draw-order artefacts, because the toolkit does not sort across panels.
- Whether the panel body has visible thickness at its edges. Thickness improves the sense of a physical object and costs a few extra quads.
