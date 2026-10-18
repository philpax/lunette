# Rendering

## Drawing in the scene

Panels draw geometry into the scene every frame. Raised faces, press travel, text, and rays retain stereo separation and depth testing. Rendering a whole panel to a cached texture would reduce idle cost, but flatten its elements. A texture per elevation would still lose per-element and animated depth. The toolkit therefore does not use offscreen panel textures as its renderer.

lunette is an overlay session and cannot depth-test against the application or passthrough beneath it. Its own fingertip proxy gives contact feedback when a real hand is hidden behind a panel. [Motion and feedback](motion-and-feedback.md#fingertip-proxy) records that limitation.

## Composition layers

Toolkit panels do not claim OpenXR composition layers. Layers can improve text resampling, but require flat images and do not share scene depth with rays and fingertip proxies. They also share the runtime's layer budget with window panels. The [panel renderer](../../../lua/lunette-plugins/panels/service/README.md) owns window-layer policy.

## The toolkit shader

The host's shaders draw recorded primitives with panel coordinates, elevation, clipping, and cylindrical mapping. Boxes include fill, edge, and side treatment; text samples the glyph atlas. Shader source is private to the renderer. There is no public shader include or material interface that gives arbitrary custom meshes the toolkit's mapping and clipping.

### Shapes

Flat and curved panels use different fixed mesh templates. Curved boxes use a fixed grid rather than a subdivision selected from size, scale, or chord-error tolerance. Text and images do not share adaptive box subdivisions. The renderer does not guarantee that every content vertex or hit lies on exactly the same tessellated chord.

### Clipping

Recorded primitives use the clipping bounds prepared by the host. Input also rejects targets outside clipping ancestors. Clip data is packed with drawing data; there is no native per-node clip buffer that an animation updates independently of descendants.

Custom volumes have a different boundary. The host hides a volume while any of its base lies outside an ancestor clip, but does not clip the volume's geometry. Its callback must keep drawing inside the declared width, height, and depth. A volume must not assume fragment clipping or a rounded depth-volume clip.

### Drawing API

The [host contract](../../../lua/lunette-contracts/ui-host.luau) owns the drawing primitives and image-source types. Ordinary visuals record primitives instead of changing a LÖVR pass. A volume records a draw callback that receives a pass placed at the volume's base every frame. On a curved panel the base is tangent at its centre; the volume does not bend.

The host restores pass state and transform after a volume callback, including when it raises. The callback balances its own pushes and applies the supplied opacity and scrim to its own content. A failing callback is reported and remains disabled until the node's visual is recorded again. The volume slot is an escape for three-dimensional content, not a public replacement renderer.

Image texture lifetimes remain the caller's responsibility. A window's texture rotates with client buffers, so a consumer that needs a persistent texture uses `window:stabilize()` rather than caching `window:getTexture()`. The host does not provide an asynchronous shared thumbnail atlas or a store-valued image source.

Native SVG rasterisation preserves aspect ratio and returns straight-alpha pixels. It does not follow external file references or shape text elements, so SVG text is not an alternative to toolkit text. The generated native declarations own the rasteriser's signature.

### Bound parameters

Animation channels and interaction response can change drawing without re-rendering a component. The host reads those values when preparing drawing data. It does not expose shader bindings to arbitrary nearby interactors or an independent native animation buffer. A visual that needs a new primitive description is recorded again rather than installing a shader expression.

## Depth

Elevation is measured towards the viewer. The host adds small depth separations for nesting and primitive order so a node's label does not share its face's depth. Hover lift and press travel use the same geometry path. The theme owns the sizes; [Theming](theming.md#elevation) records the reason for avoiding coplanar faces.

## Draw order

The renderer submits boxes, custom volumes, images, and glyphs in one sequence per panel. Boxes use bounded instanced batches, and glyphs group by atlas page. Depth determines visibility between raised content. This is not a global sort of opaque and translucent scene content, and it has no public stacking-context mechanism.

Overlays are separate panels at their own poses. Content that depends on exact ordering across intersecting translucent panels needs separate verification; the renderer does not sort all panels by depth.

## Opacity

Opacity is applied to packed primitives in the ordinary draw sequence. There is no depth-only prepass and equal-depth colour pass for group fades. Overlapping parts can therefore remain visible through one another while faded. A custom volume applies the opacity supplied to its callback itself.

## Curvature

Panel curvature uses a vertical cylindrical map, with width measured along the arc. Drawing, panel-coordinate conversion, and inspection use that model. Fixed mesh subdivision limits the geometric approximation. [Spatial model](spatial-model.md#surface-roots) states the coordinate contract.

An overlay on a curved opener remains flat and tangent to the opener's curve at the overlay's centre. It is not a concentric curved panel. An attached panel is placed relative to its target and does not imply inherited curved geometry.

## Draw cost

Visual recording caches primitive descriptions until they become dirty. Luau packs those primitives for drawing and sends bounded batches to LÖVR. There is no native per-node instance allocator, persistent per-node draw-buffer slot contract, or separate animation buffer. An unchanged component tree can still require draw preparation and uploads each frame.

Rendering cost therefore needs measurement against representative dense panels and text. A retained authoring model avoids unnecessary component renders; it does not guarantee zero CPU or upload cost for an idle panel.

## Open questions

- Ordering of translucent content across intersecting panels and within group fades.
- Adaptive subdivision and agreement between tessellated drawing and hit geometry.
- Whether the panel body needs visible thickness at its edges.
- Whether custom content needs a public clipping or material mechanism beyond the volume contract.
