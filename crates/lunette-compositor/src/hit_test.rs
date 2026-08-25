//! Ported from WayVR (https://github.com/wayvr-org/wayvr), specifically
//! `backend/wayvr/hit_test.rs` at commit 98f800c644719d3f23a20e50bd3237c29a8082cb.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Hit testing maps a sink-space pixel to a surface and its local coordinates.
//!
//! [`HitContext`] stores window geometry and input regions as a testable snapshot.
//! Its surface identifier is generic, so the geometry can be tested without a
//! Wayland client or graphics device. [`context`] builds the snapshot from the
//! live surface tree.

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
/// `T` identifies a surface. Production uses
/// `WlSurface`; tests use names, which keeps the algorithm
/// independent of the protocol.
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
    /// Returns `None` when the point is outside the window and every popup. The
    /// input path withdraws the pointer instead of clamping it to an edge, which
    /// would make the client believe that it still hovers something.
    pub(crate) fn target_at(&self, point: PixelPoint) -> Option<HitTarget<T>> {
        // A popup may extend beyond the toplevel, so check it before the bounds.
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

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum HitTarget<T> {
    /// The window itself, at a point no surface under it claimed.
    Toplevel { position: PixelPoint },
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
    /// Whether a surface with a buffer accepts input at a point.
    ///
    /// The input region narrows the buffer extent. A surface without a buffer
    /// accepts no input in the toplevel's surface tree.
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

    /// Whether a surface accepts input at a point.
    ///
    /// An explicit input region can claim input without a buffer. Without a
    /// region, the buffer extent determines the accepted points.
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

/// Collects the geometry and input regions used for one hit-test snapshot.
///
/// `size_of` supplies logical buffer sizes without coupling this module to a
/// graphics handle. The compositor owns the size lookup and its graphics resources.
pub(crate) fn context(
    toplevel: &WlSurface,
    client_area: PixelSize,
    size_of: &dyn Fn(&WlSurface) -> Option<PixelSize>,
) -> HitContext<WlSurface> {
    let surfaces = collect_tree(toplevel, Point::from((0, 0)), false, size_of);

    let popups = PopupManager::popups_for_surface(toplevel)
        .filter_map(|(popup, point)| {
            if !is_configured(&popup) {
                // An unconfigured popup has no agreed geometry, so exclude it from
                // hit testing until the client answers the configure.
                debug!("skipping an unconfigured popup in the hit test");
                return None;
            }

            // The surface starts at the popup position minus its declared geometry.
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

/// Walks a surface tree bottom-to-top and accumulates subsurface offsets.
///
/// It keeps bufferless surfaces because their children may have buffers, and
/// their input regions may still claim points.
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

/// Returns the offset of a surface from its parent.
///
/// Only a subsurface has an offset; every other role uses its parent's origin.
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

/// Returns whether a popup has configured geometry.
///
/// Missing role data and a poisoned state lock both exclude the popup from hit
/// testing instead of propagating a panic through the dispatch loop.
fn is_configured(popup: &PopupKind) -> bool {
    with_states(popup.wl_surface(), |states| {
        states
            .data_map
            .get::<XdgPopupSurfaceData>()
            .and_then(|data| data.lock().ok().map(|attributes| attributes.configured))
            .unwrap_or(false)
    })
}

fn local_of(point: PixelPoint, origin: PixelPoint) -> PixelPoint {
    PixelPoint::new(point.x - origin.x, point.y - origin.y)
}

fn within(local: PixelPoint, size: PixelSize) -> bool {
    local.x >= 0.0
        && local.y >= 0.0
        && local.x < f64::from(size.width)
        && local.y < f64::from(size.height)
}

/// Converts a surface-local point to the integer coordinates used by an input region.
///
/// Flooring selects the pixel below a fractional coordinate. The saturating cast
/// prevents an unrepresentable coordinate from wrapping into the region.
fn logical_of(local: PixelPoint) -> Point<i32, Logical> {
    #[expect(
        clippy::cast_possible_truncation,
        reason = "a float-to-integer cast saturates, and a region is indexed in whole pixels"
    )]
    Point::from((local.x.floor() as i32, local.y.floor() as i32))
}

#[cfg(test)]
mod tests;
