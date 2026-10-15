# Spatial model

Every node has a pose in the scene. Most nodes are boxes laid out on a flat or curved panel, and for them the pose follows from layout and elevation alone. The same model also places nodes that are not on a sheet: labels over a window, a radial menu around a hand, a watch face wrapped around a forearm, a gizmo handle, or a model inside a panel. Authors of ordinary panels never use the parts of the model that serve those cases, and every default reproduces a flat or cylindrical sheet.

## Node poses

A node's local space has its origin at the top-left corner of its layout box, with x to the right, y downwards, and z towards the viewer, in metres. Its pose is the transform from local space to world space:

```
pose(node) = pose(parent) * shape(parent).map(layoutRect) * elevation(node) * transform(node)
```

- `pose(parent)` is the parent's pose, or the panel's pose for a root.
- `shape(parent).map(layoutRect)` places the node's layout box on the parent's surface shape. A node in a flat parent is translated; a node on a cylinder is translated along the arc and rotated to face the axis.
- `elevation(node)` offsets the node along the surface normal at its position, as [Rendering](rendering.md#depth) describes.
- `transform(node)` is the node's own transform, which is identity unless the node sets one.

A node's transform is node state. It applies after layout, as a CSS transform does: the node keeps its layout slot, its siblings do not move, and content sizing ignores it. Its children inherit it. The transform animates without a render, so panning and zooming a canvas, sliding a toast, following a drag ghost, and rotating a radial label change no layout and reshape no text. Hit testing applies the inverse transform, and inspection reports the resulting pose.

`node:pose()` returns a node's world pose. It is available to the node's kind, through the node handle that `ui.useRef` returns, and through inspection.

## Surface shapes

A surface shape maps a point on a surface to the scene. It provides:

- `map(u, v, elevation)`, which returns a position, a normal, and a tangent.
- `query(interactorShape)`, the inverse, which returns the surface-local point, the signed distance along the normal, and the normal at the hit.
- A tessellation hint, which tells the renderer how finely to subdivide a box of a given width.
- An optional silhouette for picking, such as a rounded rectangle or a polygon.

A panel has a shape, and so does every node that opens a new surface. The standard shapes are a flat plane and a vertical cylinder whose centre is on the viewer's side, which is the model that window panels use in [`panels/service/private/shape.luau`](../../../lua/lunette-plugins/panels/service/private/shape.luau). Elevation follows the shape's normal: on the concave cylinder it reduces the radius, and on a convex shape it increases it.

Further shapes, such as a convex cylinder on a horizontal axis for a forearm, a sphere patch, or a polygon silhouette, are implementations of the same interface. The toolkit shader evaluates a small fixed set of shapes selected by a shape id and parameters in the instance data, so a new shape needs a shader variant as well as a Lua implementation. The flat and concave cylinder shapes are implemented first.

## Placement

A container's `placement` decides how its children are placed:

| Placement | Children are placed by | Uses |
|---|---|---|
| `layout` | The layout engine on the container's surface. This is the default | Every ordinary panel |
| `posed` | Their own transforms, relative to the container's pose. A posed child can open a new surface with its own shape | Gizmo handles, volumetric previews, free-floating labels |
| `custom` | A Lua arrange function that measures the children and returns their positions or transforms | Radial menus, force-directed graphs, shelves |
| `attach` | An anchor to another node's pose or to a world pose source, with an alignment and an offset | Orbiters at a panel edge, labels over a window, badges on a world object |

Content sizing counts children placed by `layout` and `custom`. Children placed by `posed` and `attach` are outside flow, and content sizing ignores them. [Layout and text](layout-and-text.md#layout-callbacks) defines the arrange function.

## Anchors

An anchor is a pose source: a node, a panel, a window surface, a tracked device, or a world point, together with an alignment and an offset. A node reads an anchor through `node:pose()` on the anchor's node, or through an anchor store that updates when the source moves. Presentations use anchors to place panels, as [Presentations](presentations.md#pose-policies) describes, and attached nodes use them to place themselves. Anchoring is a public mechanism: any plugin can anchor a node to any pose source it can read.

## Hit volumes

A node's hit volume is its layout box on its parent's surface, extruded along the normal by the node's thickness, including its hit slop as [Theming](theming.md#target-sizes) defines it. A kind can replace the default with a `hit` function that receives a query in the node's local space and returns whether the query hits the node, or which of the node's items it hits. [Extension](extension.md#element-kinds) defines items.

Interactor shapes are an open set. Rays and points are implemented first. A capsule for a fingertip with a radius, or a sphere for a grab volume, is a new member of the set, and every surface answers it through the same query. A query returns a hit record:

- the node id, and the item id when the node publishes items;
- the point in the node's local space;
- the normal at the hit;
- the distance along a ray, or the signed distance from a point to the surface.

A ray therefore hits the side of a raised control, and a point touches the outside of a convex surface. When two hits on one panel lie within the minimum elevation separation of each other, the node later in paint order wins, which matches what is drawn on top, as [Rendering](rendering.md#paint-order) describes.

## Clip volumes

A clip is a rounded rectangle in its clipping ancestor's local space, extended along the normal by a depth range. Content inside a clip draws and hits only inside the volume. A volume rather than a rectangle allows a recessed well, a model that protrudes a fixed distance from a panel, and raised controls inside a scroll box, each with a defined limit.

## Directional focus traversal

Directional traversal moves focus to the nearest focusable node in a direction. Geometry is compared after projecting each node's centre onto the tangent plane of the focus scope's surface at the focused node. For a scope whose children are placed by `posed`, the projection is onto the plane facing the viewer. A wrapped surface, such as a watch face, therefore has a defined left and right at every point.

## Implementation order

The node pose, the transform slot, the surface shape interface, the hit record, and the placement field are in the contracts from the start, because changing them later would change every kind, every surface, and every interaction test. The flat and concave cylinder shapes, the `layout` placement, ray and point interactors, and the batched drawing path are implemented first. The `posed`, `custom`, and `attach` placements, further shapes, further interactor shapes, and mesh drawing are additions to that model and need no contract change.
