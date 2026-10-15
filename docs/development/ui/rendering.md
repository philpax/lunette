# Rendering

## Drawing in the scene

Panels draw directly into the scene pass every frame. Every node is real geometry at its own pose, so elements are raised above the panel, separated from each other, and pressed in, and the eyes resolve that separation in stereo. Hands, controllers, and pointer rays depth-test against the panel and its elements.

Rendering a panel to an offscreen texture and drawing the texture is not used. It makes idle panels cheaper and gives real scissoring, but it flattens every element onto one plane, so depth, press travel, and separation between elements are lost. Rendering one texture per elevation level keeps coarse depth but not per-element depth or animated press travel, and every hover or press change re-renders a texture.

## Composition layers

UI panels do not claim composition layers. A composition layer is an OpenXR quad or cylinder that the runtime composites at its own rate, which gives sharper text because the image is resampled once. Layers are single-sided and rectangular, they do not depth-composite with the hands, controllers, or rays drawn in the scene, and they require the panel to be a flat texture, which the depth requirement rules out. lunette submits its window layers as opaque, and the layer budget is shared with window panels. The session does not use layers by default.

## The toolkit shader

Every node draws through one toolkit shader. The shader takes geometry in a node's local space and performs these steps:

1. It applies the node's transform and maps the vertex onto the parent's surface shape, selected by a shape id and parameters in the instance data. A flat shape translates; a cylinder turns local x into an angle.
2. It offsets the vertex along the shape's normal by the node's elevation, including animated offsets such as hover lift and press travel, so stacking and curvature compose.
3. It applies the paint-order depth offset described in [Paint order](#paint-order).
4. In the fragment stage, it discards fragments outside the node's clip volume, and it evaluates the node's shape and border as a signed distance field, with antialiasing width from screen-space derivatives.

The vertex mapping is also published as a shader include, so a mesh drawn with a custom material maps, clips, and offsets exactly as the toolkit's own primitives do.

### Shapes

A box is drawn as a quad, and the fragment shader computes a rounded-rectangle signed distance field from the box size and corner radii. The distance field gives the fill, the border, and antialiased edges in one draw, so rounded shapes need no tessellated meshes or mesh caches.

A box on a curved surface is drawn as a quad subdivided into strips along the curve, so that the vertex stage can bend it. The surface shape's tessellation hint selects a strip count from a small fixed set of classes, and boxes of one class share one instanced mesh. A box on a flat surface is one quad.

Glyphs are quads that sample a page of the glyph atlas, as [Layout and text](layout-and-text.md#glyph-rendering) describes. Images are quads that sample their texture. Lines, paths, and sectors go through the drawing API below.

### Clipping

A clip is a rounded rectangle in its clipping ancestor's local space with a depth range, as [Spatial model](spatial-model.md#clip-volumes) defines. Every draw carries the clip of its nearest clipping ancestor: the panel, a scroll box, or a box with `overflow = 'clip'`. Nested clips intersect. Two axis-aligned rectangles intersect to a rectangle. A nested rounded clip is approximated by the intersection rectangle with the inner clip's radii, and the approximation differs from an exact intersection only where two rounded corners overlap.

The fragment shader evaluates the clip before the shape. Clipping in the shader has these properties:

- It follows the panel's pose and shape, because the clip is in local space. A framebuffer scissor is in screen space and cannot follow a posed panel.
- It clips at any elevation within the clip's depth range, because the test uses local x and y before elevation.
- It clips exactly at rounded corners, so content can use the full area of a rounded panel.
- It needs no extra pass and does not split batches. Stencil clipping would need each clip shape drawn before the batches it clips, and it cannot express a depth range.

Custom drawing nodes and meshes are clipped by the same shader code, so a node cannot draw outside its clip. Hit testing applies the same clip, so a node is not hittable outside its clip.

### Drawing API

Visuals and custom drawing nodes draw through the host's drawing API rather than through a LÖVR `Pass`. The API offers:

- Boxes with fill, border, and radii, and rings.
- Linear and two-axis gradient fills, for colour pickers and edge fades.
- Lines and polylines with width, filled paths, and arcs and sectors, for graphs, wires, and radial menus.
- Text runs, icons, and images.
- Meshes with a material, in the node's local space.

Every primitive goes through the toolkit shader, or through a material that includes its vertex mapping, with the node's pose, clip, and surface shape. Visuals cannot change pass state, so no visual can leave the pass in a state that affects later drawing.

An image source is a texture handle with an explicit owner, or a store of one. A store lets an image change without a render, which a live window or monitor tile needs. A window's texture rotates as the client cycles its buffers, so a live tile reads `window:stabilize()`, never a cached `window:getTexture()`. Images from files are decoded by the native API off the main thread, with an owner-scoped handle that becomes ready when the decode finishes, because the lunette API is not available on `lovr.thread`.

A mesh is drawn in its own unbatched draw, depth-tested and clipped like any other primitive. Meshes are rare in a panel, so the cost of the extra draws is bounded.

## Depth

Elevation is a node property in metres along the surface normal, relative to the parent's elevation. Theme tokens name the standard values: base, raised, card, popover, and dialog. [Theming](theming.md#elevation) gives their values. Hover lift and press travel are animated offsets added to a node's elevation. They move its geometry and do not change its place in paint order.

Press travel stops at the minimum separation above the node's parent, so a pressed control never becomes coplanar with the surface beneath it.

Content inside a scroll box may be raised up to the `raised` value and no further, which is the depth of the scroll box's clip volume. Rows of raised buttons in a scrolling list are therefore drawn with their depth, and the clip edge cuts through at most a few millimetres of geometry. A scroll box is not itself elevated above its parent, following Android XR's guidance against elevating large scrollable areas.

## Paint order

The host draws each panel in a defined paint order, which is tree order: a parent before its children, and earlier siblings before later ones. Batching by primitive type would break that order, because a sibling's text and the next sibling's box are in different batches. The shader therefore encodes paint order in depth instead of in submission order.

- Each node has a paint index within its panel, assigned in tree order during commit.
- The vertex stage moves each primitive towards the viewer by a depth offset proportional to its paint index. The offset is far smaller than the minimum separation between elevation values, so it never changes which of two separated surfaces is in front, but it decides every coplanar case in favour of the later node in paint order.
- Opaque fills and their antialiased edges write depth, using alpha to coverage with the session's multisampled target. Batches can then be drawn in any order, and a later sibling's box hides an earlier sibling's text wherever they overlap.
- Text and other translucent primitives test depth without writing it, and draw after the opaque batches of their panel.

The minimum separation between distinct elevation values is a theme constant. Elevation values that differ by less than it are treated as equal and ordered by paint index.

Overlays and other portals are separate panels, drawn with the same rules at their own poses, as [Presentations](presentations.md#portals-and-overlays) describes.

Opacity fades of opaque geometry, such as an exiting dialog, use alpha to coverage with an ordered dither, so a fade keeps writing depth and does not show the geometry behind the node through itself.

## Curvature

A panel's curvature is a parameter of its surface shape. The standard cylinder is the model that window panels use in [`panels/service/private/shape.luau`](../../../lua/lunette-plugins/panels/service/private/shape.luau): a vertical cylinder of radius `1 / curve` with its centre on the viewer's side, and width measured along the arc. Drawing bends in the vertex shader. Hit testing intersects the query with the shape at the node's elevation, which for the concave cylinder is a cylinder of smaller radius, and converts the hit to local coordinates with the same mapping as `shape.hit`.

Overlays and attached panels inherit their parent's shape: the same axis and the same centre, at their own elevation. A dropdown from a curved panel is therefore curved concentrically with it.

## Draw cost

Every visible node draws every frame. The host bounds that cost:

- Each panel keeps instance buffers of box, glyph, and image quads, with one slot range per node. A change to a node rewrites only its slots, and only the changed range is uploaded. A frame with no changes uploads nothing.
- Animation channels, including hover lift and press travel, live in a separate small per-node buffer that the shader reads. An animation rewrites only that buffer and never rebuilds instance data.
- Boxes and glyphs of one panel draw as instanced draws from those buffers: one per strip class and one per atlas page. Images draw one draw per distinct texture, because LÖVR has no bindless textures.
- Per-draw data such as the clip, the shape parameters, the paint index, colours, and radii lives in the instance data, so a change of clip does not split a batch.

Hit testing first rejects panels by their bounds, and then tests nodes from an index built at commit, so a ray sweeping past a panel does not test each of its nodes.

## Open questions

- Translucent overlapping panels. Two intersecting panels with translucent fills can show draw-order artefacts, because the toolkit does not sort across panels.
- Whether the panel body has visible thickness at its edges. Thickness improves the sense of a physical object and costs a few extra quads.
- SVG icons from icon themes, which launcher entries use. They need rasterisation into a texture, and the dependency is not chosen.
