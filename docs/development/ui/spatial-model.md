# Spatial model

The host places retained nodes on flat or cylindrical panels. Layout determines their two-dimensional boxes, and elevation separates faces in the scene. Three-dimensional content uses a custom volume above a node's box. The [host contract](../../../lua/lunette-contracts/ui-host.luau) owns the supported geometry; general surface roots, placement registries, and arbitrary node transforms are not public host mechanisms.

## Surface roots

A panel is the coordinate root. Coordinates run in metres from its top-left corner, x right and y down, with elevation towards the viewer. Drawing, input, and inspection share that convention. Curvature maps panel width along a vertical cylindrical arc.

A panel's curve does not create independently registered surface roots inside its descendants. An overlay is another panel, and a custom volume has a tangent base rather than a new bent child surface.

## Composition

The host combines layout positions with ancestor scroll offsets and accumulated elevation. Hover lift, press travel, and small nesting separations affect the drawn face. Input and node poses use the resulting panel geometry.

There is no public pair of user and layout transform slots, general `setTransform` request, or native per-node transform buffer. A consumer that needs world motion poses its panel or draws its own content within a volume contract. Layout changes and animation do not establish the proposed transform-composition protocol.

## Conformance

Ordinary toolkit primitives follow the panel's curved rendering path. The host does not expose a per-node `bend` or `rigid` conformance choice. A custom volume remains rigid, with its base tangent to the curve at its centre. It stays within its declared bounds and applies its own drawing transforms.

## Node poses

A node handle reports its centre's world pose and its layout bounds in node or panel coordinates. Inspection exposes the same geometry for discovery and input tests. A pose at the centre does not represent the whole curved node as one flat matrix; callers must not apply a flat-panel formula to arbitrary points on a curved panel.

## Surface shapes

The host supports flat panels and a vertical cylindrical curve. It has no public `registerShape` API, GLSL-snippet registration, periodic surface coordinates, or shape-dependent adaptive tessellation. Window and monitor surfaces use their own panel implementation through the shared surface contract.

The renderer uses fixed subdivision for curved boxes. Drawing and hit conversion follow the same cylinder model, but the host does not guarantee exact agreement with each rendered mesh chord. [Rendering](rendering.md#curvature) states that approximation boundary.

## Placement

Children use native container layout. Fixed or absolute positions use supported layout styles rather than a separate `posed` mode. Scripted layout exists in the native tree but is not a host kind placement mode, as [Layout and text](layout-and-text.md#scripted-layout) describes.

A host panel can attach above another surface. This panel-level attachment does not provide arbitrary anchored subtrees, independent bounds roots, or `inherit`, `none`, and custom clip-policy choices on posed nodes.

## Anchors

Portals anchor overlays to opener nodes, and attached panels follow a target surface. Those are specific host behaviors rather than a general anchor-store API for nodes, tracked devices, surface points, and world pose sources.

On a curved opener, an overlay stays flat and tangent at its centre. Attached chrome follows the target's pose and width without implying a concentric copy of its shape. [Presentations](presentations.md#positioning) records the placement and lifetime rules.

## Hit volumes

The host tests node boxes and clipping ancestors. Raised targets win before lower targets, then later siblings break ties. It does not publish a per-kind arbitrary hit function or a registry of rectangle, polyline, sector, and polygon items within one node.

Rays use the shared surfaces protocol, and fingertip points use the host's touch path. Grab spheres and general manipulation are deferred in [#69](https://github.com/philpax/lunette/issues/69). Proximity queries that select nearby nodes a ray missed are deferred in [#70](https://github.com/philpax/lunette/issues/70).

## Clip volumes

Ordinary drawing and input stay inside ancestor clipping bounds. The current host does not expose rounded clips with an arbitrary elevation range as a general three-dimensional clip volume.

A volume is hidden while any of its base lies outside an ancestor clip. The host does not clip its geometry. The callback must keep content within the declared base and depth. This coarse rule avoids partially visible custom content without requiring an unsupported shader interface.

## Directional focus traversal

Directional traversal uses retained layout geometry to find focusable nodes. Traversal can scroll the destination into view. There is no periodic-surface wrap or viewer-plane projection across arbitrary surface roots because those roots are not part of the host contract.

## Implementation order

The public boundary covers the implemented flat and cylindrical panel model. Further surface shapes, arbitrary transforms, scripted host layouts, and custom hit items require explicit contract work rather than an assumption that design vocabulary already reserves those capabilities. Deferred input and arrangement requirements are tracked in [#69](https://github.com/philpax/lunette/issues/69), [#70](https://github.com/philpax/lunette/issues/70), and [#71](https://github.com/philpax/lunette/issues/71).
