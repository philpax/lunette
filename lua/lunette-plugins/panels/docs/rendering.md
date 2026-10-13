# Panel rendering

The panels provider chooses geometry and draw order for window buffers, child surfaces, and chrome. The compositor supplies textures and child placement. Shared scene and composition-layer guarantees are in [Rendering](../../../../docs/dev/rendering.md).

## Window child surfaces

A window texture contains only its own surface. The provider draws child surfaces below the window first, then the window, then children above it. This preserves popup stacking and lets content show through transparent parts of the window.

The provider separates child meshes by 0.2 mm per layer to avoid z-fighting. It clips each child to the panel silhouette, including rounded corners, and clips its sampled crop to match. The compositor routes pointer input through the surface tree, but picking covers only the window panel's own area.

A composition layer covers scene-rendered children. A panel that shows any child releases its layer claim and draws in the scene; it claims a layer again when no children remain. A custom source renderer remains responsible for its own child surfaces.

## Joined flat frames

A titlebar joins a target only while the target is live, visible, flat, and rendered in the scene. A granted layer does not join, and changing the corner radius does not change layer eligibility.

The header rounds its top outer corners and the body rounds its bottom outer corners. Their inner edges meet without a seam. The target draws one outline around both, even when native chrome is disabled; the header's border style controls that outline. The titlebar keeps its own face, text, and actions, with action drawing and hit targets clipped to the header.

Curved bodies and granted layers keep a separate flat titlebar. The [`attachFrame` contract](../../../../docs/dev/lua-api.md#joined-frame-attachments) defines attachment eligibility and lifecycle.

## Decisions

Lua draws child surfaces instead of compositing each surface tree into a window texture. A composite would add a render pass and duplicate native alpha and colour conversion, while making children visible to every texture consumer. Lua drawing keeps placement and clipping in the panel renderer; custom renderers must draw their own children.

The target owns joined-frame eligibility and the single outline because it owns the body geometry and layer state. Granted layers remain rectangular rather than forcing scene fallback when the radius changes, which would reduce text legibility and churn layer claims.

## Known gaps

A popup that extends beyond its window is clipped and cannot be pointed at outside the panel. A window that always shows a subsurface never holds a layer, and `window:stabilize()` copies only its own surface. Window buffer transforms are not applied, so transformed content and crops can be wrong.

A composition layer is single-sided, so a panel with a granted layer cannot be seen from behind. The same panel remains visible from behind when rendered in the scene.
