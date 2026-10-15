# Spatial model

Every node has a place in the scene. Most nodes are boxes laid out on a flat or curved panel, and for them the place follows from layout and elevation alone. The same model also places nodes that are not on a sheet: labels over a window, a radial menu around a hand, a watch face wrapped around a forearm, a gizmo handle, or a model inside a panel. Authors of ordinary panels never use the parts of the model that serve those cases, and every default reproduces a flat or cylindrical sheet.

## Surface roots

A surface root is a node that opens a surface: a panel root, or a node that declares a surface shape. Every other node belongs to its nearest surface root, and its position is given in that surface's coordinates:

- `u` and `v`, in metres along the surface from its top-left corner, with `u` to the right and `v` downwards. Layout produces them, and they accumulate through every ancestor up to the surface root.
- `e`, the elevation in metres along the surface normal, which accumulates through ancestors in the same way.

The surface root's shape maps `(u, v, e)` to the scene once, for the whole subtree. Nested nodes on a cylinder therefore stay concentric with the panel at every depth, because none of them maps through its parent's shape again.

On a cylinder of radius `r`, `u` is arc length at the surface, and a point at elevation `e` lies at angle `u / r` on a cylinder of radius `r - e`. A raised child therefore stays directly in front of the part of its parent it was laid out over.

## Conformance

A node's `conform` decides how it and its subtree meet a curved surface:

- `bend`, the default, bends the node's geometry onto the surface. A box 0.6 m wide on a cylinder curves with it. The node's own transform applies in surface coordinates before the mapping, and it is limited to translation in `u`, `v`, and `e`, uniform scale in `u` and `v`, and rotation about the normal. Pan, zoom, slides, drag ghosts, and radial labels need nothing more.
- `rigid` gives the node a flat frame of its own. The frame is the surface's frame at the node's anchor point, which is the centre of its layout box, followed by the node's transform, which can be any 3D transform. The node and its descendants are flat inside that frame. Gizmo handles, meshes, 3D buttons, and volumetric previews are rigid.

On a flat surface the two are the same. A node that opens a surface is rigid with respect to its parent, and its own subtree conforms to its own shape.

## Node poses

A node's pose is the transform from its local space to the scene:

- For a bent node, the pose at a local point `(x, y, z)` is the surface map of `(u + x', v + y', e + z')`, where `(x', y', z')` is the point after the node's transform. A bent node has a pose per point, and `node:pose()` reports the pose at the centre of its layout box.
- For a rigid node, the pose is a single matrix: `surfaceFrame(anchor) * elevation * transform`.

Children of a rigid node that does not open a surface lay out in its flat frame.

A node's transform is node state. It applies after layout, as a CSS transform does: the node keeps its layout slot, its siblings do not move, and content sizing ignores it. Its descendants inherit it. A kind sets it with `node:setTransform(transform)`, and any holder of a node handle animates it through the `transform` channel, as [Motion and feedback](motion-and-feedback.md#animation-channels) describes. Hit testing and inspection follow it.

Elevation and touch distances stay in metres in the scene. A zoomed canvas scales its content's `u` and `v`, not the elevation of its descendants, so raised content keeps its depth at any zoom.

`node:pose()` is available to the node's kind, through the node handle, and through inspection.

## Surface shapes

A surface shape maps a surface to the scene. It provides:

- `map(u, v, e)`, which returns a position, a normal, and a tangent frame.
- `query(interactorShape, e)`, the inverse, which returns the surface point, the signed distance along the normal, and the normal at the hit. The front of the surface is the side the normal points to.
- A tessellation hint in two dimensions, the number of segments along `u` and along `v` for a box of a given size.
- An optional silhouette for picking, such as a rounded rectangle or a polygon.

The standard shapes are a flat plane and a vertical cylinder whose centre is on the viewer's side, which is the model that window panels use in [`panels/service/private/shape.luau`](../../../lua/lunette-plugins/panels/service/private/shape.luau). Further shapes, such as a convex cylinder on a horizontal axis for a forearm, a sphere patch, or a polygon silhouette, are registered with `host:registerShape(context, registration)`. A registration provides the Lua implementation and a GLSL snippet for the mapping, and the host compiles the snippet into a variant of the toolkit shader. The flat and concave cylinder shapes are implemented first.

## Placement

A container's `placement` decides how its children are placed:

| Placement | Children are placed by | Uses |
|---|---|---|
| `layout` | The layout engine on the container's surface. This is the default | Every ordinary panel |
| `custom` | A Lua layout function that sizes the container from its children and positions them | Radial menus, shelves, docks, pies |
| `posed` | Their own transforms, relative to the container. A posed child is rigid | Gizmo handles, volumetric previews, free-floating labels |
| `attach` | An anchor to another node, a surface point, or a world pose source, with an alignment and an offset | Orbiters at a panel edge, labels over a window, badges on a world object |

Content sizing counts children placed by `layout` and `custom`. Children placed by `posed` and `attach` are outside flow, and content sizing ignores them. An attached node with no size of its own takes its max-content size. [Layout and text](layout-and-text.md#custom-layout) defines the custom layout function.

A `posed` or `attach` subtree is a bounds root. It is not clipped by its container's clip, it declares its own clip or none, and the panel's bounds for hit-test rejection include it. A label attached over a window a metre away from its panel is therefore drawn and hit-tested where it is.

## Anchors

An anchor is a pose source with an alignment and an offset. The source is one of:

- a node;
- a point `(surface, u, v)` on a surface, which follows the surface's shape, so a label at a point on a curved window stays on the curve;
- a panel or a window surface;
- a tracked device;
- a world pose.

Anchored poses are recomputed every frame before picking, as [Architecture](architecture.md#data-flow) describes, so a node attached to a hand or to a moving window follows it. A node reads an anchor through an anchor store that updates when the source moves. Presentations use anchors to place panels, as [Presentations](presentations.md#pose-policies) describes. Anchoring is a public mechanism: any plugin can anchor a node to any pose source it can read.

An anchored node can keep an orientation constraint: face the viewer, stay upright, or face its anchor. Labels over windows face the viewer, and icons on a curved dock stay upright.

## Hit volumes

A node's hit volume is its layout box on its surface, extruded along the normal by its thickness, and extended by its hit slop as [Theming](theming.md#target-sizes) defines it. Thickness is a prop with a token default: the elevation step of the node's level for raised controls, and zero for flat content.

A kind can replace the default with a `hit` function that receives a query in the node's local space and returns a hit record or `nil`. Items inside a node have shapes from a closed set: a rectangle, a rounded rectangle, a polyline with a width, a sector, a polygon, or a custom hit function. A polyline with a width is what a graph edge needs, because the bounding boxes of crossing edges overlap.

Interactor shapes are an open set. Rays, points, and grab spheres are implemented first. A capsule for a fingertip with a radius is a further member. The host answers every shape for toolkit nodes, so a plugin that adds an interactor shape adds its query to the host's shape set, and window surfaces answer rays only.

A query returns a hit record:

- the node id, and the item id when the node publishes items;
- the point in the node's local space;
- the normal at the hit;
- the distance along a ray, or the signed distance from a point to the surface.

A ray therefore hits the side of a raised control, and a point touches the outside of a convex surface. When two hits on one panel are at the same distance, the node later in tree order wins, which matches drawing order.

The host keeps a hit index per panel. Commit rebuilds it for changed nodes, and a change of transform or anchored pose updates the node's entry, so a panned canvas or a sliding toast is hit where it is drawn.

## Clip volumes

A clip is a rounded rectangle in its clipping ancestor's coordinates, extended along the normal by a depth range. A clipping node declares its depth range, and the panel's default depth range extends to the `dialog` elevation. Content inside a clip draws and hits only inside the volume. A volume rather than a rectangle allows a recessed well, a model that protrudes a declared distance from a panel, and raised controls inside a scroll box, each with a defined limit.

## Directional focus traversal

Directional traversal moves focus to the nearest focusable node in a direction. When the candidates share the focused node's surface root, they are compared in `(u, v)` coordinates, so a wrapped surface such as a watch face has a defined left and right everywhere. Across surface roots, and among rigid nodes, node centres are projected onto the plane facing the viewer.

## Implementation order

The surface root and `(u, v, e)` coordinates, conformance, the transform and its writer, the surface shape interface and its registration, the hit record and item shapes, bounds roots, anchors, and the placement field are in the contracts from the start, because changing any of them later would change every kind, every surface, and every interaction test. The flat and concave cylinder shapes, the `layout` and `custom` placements, ray, point, and grab-sphere interactors, and the batched drawing path are implemented first. The `posed` and `attach` placements, further shapes, further interactor shapes, and mesh drawing are implementations of those contracts.
