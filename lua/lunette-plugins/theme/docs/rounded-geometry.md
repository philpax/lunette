# Rounded geometry

The theme plugin's `rounded-geometry.luau` builds convex rounded-rectangle perimeters for scene-rendered panels, UI faces, and keyboard faces. It also builds clipped polygons and outline rings. Drawing and initial picking use the same emitted perimeter.

## Perimeter construction

A profile has independent horizontal and vertical radii for each corner. Each radius is clamped to half the corresponding panel extent. A zero radius produces a square corner. Each nonzero quarter arc has eight segments. The perimeter consists of the arc vertices and the chords between them; a point between a chord and its circle is outside for both drawing and initial picking.

Rounded panel textures use meshes clipped to the perimeter. Their UV coordinates come from unclipped panel-local coordinates, so clipping removes corner pixels without stretching the remaining image. Monitor rotation and flip apply after that mapping. Curved content splits the clipped polygon at cylinder strip boundaries, then maps each vertex onto the cylinder. Picking maps back through the same perimeter.

Outline geometry is a ring between outer and inner perimeters. The ring uses matching perimeter vertices to form strips. A rounded corner has no content and no depth-writing geometry, so farther scene surfaces remain visible and pickable through it.

## Conservative clip geometry

`safeClip` returns a rectangle inside the rounded perimeter's chords. The emitted arcs include their 45-degree vertices. The inset factor is `1 - sqrt(0.5)`, applied to the largest relevant horizontal and vertical corner radii on each side. The UI provider uses this rectangle to keep text inside the rounded silhouette. Rectangular hit targets preserve usable area on small keys. [UI rendering](../../ui/docs/rendering.md#content-clips) specifies the UI clip policy and its costs.

## Mesh ownership

Mesh keys include bounds, the clamped corner profile, optional clip bounds, and ring thickness. Panel and UI callers retain meshes while these inputs stay unchanged. The owning panel or provider activation releases replaced meshes and releases retained meshes during owner cleanup or provider shutdown. Requiring a module creates no mesh.

A radius change does not acquire or release a composition-layer claim. A granted layer keeps rectangular content and hits on both backends. An ungranted window claim uses the rounded scene profile. Base, Dark, and Light use a zero monitor radius; Arcade uses 0.012 m.

## Decisions

Clipped meshes remove corner pixels, hit area, and depth together. Rectangular content clips let text and hooks stay inside the silhouette without stencil or offscreen passes. Stencil and offscreen passes were rejected because of their pass requirements and composition cost. The cost is less content room near corners. Controls keep rectangular hit targets because chord-clipped targets would remove usable area from small keys; the panel perimeter still excludes the outer cutouts.

## Known gaps

Geometry recorders do not rasterise edges, alpha, depth, or fonts. The shared [rendering specification](../../../../docs/dev/rendering.md#known-gaps) records which GPU checks exist and which rasterization, stereo, and headset properties still require manual checks.
