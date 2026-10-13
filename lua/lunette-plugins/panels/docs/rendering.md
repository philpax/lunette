# Panel rendering

The panels provider draws a window's buffer, popups, subsurfaces, and optional chrome in scene space. The native layer supplies window textures and child placement; the panels provider chooses their geometry and draw order. Shared import, scene-depth, and composition-layer guarantees remain in [Rendering](../../../../docs/dev/rendering.md). Surface and pointer contracts remain in [the Lua API](../../../../docs/dev/lua-api.md#panels).

## Window child surfaces

A window texture contains only the window's own surface buffer. The compositor reports popup and subsurface textures and their positions relative to the window. The panels provider draws children below the window first, then the window, then children above it. A menu therefore covers the window, and a video subsurface beneath a transparent region shows through it.

Each child is drawn 0.2 mm further toward the viewer than the previous layer. Coplanar meshes z-fight. A child below the window is drawn 0.2 mm behind the window per layer. This separation is panel rendering policy; the native compositor continues to route pointer input within the surface tree.

Each child mesh is clipped to the panel silhouette, including rounded corners, and samples only the part of its crop that remains. Picking reaches only the window's own panel area. The clip therefore keeps the visible child area aligned with the area to which the compositor can route a pointer. The child mesh follows the panel curve. It remains cached while the child's placement, crop, and panel shape stay unchanged.

A composition layer composites over the scene and would cover children drawn in the scene. A window panel that shows any child releases its layer claim and draws in the scene. It claims a layer again after no children remain. A custom source renderer remains responsible for drawing its own child surfaces.

## Joined flat frames

A shared titlebar joins a target only while the target is live, visible, flat, and rendered in the scene. A target with a granted layer does not join. This is a rendering policy over the target's actual geometry and claim state; a radius change does not acquire or release a claim.

For a joined target, the header rounds only its top outer corners, and the body rounds only its bottom outer corners. The inner edges are square and meet with no margin. The header's inner width equals the body's. Header radii clamp to the header height. Hiding or removing the heading restores the body's own profile.

The target draws one outline around the header and body, including when native `chrome = false`. The header's border thickness, depth, and normal or highlighted colour govern the whole outline. For body width W, body height H, and header height h, the inner envelope is W by H+h, centred at y = h/2 in target-local metres. The outer envelope grows by the border thickness. No outline runs along the seam, and the cutouts write no depth.

The titlebar still draws its face, text, and actions. Action faces clip to the header perimeter, and action and drag hits are gated by it, so a cutout is not a hidden grab target. A curved body keeps a separate flat titlebar, as does a granted layer. The [`attachFrame` contract](../../../../docs/dev/lua-api.md#joined-frame-attachments) defines the shared attachment lifecycle and eligibility.

## Decisions

The panels provider draws child surfaces in Lua rather than compositing each surface tree into one texture per window on the frame thread. WayVR uses that compositing approach for its overlay. It would replace zero-copy import with a render pass into a lunette-owned image whenever a window has a child, duplicate the alpha and colour conversion that the panels provider already performs in a native shader, and take child placement, clipping, and picking away from Lua. The composite would make layers, `window:stabilize()`, and every other consumer of a window texture show children without changes to those consumers. Drawing children in Lua instead gives windows with children the scene path and leaves a custom renderer responsible for drawing them itself.

The target owns joined-frame eligibility and the single outline because it owns the body geometry and actual layer state. A narrow attachment avoids exposing curve or grant state through generic surfaces and avoids a general container API. The header's outline governs the whole frame so header and body styles cannot create a doubled seam. Granted layers stay rectangular because the runtime receives an unchanged copy; forcing scene fallback on a radius change would trade legible text for appearance and churn claims. A curved body keeps a separate titlebar because joining would need a curved header.

## Known gaps

A popup is clipped to its window's panel because picking covers only the window's own area. The compositor constrains a popup to its window where the client's positioner allows, but a popup that reaches outside it anyway, such as a menu taller than its window, is cut off and its outside part cannot be pointed at.

A window that shows a subsurface for its whole life, as some video players do, never holds a composition layer. `window:stabilize()` copies only the window's own surface.

A client's buffer transform is not applied when a window is drawn. A transformed buffer is drawn untransformed, and a crop of that buffer samples the wrong region.

A panel on a composition layer cannot be seen from behind because a quad layer is single-sided. The same panel can be seen from behind on a scene quad. The provider chooses when a panel holds a layer, so a grant can make a panel that was readable from behind disappear. Scene rendering is the fallback, not a degraded mode, and this is the visible difference that fallback does not account for.

The shared [rendering known gaps](../../../../docs/dev/rendering.md#known-gaps) record further native and backend limits, including OpenVR layer copies and hardware acceptance.
