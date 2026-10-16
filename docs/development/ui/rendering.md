# Rendering

## Drawing in the scene

Panels draw directly into the scene pass every frame. Every node is real geometry at its own place, so elements are raised above the panel, separated from each other, and pressed in, and the eyes resolve that separation in stereo. Rays, cursors, and lunette's fingertip proxies depth-test against the panel and its elements.

lunette runs as an overlay session, so it does not occlude against the depth of the application beneath it. A user's real hand, as the base application or passthrough shows it, is hidden behind a panel that lunette draws in front of it. lunette therefore draws its own fingertip proxy for touch, as [Motion and feedback](motion-and-feedback.md#fingertip-proxy) describes.

Rendering a panel to an offscreen texture and drawing the texture is not used. It makes idle panels cheaper and gives real scissoring, but it flattens every element onto one plane, so depth, press travel, and separation between elements are lost. Rendering one texture per elevation level keeps coarse depth but not per-element depth or animated press travel, and every hover or press change re-renders a texture.

## Composition layers

UI panels do not claim composition layers. A composition layer is an OpenXR quad or cylinder that the runtime composites at its own rate, which gives sharper text because the image is resampled once. Layers are single-sided and rectangular, they do not depth-composite with the rays and proxies drawn in the scene, and they require the panel to be a flat texture, which the depth requirement rules out. lunette submits its window layers as opaque quads, and the layer budget is shared with window panels. The session does not use layers by default.

## The toolkit shader

Every node draws through one toolkit shader. The shader takes geometry in a node's local space and performs these steps:

1. For a bent node, it applies the node's composed transform in surface coordinates and maps the vertex onto the surface root's shape, selected by a shape id and parameters in the instance data. For a rigid node, it applies the node's frame. On a flat surface both are a single matrix.
2. It offsets the vertex along the normal by the node's elevation, including animated offsets such as hover lift and press travel.
3. In the fragment stage, it discards fragments outside the node's clip volume, and it evaluates the node's shape and border as a signed distance field, with an antialiasing width from screen-space derivatives on each axis.
4. It evaluates the node's bound parameters, as [Bound parameters](#bound-parameters) describes.

The shader declares its output position invariant, and the mapping, clipping, and binding code is published as a shader include, so a mesh drawn with a custom material maps, clips, and responds to interactors exactly as the toolkit's own primitives do, and produces identical depth in both passes of a fade.

### Shapes

A box is drawn as a quad, and the fragment shader computes a rounded-rectangle signed distance field from the box size and corner radii. The distance field gives the fill, the border, and antialiased edges in one draw, so rounded shapes need no tessellated meshes or mesh caches.

A bent box on a curved surface is drawn as a grid subdivided along the curve, so that the vertex stage can bend it. The shape's tessellation function chooses the subdivision from the box's size and composed scale, so the chord error stays within a tolerance, and the host chooses again when the composed scale changes enough to cross a class. Boxes of one subdivision class share one instanced mesh. A box on a flat surface is one quad.

A node's content, such as its text, icons, border, and focus ring, maps through its box's subdivision rather than through the exact surface: the shader places each content vertex on the same flat chord of the box that lies beneath it. Content therefore sits exactly the content offset in front of the drawn box on any curve, however coarse the subdivision. Hit testing uses the same chords, so a hit agrees with what is drawn.

Glyphs are quads that sample a page of the glyph atlas, as [Layout and text](layout-and-text.md#glyph-rendering) describes. Images are quads that sample their texture. Lines, paths, and sectors go through the drawing API below.

### Clipping

A clip is a rounded rectangle in its clipping ancestor's coordinates with a depth range, as [Spatial model](spatial-model.md#clip-volumes) defines. Every draw refers to the clip of its nearest clipping ancestor by that ancestor's node index, and the shader reads the clip's current size from the per-node buffer, so an animated clip, such as a section revealing its content, changes no descendant's instance data. Nested clips intersect. Two axis-aligned rectangles intersect to a rectangle. A nested rounded clip is approximated by the intersection rectangle with the inner clip's radii, and the approximation differs from an exact intersection only where two rounded corners overlap.

The fragment shader evaluates the clip before the shape. For bent content, it tests the fragment's surface coordinates. For rigid content and meshes, it maps the fragment's position back to surface coordinates through the shape's inverse first. Clipping in the shader has these properties:

- It follows the panel's pose and shape, because the clip is in surface coordinates. A framebuffer scissor is in screen space and cannot follow a posed panel.
- It clips at any elevation within the clip's depth range.
- It clips exactly at rounded corners, so content can use the full area of a rounded panel.
- It needs no extra pass and does not split batches. Stencil clipping would need each clip shape drawn before the batches it clips, and it cannot express a depth range.

Custom drawing nodes and meshes are clipped by the same shader code, so a node cannot draw outside its clip. Hit testing applies the same clip, so a node is not hittable outside its clip.

### Drawing API

Visuals and custom drawing nodes draw through the host's drawing API rather than through a LÖVR `Pass`. The API offers:

- Boxes with fill, border, and radii, and rings.
- Linear, two-axis, radial, and conic gradient fills, for colour pickers, hue wheels, and edge fades.
- Lines and polylines with width, filled paths, and arcs and sectors, for graphs, wires, and radial menus.
- Text runs, icons, and images.
- Paths between anchors, whose end points are node or anchor references that the host resolves every frame. A path whose ends share a surface root is drawn in that surface's coordinates and bends with it. A path between surface roots, such as a leader line from a label to a window, is drawn in the scene.
- Meshes with a material, in the node's frame.

Every primitive goes through the toolkit shader, or through a material that includes its code, with the node's pose, clip, and surface shape. Visuals cannot change pass state, so no visual can leave the pass in a state that affects later drawing.

An image source is a texture handle with an explicit owner, a store of one, or an SVG document. A store lets an image change without a render, which a live window or monitor tile needs. A window's texture rotates as the client cycles its buffers, so a live tile reads `window:stabilize()`, never a cached `window:getTexture()`, and the host checks the handle's `dead` field every frame. Images from files are decoded by the native API off the main thread into a shared image atlas, with an owner-scoped handle that becomes ready when the decode finishes, because the lunette API is not available on `lovr.thread`. A grid of thumbnails therefore draws in a few draws rather than one per image. SVG documents, such as application icons from icon themes, are rasterised natively with resvg at the size they are drawn, and rasterised again when their drawn size changes by more than a threshold.

`lunette.rasterizeSvg` fits a document into a canvas of the requested pixel size, centred with its aspect ratio preserved, and returns straight-alpha RGBA8 pixels, the layout LÖVR images use. It reads nothing but the document: hrefs to files are not followed, so an icon cannot make the main thread read the filesystem. Text elements are not drawn, because resvg is built without text shaping; an icon that spells its glyphs as text loses them.

A mesh is drawn in its own unbatched draw, depth-tested and clipped like any other primitive. Meshes are rare in a panel, so the cost of the extra draws is bounded.

### Bound parameters

Some appearance changes every frame: a glow that follows a fingertip, a press face that follows the finger, a spinner's rotation, a hold ring filling, a hover state layer fading in, a scroll thumb's position. Visuals do not run every frame, so the drawing API lets a primitive bind a parameter to a value that the shader evaluates:

- A node's animation channels, as [Motion and feedback](motion-and-feedback.md#animation-channels) describes.
- The interactors near the panel. The host uploads up to four active interactors per panel every frame: the position or ray, the signed distance for a point interactor, and the select progress. A binding combines all of them, by maximum or by sum, rather than following the nearest, so two fingertips at similar distances do not make a glow jump between hands.
- Node state that the host exports to the shader, such as a scroll box's offset and content size.

A binding is declared when the visual runs, for example `draw:box(bounds, { fill = colour, stateLayer = draw.channel('hover') })` or `draw:arc(bounds, { sweep = draw.channel('progress') })`. The standard kinds use the same bindings that third-party kinds use.

## Depth

Elevation is a node property in metres along the surface normal, accumulated from the node's ancestors. Theme tokens name the standard values: base, raised, card, popover, and dialog. [Theming](theming.md#elevation) gives their values. Hover lift and press travel are animated offsets added to a node's elevation.

Press travel stops at the minimum separation above the node's parent, so a pressed control never becomes coplanar with the surface beneath it.

Content inside a scroll box may be raised up to the `raised` value and no further, and the scroll box's default clip depth range covers that value plus hover lift and the content offset. Rows of raised buttons in a scrolling list are therefore drawn with their depth, and the clip edge cuts through at most a few millimetres of geometry. A scroll box is not itself elevated above its parent, following Android XR's guidance against elevating large scrollable areas.

## Draw order

A panel's nodes draw in batches, and depth decides what is in front:

- Content at different elevations is separated by depth, and the panel is separated from rays, proxies, and other panels by depth.
- A node's own content, such as its text, icons, border, and focus ring, draws at a content offset of 0.25 mm in front of the node's surface, so a label never depth-fights the box it sits on. The offset is large enough to resolve with the 24-bit depth buffer that LÖVR falls back to, at the farthest comfortable viewing distance.
- Opaque fills write depth. Their antialiased edges use alpha to coverage with the session's multisampled target, so edges write depth too.
- State layers are part of a box's fill in the shader, not separate translucent quads, so a hover state layer never draws over its own label.
- Translucent fills, which a theme may use for surfaces, draw from a separate buffer sorted in tree order, after the opaque batches and before text.
- Text and other translucent primitives test depth without writing it, and draw last.

Overlapping siblings at the same elevation need an order. A node that declares a stacking context, such as a node editor's canvas, assigns its children stacking orders, and the shader applies each order as a small depth bias in clip space rather than as geometry. Bringing a child to the front changes its order. The orders are bounded per stacking context, so the total bias stays within the minimum elevation separation, and hit testing breaks ties by the same order. Without a stacking context, overlapping siblings at the same elevation have no defined order, and a design that overlaps content raises the upper content by an elevation step.

Overlays and other portals are separate panels, drawn with the same rules at their own poses, as [Presentations](presentations.md#portals-and-overlays) describes.

## Opacity

A node's effective opacity is the product of its own opacity channel and its ancestors'. A panel or subtree whose effective opacity is below 1 leaves the opaque batches, because the opaque pass discards instances whose node's effective opacity is below 1. It draws after the opaque content of the scene, in a frame-service phase for faded content, in two passes:

1. A depth-only pass of the subtree's opaque primitives.
2. The subtree's opaque primitives in colour, blended, with an equal depth test and alpha to coverage on their edges, followed by its text and translucent primitives with a less-or-equal depth test and no depth writes.

The subtree fades as one surface, its own overlapping parts do not show through each other, and it keeps hiding what is behind it as it fades. Below a small opacity, the depth pass is skipped, so a nearly invisible panel does not hide rays and cursors behind it. Most fades are of whole overlay panels, so the second pass is usually one panel.

## Curvature

A panel's curvature is a parameter of its surface shape. The standard cylinder is the model that window panels use in [`panels/service/private/shape.luau`](../../../lua/lunette-plugins/panels/service/private/shape.luau): a vertical cylinder of radius `1 / curve` with its centre on the viewer's side, and width measured along the arc. Drawing bends in the vertex shader. Hit testing intersects the query with the drawn chords at the node's elevation and converts the hit to surface coordinates, as [Spatial model](spatial-model.md#surface-roots) defines.

Overlays and attached panels inherit their parent's shape: the same axis and the same centre, at their own elevation. A dropdown from a curved panel is therefore curved concentrically with it.

## Draw cost

Every visible node draws every frame. The host bounds that cost:

- The native side packs each panel's instance data into LÖVR buffers, one buffer per primitive class: one per box subdivision class and shape variant, one per glyph atlas page, one for the image atlas, and one per other texture. Each node owns slots in the buffers it uses. A change to a node rewrites only its slots, and freed slots are reused or compacted, so a frame with no changes uploads nothing. Lua describes primitives once per visual run, and Rust writes the per-glyph and per-box instance data.
- Composed transforms, animation channels, clip sizes, and exported node state live in a separate small per-node buffer that the shader reads through each instance's node index. An animation or a pan rewrites only that buffer and never rebuilds instance data.
- Each panel draws one instanced draw per buffer, using LÖVR's direct instanced draws or its indirect draws where a draw covers part of a buffer.
- Per-instance data such as the clip index, the shape parameters, colours, and radii lives in the instance data, so a change of clip does not split a batch.

Hit testing first rejects panels by their bounds, including their bounds roots, and then tests nodes from the panel's hit index, so a ray sweeping past a panel does not test each of its nodes.

## Open questions

- Translucent overlapping panels. Two intersecting panels with translucent fills can show draw-order artefacts, because the toolkit does not sort across panels.
- Whether the panel body has visible thickness at its edges. Thickness improves the sense of a physical object and costs a few extra quads.
- Whether visuals need pass state for gizmo handles that draw through other content, or additive glows.
