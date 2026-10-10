//! Adapted from WayVR's `backend/wayvr/hit_test.rs` at commit
//! 42e9deb54cc5c36037b49237867afa3dc4593f4a.
//! Copyright (c) the WayVR authors (galister, oo8dev). Licensed GPL-3.0-only.
//!
//! Maps a point in a window's surface coordinates to the surface under it.
//!
//! lunette draws no decoration panel around a window and hit-tests in the
//! sink's own pixel space, so `PointerHit`, `hit_target`, the panel and UV
//! conversions, and the rendered image fields are left out, and the transforms
//! are always built without server-side decorations. Imported images live on
//! the frame thread, so the logical size of each surface comes from the
//! caller's `surface_size` lookup rather than from the surface's data map.

use glam::{Affine2, Vec2};
use smithay::{
    desktop::PopupManager,
    reexports::wayland_server::{Resource, protocol::wl_surface::WlSurface},
    utils::{Logical, Point, Size},
    wayland::{
        compositor::{
            SUBSURFACE_ROLE, SubsurfaceCachedState, SurfaceAttributes, TraversalAction,
            with_states, with_surface_tree_upward,
        },
        shell::xdg::XdgPopupSurfaceData,
    },
};
use std::{ops::RangeInclusive, rc::Rc};

pub const BORDER_SIZE: u32 = 5;
pub const BAR_SIZE: u32 = 48;

/// The logical size of a surface's current buffer, or `None` when it has none.
pub type SurfaceSize<'a> = &'a dyn Fn(&WlSurface) -> Option<Size<i32, Logical>>;

#[derive(Clone)]
pub struct PopupRoot {
    pub surface: WlSurface,
    pub surface_origin: Vec2,
}

#[derive(Clone)]
pub struct RenderedSurface {
    pub surface: WlSurface,
    pub pos: Vec2,
    pub size: Vec2,
}

#[expect(
    dead_code,
    reason = "lunette's pointer path takes the motion location from the command, not from the hit"
)]
#[derive(Clone)]
pub enum WvrHitTarget {
    Toplevel {
        pos: Vec2,
    },
    Surface {
        surface: WlSurface,
        global_pos: Vec2,
        origin: Vec2,
    },
    Popup {
        surface: WlSurface,
        global_pos: Vec2,
        origin: Vec2,
    },
}

pub struct WvrHitContext<'a> {
    pub surfaces: Rc<[RenderedSurface]>,
    pub popup_roots: Rc<[PopupRoot]>,
    pub mouse_transform: Affine2,
    pub uv_range: RangeInclusive<f32>,
    pub inner_extent: [u32; 2],
    pub surface_size: SurfaceSize<'a>,
}

impl WvrHitContext<'_> {
    pub fn popup_hit_at_client_pos(&self, pos: Vec2) -> Option<(WlSurface, Vec2)> {
        self.popup_roots.iter().find_map(|popup| {
            surface_tree_input_hit_test(
                &popup.surface,
                popup.surface_origin,
                pos,
                true,
                self.surface_size,
            )
        })
    }

    pub fn is_inside_client_area(&self, transformed: Vec2) -> bool {
        self.uv_range.contains(&transformed.x) && self.uv_range.contains(&transformed.y)
    }

    pub fn hit_target_at(&self, client_pos: Vec2) -> Option<WvrHitTarget> {
        let transformed = self.mouse_transform.inverse().transform_point2(Vec2::new(
            client_pos.x / self.inner_extent[0] as f32,
            client_pos.y / self.inner_extent[1] as f32,
        ));
        if let Some((surface, surface_origin)) = self.popup_hit_at_client_pos(client_pos) {
            return Some(WvrHitTarget::Popup {
                surface,
                global_pos: client_pos,
                origin: surface_origin,
            });
        }

        if !self.is_inside_client_area(transformed) {
            return None;
        }

        let hit_surface = self
            .surfaces
            .iter()
            .rev()
            .find(|s| surface_accepts_input(s, client_pos));

        if let Some(surface) = hit_surface {
            return Some(WvrHitTarget::Surface {
                surface: surface.surface.clone(),
                global_pos: client_pos,
                origin: surface.pos,
            });
        }

        Some(WvrHitTarget::Toplevel { pos: client_pos })
    }
}

fn surface_location(states: &smithay::wayland::compositor::SurfaceData) -> Point<i32, Logical> {
    if states.role == Some(SUBSURFACE_ROLE) {
        let mut guard = states.cached_state.get::<SubsurfaceCachedState>();
        guard.current().location
    } else {
        (0, 0).into()
    }
}

pub fn collect_rendered_surface_tree_at(
    root: &WlSurface,
    initial_pos: Point<i32, Logical>,
    include_root: bool,
    surface_size: SurfaceSize<'_>,
) -> Vec<RenderedSurface> {
    let mut out = Vec::new();
    let root_id = root.id();

    with_surface_tree_upward(
        root,
        initial_pos,
        |_, states, parent_pos| {
            let pos = *parent_pos + surface_location(states);

            // do not skip even if this surface has no buffer; children may still have buffers
            TraversalAction::DoChildren(pos)
        },
        |surface, states, parent_pos| {
            if !include_root && surface.id() == root_id {
                return;
            }

            let pos = *parent_pos + surface_location(states);

            if let Some(logical_size) = surface_size(surface) {
                out.push(RenderedSurface {
                    surface: surface.clone(),
                    pos: Vec2::new(pos.x as f32, pos.y as f32),
                    size: Vec2::new(logical_size.w as f32, logical_size.h as f32),
                });
            }
        },
        |_, _, _| true,
    );

    out
}

pub fn collect_rendered_surface_tree(
    root: &WlSurface,
    surface_size: SurfaceSize<'_>,
) -> Rc<[RenderedSurface]> {
    collect_rendered_surface_tree_at(
        root,
        Point::<i32, Logical>::from((0, 0)),
        false,
        surface_size,
    )
    .into()
}

fn surface_accepts_input(surface: &RenderedSurface, global_pos: Vec2) -> bool {
    let local = global_pos - surface.pos;

    if local.x < 0.0 || local.y < 0.0 || local.x >= surface.size.x || local.y >= surface.size.y {
        return false;
    }

    #[allow(clippy::significant_drop_tightening)]
    with_states(&surface.surface, |states| {
        let mut guard = states.cached_state.get::<SurfaceAttributes>();
        let attrs = guard.current();

        match attrs.input_region.as_ref() {
            None => true,
            Some(region) => {
                let point =
                    Point::<i32, Logical>::from((local.x.floor() as i32, local.y.floor() as i32));
                region.contains(point)
            }
        }
    })
}

#[allow(clippy::significant_drop_tightening)]
fn surface_accepts_input_states(
    surface: &WlSurface,
    states: &smithay::wayland::compositor::SurfaceData,
    local: Vec2,
    surface_size: SurfaceSize<'_>,
) -> bool {
    if local.x < 0.0 || local.y < 0.0 {
        return false;
    }

    let mut guard = states.cached_state.get::<SurfaceAttributes>();
    let attrs = guard.current();

    let point = Point::<i32, Logical>::from((local.x.floor() as i32, local.y.floor() as i32));

    // explicit input region wins, even if no render buffer
    if let Some(region) = attrs.input_region.as_ref() {
        return region.contains(point);
    }

    // fallback for normal rendered surfaces
    if let Some(size) = surface_size(surface) {
        return local.x < size.w as f32 && local.y < size.h as f32;
    }

    false
}

pub fn surface_tree_input_hit_test(
    root: &WlSurface,
    root_origin: Vec2,
    global_pos: Vec2,
    include_root: bool,
    surface_size: SurfaceSize<'_>,
) -> Option<(WlSurface, Vec2)> {
    let mut hit = None;
    let root_id = root.id();

    with_surface_tree_upward(
        root,
        Point::<i32, Logical>::from((root_origin.x as i32, root_origin.y as i32)),
        |_, states, parent_pos| {
            let pos = *parent_pos + surface_location(states);
            TraversalAction::DoChildren(pos)
        },
        |surface, states, parent_pos| {
            if !include_root && surface.id() == root_id {
                return;
            }

            let pos = *parent_pos + surface_location(states);
            let surface_origin = Vec2::new(pos.x as f32, pos.y as f32);
            let local = global_pos - surface_origin;

            if surface_accepts_input_states(surface, states, local, surface_size) {
                // with_surface_tree_upward visits bottom-to-top, so later hits win
                hit = Some((surface.clone(), surface_origin));
            }
        },
        |_, _, _| true,
    );

    hit
}

pub fn compute_transforms(
    inner_extent: [u32; 2],
    server_side_decorations: bool,
) -> (Affine2, RangeInclusive<f32>) {
    if !server_side_decorations {
        return (Affine2::IDENTITY, 0.0..=1.0);
    }

    let ix = inner_extent[0].max(1) as f32;
    let iy = inner_extent[1].max(1) as f32;

    let extent_x = ix + BORDER_SIZE as f32 * 2.0;
    let extent_y = iy + BORDER_SIZE as f32 * 2.0 + BAR_SIZE as f32;

    let scale_x = (extent_x + BORDER_SIZE as f32 * 2.0) / extent_x;
    let scale_y = (extent_y + BORDER_SIZE as f32 * 2.0 + BAR_SIZE as f32) / extent_y;

    let translation_x = -(BORDER_SIZE as f32) / ix;
    let translation_y = -((BORDER_SIZE + BAR_SIZE) as f32) / iy;

    let mouse_transform = Affine2::from_scale_angle_translation(
        Vec2::new(scale_x, scale_y),
        0.0,
        Vec2::new(translation_x, translation_y),
    );
    let uv_range = translation_x..=(1.0 - translation_x);

    (mouse_transform, uv_range)
}

pub fn build_hit_context<'a>(
    toplevel: &WlSurface,
    _popup_manager: &PopupManager,
    inner_extent: [u32; 2],
    surface_size: SurfaceSize<'a>,
) -> WvrHitContext<'a> {
    let (mouse_transform, uv_range) = compute_transforms(inner_extent, false);

    let surfaces = collect_rendered_surface_tree(toplevel, surface_size);

    let mut popup_roots = Vec::new();

    for (popup, point) in PopupManager::popups_for_surface(toplevel) {
        let configured = with_states(popup.wl_surface(), |states| {
            states
                .data_map
                .get::<XdgPopupSurfaceData>()
                .unwrap()
                .lock()
                .unwrap()
                .configured
        });

        if !configured {
            continue;
        }

        let popup_origin = point - popup.geometry().loc;

        popup_roots.push(PopupRoot {
            surface: popup.wl_surface().clone(),
            surface_origin: Vec2::new(popup_origin.x as f32, popup_origin.y as f32),
        });
    }

    WvrHitContext {
        surfaces,
        popup_roots: popup_roots.into(),
        mouse_transform,
        uv_range,
        inner_extent,
        surface_size,
    }
}
