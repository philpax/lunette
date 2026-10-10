//! The popups and subsurfaces of each window, as its snapshot reports them.
//!
//! A child is found by the walks the hit test makes: the window's own surface
//! tree through `collect_rendered_surface_tree_at`, and its popups through the
//! popup roots of `build_hit_context`. A child is therefore reported where the
//! pointer reaches it, and a consumer that draws it there draws what the
//! compositor routes input to. Only a surface with content is reported, as only
//! one with content is drawn.
//!
//! The trees are read again after every dispatch, because a subsurface moves at
//! its parent's commit and a popup is dismissed without either committing a new
//! buffer, which is what otherwise marks the snapshot out of date.

use glam::Vec2;
use smithay::{
    desktop::PopupManager,
    reexports::wayland_server::{Resource, protocol::wl_surface::WlSurface},
    utils::{Logical, Point},
    wayland::compositor::{SUBSURFACE_ROLE, with_states},
};

use crate::{
    protocol::{ChildKind, ChildSurface, PixelSize, Stacking, SurfaceOffset},
    surface::{SurfaceRegistry, committed_view},
    wayvr::{
        comp::Application,
        hit_test::{RenderedSurface, build_hit_context, collect_rendered_surface_tree_at},
    },
};

impl Application {
    /// Reads every mapped window's children again, and marks the snapshot out
    /// of date when any window's changed.
    pub(crate) fn refresh_surface_trees(&mut self) {
        let mut changed = false;
        for window in self.windows.windows.values_mut() {
            if !window.mapped {
                continue;
            }
            let size = window.size();
            let children = children_of(
                window.toplevel.wl_surface(),
                [size.width, size.height],
                &self.popup_manager,
                &mut self.surfaces,
            );
            if children != window.children {
                window.children = children;
                changed = true;
            }
        }
        if changed {
            self.touch();
        }
    }
}

/// The children of the window whose surface is `root`, bottom first.
fn children_of(
    root: &WlSurface,
    extent: [u32; 2],
    popups: &PopupManager,
    surfaces: &mut SurfaceRegistry,
) -> Vec<ChildSurface> {
    let mut children = Vec::new();

    // The walk visits the tree in drawing order and includes the window's own
    // surface where it stacks, which divides the children below it from those
    // above.
    let mut stacking = Stacking::Below;
    for rendered in collect_rendered_surface_tree_at(root, Point::from((0, 0)), true) {
        if rendered.surface.id() == root.id() {
            stacking = Stacking::Above;
            continue;
        }
        children.extend(child(&rendered, stacking, surfaces));
    }

    // Popups are drawn over the window's whole tree. The hit test takes the
    // first popup that accepts a point, so they are drawn last to first.
    let context = build_hit_context(root, popups, extent);
    for popup in context.popup_roots.iter().rev() {
        let origin = point(popup.surface_origin);
        for rendered in collect_rendered_surface_tree_at(&popup.surface, origin, true) {
            children.extend(child(&rendered, Stacking::Above, surfaces));
        }
    }

    children
}

/// Describes one surface of a window's tree, or `None` when it has lost its
/// content since the walk.
fn child(
    rendered: &RenderedSurface,
    stacking: Stacking,
    surfaces: &mut SurfaceRegistry,
) -> Option<ChildSurface> {
    let (kind, view) = with_states(&rendered.surface, |states| {
        let kind = if states.role == Some(SUBSURFACE_ROLE) {
            ChildKind::Subsurface
        } else {
            ChildKind::Popup
        };
        (kind, committed_view(states))
    });
    let (size, source_crop) = view?;
    let position = point(rendered.pos);
    Some(ChildSurface {
        surface: surfaces.id_for(&rendered.surface),
        kind,
        position: SurfaceOffset {
            x: position.x,
            y: position.y,
        },
        size: PixelSize::new(
            u32::try_from(size.w).unwrap_or(0),
            u32::try_from(size.h).unwrap_or(0),
        ),
        source_crop,
        stacking,
    })
}

/// Converts a position the upstream walks keep in `f32` back to the integer
/// surface coordinates it was made from.
#[expect(
    clippy::cast_possible_truncation,
    reason = "upstream's walks hold integer surface coordinates in f32, which represents every \
              coordinate a surface can have exactly"
)]
fn point(position: Vec2) -> Point<i32, Logical> {
    Point::from((position.x.round() as i32, position.y.round() as i32))
}
