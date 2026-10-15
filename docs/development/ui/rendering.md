# Rendering

## Drawing in the scene

Panels draw directly into the scene pass every frame. Every node is real geometry at its own place, so elements are raised above the panel, separated from each other, and pressed in, and the eyes resolve that separation in stereo. Hands, controllers, and pointer rays depth-test against the panel and its elements.

Rendering a panel to an offscreen texture and drawing the texture is not used. It makes idle panels cheaper and gives real scissoring, but it flattens every element onto one plane, so depth, press travel, and separation between elements are lost. Rendering one texture per elevation level keeps coarse depth but not per-element depth or animated press travel, and every hover or press change re-renders a texture.

## Composition layers

UI panels do not claim composition layers. A composition layer is an OpenXR quad or cylinder that the runtime composites at its own rate, which gives sharper text because the image is resampled once. Layers are single-sided and rectangular, they do not depth-composite with the hands, controllers, or rays drawn in the scene, and they require the panel to be a flat texture, which the depth requirement rules out. lunette submits its window layers as opaque, and the layer budget is shared with window panels. The session does not use layers by default.

## The toolkit shader

Every node draws through one toolkit shader. The shader takes geometry in a node's local space and performs these steps:

1. For a bent node, it applies the node's transform in surface coordinates and maps the vertex onto the surface root's shape, selected by a shape id and parameters in the instance data. For a rigid node, it applies the node's frame. On a flat surface both are a single matrix.
2. It offsets the vertex along the normal by the node's elevation, including animated offsets such as hover lift and press travel.
3. In the fragment stage, it discards fragments outside the node's clip volume, and it evaluates the node's shape and border as a signed distance field, with an antialiasing width from screen-space derivatives on each axis.
4. It evaluates the node's bound parameters, as [Bound parameters](#bound-parameters) describes.

The shader's mapping, clipping, and binding code is also published as a shader include, so a mesh drawn with a custom material maps, clips, and responds to interactors exactly as the toolkit's own primitives do.

### Shapes

A box is drawn as a quad, and the fragment shader computes a rounded-rectangle signed distance field from the box size and corner radii. The distance field gives the fill, the border, and antialiased edges in one draw, so rounded shapes need no tessellated meshes or mesh caches.

A bent box on a curved surface is drawn as a grid subdivided along the curve, so that the vertex stage can bend it. The shape's tessellation hint selects the subdivision from a small fixed set of classes, and boxes of one class share one instanced mesh. Glyph quads on a curved surface use the same subdivision as boxes of their size, so text and the box beneath it follow the same curve. A box on a flat surface is one quad.

Glyphs are quads that sample a page of the glyph atlas, as [Layout and text](layout-and-text.md#glyph-rendering) describes. Images are quads that sample their texture. Lines, paths, and sectors go through the drawing API below.

### Clipping

A clip is a rounded rectangle in its clipping ancestor's coordinates with a depth range, as [Spatial model](spatial-model.md#clip-volumes) defines. Every draw carries the clip of its nearest clipping ancestor within its bounds root: the panel, a scroll box, or a box with `overflow = 'clip'`. Nested clips intersect. Two axis-aligned rectangles intersect to a rectangle. A nested rounded clip is approximated by the intersection rectangle with the inner clip's radii, and the approximation differs from an exact intersection only where two rounded corners overlap.

The fragment shader evaluates the clip before the shape. Clipping in the shader has these properties:

- It follows the panel's pose and shape, because the clip is in surface coordinates. A framebuffer scissor is in screen space and cannot follow a posed panel.
- It clips at any elevation within the clip's depth range, because the test uses `u` and `v` before elevation.
- It clips exactly at rounded corners, so content can use the full area of a rounded panel.
- It needs no extra pass and does not split batches. Stencil clipping would need each clip shape drawn before the batches it clips, and it cannot express a depth range.

Custom drawing nodes and meshes are clipped by the same shader code, so a node cannot draw outside its clip. Hit testing applies the same clip, so a node is not hittable outside its clip.

### Drawing API

Visuals and custom drawing nodes draw through the host's drawing API rather than through a LÖVR `Pass`. The API offers:

- Boxes with fill, border, and radii, and rings.
- Linear, two-axis, radial, and conic gradient fills, for colour pickers, hue wheels, and edge fades.
- Lines and polylines with width, filled paths, and arcs and sectors, for graphs, wires, and radial menus.
- Text runs, icons, and images.
- Paths between anchors, whose end points follow other nodes or anchors, for wires between ports and leader lines from a label to a window.
- Meshes with a material, in the node's frame.

Every primitive goes through the toolkit shader, or through a material that includes its code, with the node's pose, clip, and surface shape. Visuals cannot change pass state, so no visual can leave the pass in a state that affects later drawing.

An image source is a texture handle with an explicit owner, a store of one, or an SVG document. A store lets an image change without a render, which a live window or monitor tile needs. A window's texture rotates as the client cycles its buffers, so a live tile reads `window:stabilize()`, never a cached `window:getTexture()`, and the host checks the handle's `dead` field every frame. Images from files are decoded by the native API off the main thread, with an owner-scoped handle that becomes ready when the decode finishes, because the lunette API is not available on `lovr.thread`. SVG documents, such as application icons from icon themes, are rasterised natively with resvg at the size they are drawn, and rasterised again when their drawn size changes by more than a threshold.

A mesh is drawn in its own unbatched draw, depth-tested and clipped like any other primitive. Meshes are rare in a panel, so the cost of the extra draws is bounded.

### Bound parameters

Some appearance changes every frame: a glow that follows a fingertip, a press face that follows the finger, a spinner's rotation, a hold ring filling, a hover state layer fading in, a scroll thumb's position. Visuals do not run every frame, so the drawing API lets a primitive bind a parameter to a value that the shader evaluates:

- A node's animation channels, as [Motion and feedback](motion-and-feedback.md#animation-channels) describes.
- The interactors near the panel. The host uploads each panel's active interactors every frame: the position or ray, the signed distance for a point interactor, and the select progress. A primitive can bind its fill, glow, or offset to the nearest interactor's distance or position on the surface.
- Node state that the host exports to the shader, such as a scroll box's offset and content size.

A binding is declared when the visual runs, for example `draw:box(bounds, { fill = colour, stateLayer = draw.channel('hover') })` or `draw:arc(bounds, { sweep = draw.channel('progress') })`. The standard kinds use the same bindings that third-party kinds use.

## Depth

Elevation is a node property in metres along the surface normal, accumulated from the node's ancestors. Theme tokens name the standard values: base, raised, card, popover, and dialog. [Theming](theming.md#elevation) gives their values. Hover lift and press travel are animated offsets added to a node's elevation.

Press travel stops at the minimum separation above the node's parent, so a pressed control never becomes coplanar with the surface beneath it.

Content inside a scroll box may be raised up to the `raised` value and no further, which is the default depth range of a scroll box's clip volume. Rows of raised buttons in a scrolling list are therefore drawn with their depth, and the clip edge cuts through at most a few millimetres of geometry. A scroll box is not itself elevated above its parent, following Android XR's guidance against elevating large scrollable areas.

## Draw order

A panel's nodes draw in tree order: a parent before its children, and earlier siblings before later ones. Depth separates content at different elevations, and separates the panel from hands, rays, and other panels.

- A node's own content, such as its text, icons, border, and focus ring, draws at a fixed content offset of 0.1 mm above the node's surface, so a label never depth-fights the box it sits on.
- Opaque fills write depth. Their antialiased edges use alpha to coverage with the session's multisampled target, so edges write depth too.
- State layers are part of a box's fill in the shader, not separate translucent quads, so a hover state layer never draws over its own label.
- Text and other translucent primitives test depth without writing it, and draw after the opaque batches of their panel.

Overlapping siblings at the same elevation are not ordered by depth. A design that overlaps content, such as stacked cards or a badge on a thumbnail, raises the upper content by an elevation step. This rule is chosen for simplicity, and it is revisited if real interfaces need same-elevation overlap.

Overlays and other portals are separate panels, drawn with the same rules at their own poses, as [Presentations](presentations.md#portals-and-overlays) describes.

## Opacity

A node's effective opacity is the product of its own opacity channel and its ancestors'. A panel or subtree whose effective opacity is below 1 draws after the opaque content of the scene, in two passes: a depth-only pass of the subtree, then its colour, blended, with an equal depth test. The subtree fades as one surface, its own overlapping parts do not show through each other, and it keeps hiding what is behind it as it fades. Most fades are of whole overlay panels, so the second pass is usually one panel.

## Curvature

A panel's curvature is a parameter of its surface shape. The standard cylinder is the model that window panels use in [`panels/service/private/shape.luau`](../../../lua/lunette-plugins/panels/service/private/shape.luau): a vertical cylinder of radius `1 / curve` with its centre on the viewer's side, and width measured along the arc. Drawing bends in the vertex shader. Hit testing intersects the query with the shape at the node's elevation and converts the hit to surface coordinates, as [Spatial model](spatial-model.md#surface-roots) defines.

Overlays and attached panels inherit their parent's shape: the same axis and the same centre, at their own elevation. A dropdown from a curved panel is therefore curved concentrically with it.

## Draw cost

Every visible node draws every frame. The host bounds that cost:

- The native side packs each panel's instance data into LÖVR buffers, one buffer per primitive class: one per box subdivision class, one per glyph atlas page, and one per image texture. Each node owns slots in the buffers it uses. A change to a node rewrites only its slots, and freed slots are reused or compacted, so a frame with no changes uploads nothing. Lua describes primitives once per visual run, and Rust writes the per-glyph and per-box instance data.
- Animation channels, transforms, and exported node state live in a separate small per-node buffer that the shader reads through each instance's node index. An animation or a pan rewrites only that buffer and never rebuilds instance data.
- Each panel draws one instanced draw per buffer. Images draw one draw per distinct texture, because LÖVR has no bindless textures.
- Per-instance data such as the clip, the shape parameters, colours, and radii lives in the instance data, so a change of clip does not split a batch.

Hit testing first rejects panels by their bounds, including their bounds roots, and then tests nodes from the panel's hit index, so a ray sweeping past a panel does not test each of its nodes.

## Open questions

- Translucent overlapping panels. Two intersecting panels with translucent fills can show draw-order artefacts, because the toolkit does not sort across panels.
- Whether the panel body has visible thickness at its edges. Thickness improves the sense of a physical object and costs a few extra quads.
