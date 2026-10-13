# Rounded geometry

The theme plugin builds the shared rounded perimeters used by scene-rendered panels, UI faces, and keyboard faces. Panels, controls, and text therefore use consistent visible edges and hit geometry.

## Perimeter construction

Each corner has independent horizontal and vertical radii. A zero radius produces a square corner. The emitted perimeter uses straight chords between arc vertices, and drawing and initial picking use that same perimeter.

Panel textures clip to the perimeter while retaining UVs from the original panel coordinates, so clipping does not stretch the remaining image. Curved panels split the clipped polygon at cylinder boundaries before mapping it onto the curve.

## Content clips

`safeClip` returns a conservative rectangle inside the rounded perimeter. The UI uses it to keep text and hooks inside the silhouette; control hit targets remain rectangular so small controls retain usable area. [UI rendering](../../ui/docs/rendering.md#content-clips) defines that policy.

## Decisions

Clipped meshes remove corner pixels, hit area, and depth-writing geometry together. The UI uses a conservative rectangle for content rather than stencil or offscreen clipping, which would add pass requirements and composition cost. The trade-off is less content room near rounded corners.
