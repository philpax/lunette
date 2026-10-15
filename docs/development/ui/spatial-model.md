# Spatial model

Every node has a place in the scene. Most nodes are boxes laid out on a flat or curved panel, and for them the place follows from layout and elevation alone. The same model also places nodes that are not on a sheet: labels over a window, a radial menu around a hand, a watch face wrapped around a forearm, a gizmo handle, or a model inside a panel. Authors of ordinary panels never use the parts of the model that serve those cases, and every default reproduces a flat or cylindrical sheet.

## Surface roots

A surface root is a node that opens a surface: a panel root, or a node that declares a surface shape. Every other node belongs to its nearest surface root, and its position is given in that surface's coordinates:

- `u` and `v`, in metres along the surface from its top-left corner, with `u` to the right and `v` downwards.
- `e`, the elevation in metres along the surface normal.

The surface root's shape maps `(u, v, e)` to the scene once, for the whole subtree. Nested nodes on a cylinder therefore stay concentric with the panel at every depth, because none of them maps through its parent's shape again.

On a cylinder of radius `r`, `u` is arc length at the surface, and a point at elevation `e` lies at angle `u / r` on a cylinder of radius `r - e`. A raised child therefore stays directly in front of the part of its parent it was laid out over.

## Composition

A node's surface coordinates compose through its ancestors up to the surface root. At each ancestor, in this order:

1. The ancestor's layout position, from layout.
2. The ancestor's scroll offset, if it scrolls.
3. The ancestor's layout transform: the host-owned offset and size of a running layout transition, and the transform that a custom layout placed the node with.
4. The ancestor's user transform.

Then the node's own layout position, layout transform, and user transform apply in the same order. Elevation accumulates through the same chain. Rotation and scale pivot about the centre of the node's layout box.

The two transform slots have one writer each. The host writes the layout transform, from layout transitions and from `ctx:place`. The node's kind writes the user transform, with `node:setTransform`, and a holder of the node's handle animates it through the `transform` channel only if the kind declares the transform as handle-writable. A drag ghost is a portal, not a transform, as [Input](input.md#drag-and-drop) describes.

The host composes these values on the CPU when any of them changes, and writes each affected node's composed values into the per-node buffer that the shader reads. A pan of a canvas with many descendants therefore rewrites those descendants' entries in that small buffer, but never their instance data.

## Conformance

A node's `conform` decides how it and its subtree meet a curved surface:

- `bend`, the default, bends the node's geometry onto the surface. A box 0.6 m wide on a cylinder curves with it. Transforms of bent nodes are similarities in surface coordinates: translation in `u`, `v`, and `e`, uniform scale in `u` and `v`, and rotation about the normal. Pan, zoom, slides, and radial labels need nothing more. A horizontal-only zoom, such as a timeline's, relayouts instead.
- `rigid` gives the node a flat frame of its own. The frame is the surface's frame at the node's anchor point, which is the centre of its composed layout box, followed by the node's transform, which can be any 3D transform. The anchor point already includes every ancestor's scroll and transforms, so a rigid node inside a scrolled or zoomed canvas moves with it. Ancestor scale scales rigid descendants. A rigid node and its descendants are flat inside its frame.

On a flat surface the two are the same. A node that opens a surface is rigid with respect to its parent, and its own subtree conforms to its own shape.

For a rigid node, elevation, hover lift, press travel, and press depth apply along its local z axis, so a tilted 3D button presses along its own axis.

A rigid node declares an extent, a local bounding box, which the hit index, panel bounds, and culling use. A rigid or anchored node can carry an orientation constraint: face the viewer, stay upright, or face its anchor. Labels over windows face the viewer, and icons on a curved dock stay upright.

## Node poses

A node's pose is the transform from its local space to the scene:

- For a bent node, the pose at a local point is the surface map of the point's composed surface coordinates. A bent node has a pose per point, and `node:pose()` reports the pose at the centre of its layout box.
- For a rigid node, the pose is a single matrix: the surface frame at its anchor, then its elevation, then its transform.

Elevation and touch distances stay in metres in the scene. A zoomed canvas scales its content's `u` and `v`, not the elevation of its descendants, so raised content keeps its depth at any zoom.

`node:pose()` is available to the node's kind, through the node handle, and through inspection.

## Surface shapes

A surface shape maps a surface to the scene. It provides:

- `map(u, v, e)`, which returns a position, a normal, and a tangent frame.
- `inverse(position)`, which returns `(u, v, e)`. The shader uses it to clip rigid content and meshes against a bent clip.
- `query(interactorShape, e)`, which returns the surface point, the signed distance along the normal, and the normal at the hit. The front of the surface is the side the normal points to.
- A tessellation function, which returns the number of segments along `u` and along `v` for a box of a given size at a given scale and elevation, so that the chord error stays within a tolerance.
- An optional silhouette for picking, such as a rounded rectangle or a polygon.
- Whether `u` is periodic, such as on a band wrapped around a forearm.

The standard shapes are a flat plane and a vertical cylinder whose centre is on the viewer's side, which is the model that window panels use in [`panels/service/private/shape.luau`](../../../lua/lunette-plugins/panels/service/private/shape.luau). The cylinder's curvature has a maximum, so that its tessellation stays bounded. Further shapes, such as a convex cylinder on a horizontal axis for a forearm, a sphere patch, or a polygon silhouette, are registered with `host:registerShape(context, registration)`. A registration provides the Lua implementation and GLSL snippets for the mapping and its inverse, and the host compiles the snippets into a variant of the toolkit shader. Each shape variant draws in its own instanced draws. The flat and concave cylinder shapes are implemented first.

Window and monitor surfaces publish their shape in metres too, through the interaction contract, so the toolkit can anchor to a point on a window and follow its curve.

## Placement

A container's `placement` decides how its children are placed:

| Placement | Children are placed by | Uses |
|---|---|---|
| `flow` | The layout engine on the container's surface. This is the default | Every ordinary panel |
| `scripted` | A Lua layout function that sizes the container from its children and positions them | Radial menus, shelves, docks, pies |
| `posed` | Their own transforms, relative to the container. A posed child is rigid | Gizmo handles, volumetric previews, free-floating labels |
| `attach` | An anchor to another node, a surface point, or a world pose source, with an alignment and an offset | Orbiters at a panel edge, labels over a window, badges on a world object |

Content sizing counts children placed by `flow` and `scripted`. Children placed by `posed` and `attach` are outside flow, and content sizing ignores them. An attached node with no size of its own takes its max-content size. [Layout and text](layout-and-text.md#scripted-layout) defines the scripted layout function.

Clipping and bounds are separate choices. A `posed` or `attach` subtree is a bounds root: the panel's bounds for hit-test rejection include it. Its clip is one of:

- `inherit`, the default for `posed`: it stays inside its container's clip, with an optional depth range of its own, so a volumetric preview in a scrolling page is cut off when it scrolls out of view but can protrude a declared distance in front of the page;
- `none`, the default for `attach`: it is not clipped, so a label attached over a window a metre away from its panel is drawn where it is;
- a clip of its own.

## Anchors

An anchor is a pose source with an alignment and an offset. The source is one of:

- a node;
- a point `(surface, u, v)` on a surface, which follows the surface's shape;
- a panel or a window surface;
- a tracked device;
- a world pose.

An attached subtree is rigid at the anchor's frame, unless it declares `conform = 'target'`, in which case it bends onto the shape of the surface it is anchored to.

Anchored poses are recomputed every frame before picking, as [Architecture](architecture.md#data-flow) describes, so a node attached to a hand or to a moving window follows it. A node reads an anchor through an anchor store that updates when the source moves. Presentations use anchors to place panels, as [Presentations](presentations.md#pose-policies) describes. Anchoring is a public mechanism: any plugin can anchor a node to any pose source it can read.

## Hit volumes

A node's hit volume is its layout box on its surface, extruded along the normal by its thickness, and extended by its hit slop as [Theming](theming.md#target-sizes) defines it. Thickness is a prop with a token default: the elevation step of the node's level for raised controls, and zero for flat content. Hit testing uses the node's drawn elevation, including hover lift, so a ray hits the face that is drawn.

A kind can replace the default with a `hit` function that returns a hit record or `nil`. Its input depends on the node's conformance:

- A bent node receives the query's intersection with its surface at its elevation: the point in its local `u` and `v`, the signed distance, and the normal. A ray on a cylinder is a curve in local coordinates, so the host intersects it first.
- A rigid node receives the query in its local frame: a ray, a point, or a sphere.

Items inside a node have shapes from a closed set: a rectangle, a rounded rectangle, a set of rectangles, a polyline with a width, a sector, a polygon, or a custom hit function. A set of rectangles is what a link that wraps across lines needs, and a polyline with a width is what a graph edge needs, because the bounding boxes of crossing edges overlap. Item hit widths are clamped to a physical minimum after transforms, so a zoomed-out edge stays targetable. An item can declare the nodes its shape depends on, and the host re-evaluates it when their poses change.

Interactor shapes are an open set. Rays, points, and grab spheres are implemented first. A capsule for a fingertip with a radius is a further member. The host answers every shape for toolkit nodes, so a plugin that adds an interactor shape adds its query to the host's shape set, and window surfaces answer rays only.

A query returns a hit record:

- the node id, and the item id when the node publishes items;
- the point in the node's local space;
- the normal at the hit;
- the distance along a ray, or the signed distance from a point to the surface.

A ray therefore hits the side of a raised control, and a point touches the outside of a convex surface. When two hits on one panel are at the same distance, the node with the higher stacking order wins, which matches what is drawn on top, as [Rendering](rendering.md#draw-order) describes.

The host keeps a hit index per panel. Commit rebuilds it for changed nodes, and a change of composed transform, scroll offset, or anchored pose updates the affected entries, so a panned canvas, a scrolled list, or a sliding toast is hit where it is drawn. While a layout transition runs, the node is hit at its drawn rectangle, and at its final rectangle only where no drawn rectangle is hit.

## Clip volumes

A clip is a rounded rectangle in its clipping ancestor's coordinates, extended along the normal by a depth range. A clipping node declares its depth range. The default depth range of a scroll box covers the `raised` elevation plus hover lift and the content offset, so a hovered button in a list keeps its face and its label. The panel's default depth range extends to the `dialog` elevation. Content inside a clip draws and hits only inside the volume. A volume rather than a rectangle allows a recessed well, a model that protrudes a declared distance from a panel, and raised controls inside a scroll box, each with a defined limit.

## Directional focus traversal

Directional traversal moves focus to the nearest focusable node in a direction. Candidates that share the focused node's surface root are compared in `(u, v)` coordinates, using a rigid node's anchor point and an item's centroid, and wrapping across a periodic `u`. A watch face therefore has a defined left and right everywhere. Candidates on other surface roots are compared by projecting their centres onto the plane facing the viewer.

## Implementation order

The surface root and `(u, v, e)` coordinates, the composition order, conformance, the two transform slots, the surface shape interface and its registration, the hit record and item shapes, bounds roots and clip inheritance, anchors, and the placement field are in the contracts from the start, because changing any of them later would change every kind, every surface, and every interaction test. The flat and concave cylinder shapes, the `flow` and `scripted` placements, ray, point, and grab-sphere interactors, and the batched drawing path are implemented first. The `posed` and `attach` placements, further shapes, further interactor shapes, and mesh drawing are implementations of those contracts.
