//! Ported from WayVR (https://github.com/wayvr-org/wayvr), backend/wayvr/hit_test.rs, at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Where a pixel in a sink's space lands: which surface, and where inside it.
//!
//! A window is not one surface. It is a toplevel with a tree of subsurfaces
//! under it and, while a menu is open, a set of popups that may extend well
//! outside its own bounds. Delivering a click to the toplevel regardless is what
//! Phase 2 did, and it is why a menu could be opened but not chosen from.
//!
//! # The shape
//!
//! [`HitContext`] is pure geometry over pixel coordinates: rectangles, input
//! regions, and an ordering. It is generic over what identifies a surface, so
//! the algorithm can be exercised with no client, no display, and no GPU —
//! which is what `AC9.4` asks of this crate's tests. [`context`] is the
//! imperative half: it walks the live surface tree once and produces one of
//! those.
//!
//! # Three details that are load-bearing
//!
//! - **Popups are tested before the toplevel's own bounds.** A popup may extend
//!   beyond its parent, and testing the bounds first would discard exactly the
//!   menus that motivate hit testing at all (`hit_test.rs:143`).
//! - **The toplevel's surfaces are searched in reverse.** The tree is collected
//!   bottom-most first, so the last match is the top-most one
//!   (`hit_test.rs:158`).
//! - **Within one popup's tree, a later hit wins**, for the same reason and
//!   because `with_surface_tree_upward` visits bottom-to-top
//!   (`hit_test.rs:310`).
//!
//! # What upstream has that is not here
//!
//! The GPU handle. `RenderedSurface` carries an `Arc<ImageView>`
//! (`hit_test.rs:36`) that the hit test reads only to obtain a size
//! (`:210-219`, `:274-278`). Carrying it here would put a graphics dependency in
//! the crate whose tests must run without a device, so the size arrives as a
//! value and the image stays with whoever draws.
//!
//! The XR layer. `PointerHit`, the UV transform, `uv_range`, and
//! `WvrHitTarget::Panel` (`:19`, `:43`, `:79-109`) exist because WayVR performs
//! the ray intersection in Rust. Under `docs/input.md:5-7` Lua does that and
//! hands down pixel coordinates, so all of it disappears and only
//! `hit_target_at` (`:105`) remains, without the inverse transform it opened
//! with.
//!
//! The chrome. `BORDER_SIZE` and `BAR_SIZE` (`:23-24`) are WayVR's titlebar.
//! lunette's chrome is mullion's, in Lua, and the client area here is the
//! window's own.
//!
//! `Rc<[…]>` at all three of its sites (`:60`, `:61`, `:229`) is `Arc<[…]>`:
//! this crate runs the compositor on its own thread, and `Rc` is not `Send`.

use std::sync::Arc;

use smithay::{
    desktop::{PopupKind, PopupManager},
    reexports::wayland_server::protocol::wl_surface::WlSurface,
    utils::{Logical, Point},
    wayland::{
        compositor::{
            RegionAttributes, SUBSURFACE_ROLE, SubsurfaceCachedState, SurfaceAttributes,
            SurfaceData, TraversalAction, with_states, with_surface_tree_upward,
        },
        shell::xdg::XdgPopupSurfaceData,
    },
};
use tracing::debug;

use crate::protocol::{PixelPoint, PixelSize};

/// Everything a window presents to input, as one testable snapshot.
///
/// `T` is whatever identifies a surface to the caller. Production passes
/// `WlSurface`; a test passes a name, which is what keeps the algorithm
/// separable from the protocol.
#[derive(Clone, Debug)]
pub(crate) struct HitContext<T> {
    /// The toplevel's subsurface tree, bottom-most first, excluding the
    /// toplevel itself. The toplevel is the fallback rather than a member: a
    /// point inside the window that no subsurface claims belongs to it.
    surfaces: Arc<[HitSurface<T>]>,
    /// One entry per configured popup, deepest first, each holding its own
    /// subtree bottom-most first.
    popups: Arc<[PopupTree<T>]>,
    /// The toplevel's own extent, which is what "inside the window" means.
    client_area: PixelSize,
}

impl<T: Clone> HitContext<T> {
    /// What a point in the sink's pixel space lands on.
    ///
    /// Nothing, when the point is outside the window and outside every popup.
    /// A caller withdraws the pointer in that case rather than clamping it in,
    /// because a pointer clamped to an edge is a pointer the client believes is
    /// hovering something.
    pub(crate) fn target_at(&self, point: PixelPoint) -> Option<HitTarget<T>> {
        // Popups first, before the bounds check: a popup may extend outside the
        // window, and a menu that opens past the edge is the ordinary case.
        if let Some(surface) = self.popup_at(point) {
            return Some(surface);
        }

        if !self.inside_client_area(point) {
            return None;
        }

        if let Some(surface) = self
            .surfaces
            .iter()
            .rev()
            .find(|surface| surface.accepts_rendered_input(point))
        {
            return Some(HitTarget::Surface {
                surface: surface.surface.clone(),
                origin: surface.origin,
                local: local_of(point, surface.origin),
            });
        }

        // Inside the window, claimed by no subsurface. Upstream clamps here
        // (`hit_test.rs:170-173`); the bounds check above has already
        // established the point is inside, so there is nothing left to clamp.
        Some(HitTarget::Toplevel { position: point })
    }

    /// The top-most popup surface covering the point.
    ///
    /// Popup trees are searched in the order smithay reports them, which is
    /// deepest first, so a nested menu wins over the menu that opened it.
    /// Within one tree the last accepting surface wins, because the tree is
    /// collected bottom-to-top.
    fn popup_at(&self, point: PixelPoint) -> Option<HitTarget<T>> {
        self.popups.iter().find_map(|popup| {
            let surface = popup
                .surfaces
                .iter()
                .rfind(|surface| surface.accepts_input(point))?;

            Some(HitTarget::Popup {
                surface: surface.surface.clone(),
                origin: surface.origin,
                local: local_of(point, surface.origin),
            })
        })
    }

    fn inside_client_area(&self, point: PixelPoint) -> bool {
        point.x >= 0.0
            && point.y >= 0.0
            && point.x < f64::from(self.client_area.width)
            && point.y < f64::from(self.client_area.height)
    }
}

/// What a point landed on.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum HitTarget<T> {
    /// The window itself, at a point no surface under it claimed.
    Toplevel { position: PixelPoint },
    /// A subsurface of the window.
    Surface {
        surface: T,
        /// Where the surface sits, which is what a pointer focus is anchored
        /// at.
        origin: PixelPoint,
        /// The point in the surface's own coordinates.
        local: PixelPoint,
    },
    /// A popup, or a subsurface of one.
    Popup {
        surface: T,
        origin: PixelPoint,
        local: PixelPoint,
    },
}

/// One surface's geometry and input region, in the sink's pixel space.
///
/// No `PartialEq`: smithay's `RegionAttributes` has none, and comparing two
/// input regions structurally would answer a different question from comparing
/// the sets of points they cover.
#[derive(Clone, Debug)]
pub(crate) struct HitSurface<T> {
    pub(crate) surface: T,
    /// Where the surface's top-left corner sits. Negative for a popup placed
    /// above or to the left of its parent.
    pub(crate) origin: PixelPoint,
    /// The extent of the surface's buffer in logical pixels. Absent when the
    /// surface has no buffer, which happens for a container subsurface whose
    /// children carry the content.
    pub(crate) size: Option<PixelSize>,
    /// The region the client accepts input in. Absent means the whole surface,
    /// which is the protocol's default.
    pub(crate) input: Option<RegionAttributes>,
}

impl<T> HitSurface<T> {
    /// Whether a surface with content accepts input at a point.
    ///
    /// Ported from `surface_accepts_input` (`hit_test.rs:233-253`): the buffer's
    /// extent is checked first, and the input region only refines what is
    /// already inside it. A surface with no buffer accepts nothing, because
    /// upstream never puts one in this list at all (`:210`).
    fn accepts_rendered_input(&self, point: PixelPoint) -> bool {
        let local = local_of(point, self.origin);
        let Some(size) = self.size else {
            return false;
        };
        if !within(local, size) {
            return false;
        }

        match self.input.as_ref() {
            None => true,
            Some(region) => region.contains(logical_of(local)),
        }
    }

    /// Whether a surface accepts input at a point, letting an explicit input
    /// region stand in for a buffer.
    ///
    /// Ported from `surface_accepts_input_states` (`hit_test.rs:255-282`). The
    /// difference from [`HitSurface::accepts_rendered_input`] is deliberate and
    /// is why both exist: a client may set an input region on a surface it has
    /// not drawn into, and that region still receives clicks (`:269-271`).
    /// Without a region, the buffer's extent decides as before (`:274-279`).
    fn accepts_input(&self, point: PixelPoint) -> bool {
        let local = local_of(point, self.origin);
        if local.x < 0.0 || local.y < 0.0 {
            return false;
        }

        if let Some(region) = self.input.as_ref() {
            return region.contains(logical_of(local));
        }

        self.size.is_some_and(|size| within(local, size))
    }
}

/// One popup and the surfaces under it, bottom-most first.
#[derive(Clone, Debug)]
struct PopupTree<T> {
    surfaces: Arc<[HitSurface<T>]>,
}

/// Collects everything a window presents to input, once.
///
/// `size_of` reports a surface's logical size, which is what the caller's own
/// commit bookkeeping knows and this module deliberately does not: reading it
/// from a graphics handle is what coupled upstream's hit test to vulkano.
pub(crate) fn context(
    toplevel: &WlSurface,
    client_area: PixelSize,
    size_of: &dyn Fn(&WlSurface) -> Option<PixelSize>,
) -> HitContext<WlSurface> {
    let surfaces = collect_tree(toplevel, Point::from((0, 0)), false, size_of);

    let popups = PopupManager::popups_for_surface(toplevel)
        .filter_map(|(popup, point)| {
            if !is_configured(&popup) {
                // A popup the client has not answered the configure for has no
                // agreed geometry, so a hit against it would be a hit against a
                // position it is about to be moved from (`hit_test.rs:370-382`).
                debug!("skipping an unconfigured popup in the hit test");
                return None;
            }

            // The popup's origin is where its surface starts, which is its
            // position less the window geometry it declared (`:384`).
            let origin = point - popup.geometry().loc;
            Some(PopupTree {
                surfaces: collect_tree(popup.wl_surface(), origin, true, size_of),
            })
        })
        .collect::<Vec<_>>();

    HitContext {
        surfaces,
        popups: popups.into(),
        client_area,
    }
}

/// Walks a surface tree bottom-to-top, accumulating subsurface offsets.
///
/// Ported from `collect_rendered_surface_tree_at` (`hit_test.rs:186-227`). A
/// surface with no buffer is kept rather than pruned, for the reason upstream
/// records at `:199`: its children may have buffers, and so may its own input
/// region.
fn collect_tree(
    root: &WlSurface,
    origin: Point<i32, Logical>,
    include_root: bool,
    size_of: &dyn Fn(&WlSurface) -> Option<PixelSize>,
) -> Arc<[HitSurface<WlSurface>]> {
    let mut collected: Vec<HitSurface<WlSurface>> = Vec::new();

    with_surface_tree_upward(
        root,
        origin,
        |_, states, parent| TraversalAction::DoChildren(*parent + surface_offset(states)),
        |surface, states, parent| {
            if !include_root && surface == root {
                return;
            }

            let position = *parent + surface_offset(states);
            collected.push(HitSurface {
                surface: surface.clone(),
                origin: PixelPoint::new(f64::from(position.x), f64::from(position.y)),
                size: size_of(surface),
                input: input_region(states),
            });
        },
        |_, _, _| true,
    );

    collected.into()
}

/// Where a surface sits relative to its parent.
///
/// Only a subsurface has an offset; every other role sits at its parent's
/// origin (`hit_test.rs:177-184`).
fn surface_offset(states: &SurfaceData) -> Point<i32, Logical> {
    if states.role == Some(SUBSURFACE_ROLE) {
        states
            .cached_state
            .get::<SubsurfaceCachedState>()
            .current()
            .location
    } else {
        Point::from((0, 0))
    }
}

fn input_region(states: &SurfaceData) -> Option<RegionAttributes> {
    states
        .cached_state
        .get::<SurfaceAttributes>()
        .current()
        .input_region
        .clone()
}

/// Whether a popup's client has answered its configure.
///
/// Upstream unwraps both the lookup and the lock (`hit_test.rs:370-377`). A
/// popup with no role data is not one this compositor tracks, and a poisoned
/// lock means a panic has already happened elsewhere; either way the popup is
/// reported as unconfigured, which excludes it from hit testing rather than
/// propagating a panic through the dispatch loop.
fn is_configured(popup: &PopupKind) -> bool {
    with_states(popup.wl_surface(), |states| {
        states
            .data_map
            .get::<XdgPopupSurfaceData>()
            .and_then(|data| data.lock().ok().map(|attributes| attributes.configured))
            .unwrap_or(false)
    })
}

/// A point in a surface's own coordinates (`hit_test.rs:234`, `:307`).
fn local_of(point: PixelPoint, origin: PixelPoint) -> PixelPoint {
    PixelPoint::new(point.x - origin.x, point.y - origin.y)
}

/// Whether a surface-local point is inside a buffer of that size.
fn within(local: PixelPoint, size: PixelSize) -> bool {
    local.x >= 0.0
        && local.y >= 0.0
        && local.x < f64::from(size.width)
        && local.y < f64::from(size.height)
}

/// A surface-local point as an input region is indexed.
///
/// Floored, because a region is a set of integer rectangles and the pixel a
/// fractional coordinate falls in is the one below it. The cast saturates,
/// which is what keeps a coordinate no client could produce from wrapping into
/// the region.
fn logical_of(local: PixelPoint) -> Point<i32, Logical> {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "a float-to-integer cast saturates, and a region is indexed in whole pixels"
    )]
    Point::from((local.x.floor() as i32, local.y.floor() as i32))
}

#[cfg(test)]
mod tests;
