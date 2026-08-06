//! The hit test over synthetic surface trees.
//!
//! Every case here is pure geometry: no client, no display, and no graphics
//! device, which is the whole reason [`super::HitContext`] is generic over what
//! identifies a surface. A surface is a name, a rectangle, and an optional
//! input region.

use pretty_assertions::assert_eq;
use smithay::{
    utils::{Rectangle, Size},
    wayland::compositor::RectangleKind,
};

use super::*;

/// A surface named `name`, of `size`, at `origin`, accepting input everywhere.
fn surface(name: &'static str, origin: (f64, f64), size: (u32, u32)) -> HitSurface<&'static str> {
    HitSurface {
        surface: name,
        origin: PixelPoint::new(origin.0, origin.1),
        size: Some(PixelSize::new(size.0, size.1)),
        input: None,
    }
}

/// A surface with no buffer, as a container subsurface has.
fn bufferless(name: &'static str, origin: (f64, f64)) -> HitSurface<&'static str> {
    HitSurface {
        surface: name,
        origin: PixelPoint::new(origin.0, origin.1),
        size: None,
        input: None,
    }
}

/// An input region built from additive rectangles, in surface-local pixels.
fn region(rects: &[(i32, i32, i32, i32)]) -> RegionAttributes {
    RegionAttributes {
        rects: rects
            .iter()
            .map(|(x, y, width, height)| {
                (
                    RectangleKind::Add,
                    Rectangle::new(Point::from((*x, *y)), Size::from((*width, *height))),
                )
            })
            .collect(),
    }
}

fn context(
    surfaces: Vec<HitSurface<&'static str>>,
    popups: Vec<Vec<HitSurface<&'static str>>>,
) -> HitContext<&'static str> {
    HitContext {
        surfaces: surfaces.into(),
        popups: popups
            .into_iter()
            .map(|surfaces| PopupTree {
                surfaces: surfaces.into(),
            })
            .collect::<Vec<_>>()
            .into(),
        client_area: PixelSize::new(100, 100),
    }
}

fn at(x: f64, y: f64) -> PixelPoint {
    PixelPoint::new(x, y)
}

#[test]
fn a_point_in_an_empty_window_lands_on_the_toplevel() {
    let context = context(Vec::new(), Vec::new());

    assert_eq!(
        context.target_at(at(10.0, 20.0)),
        Some(HitTarget::Toplevel {
            position: at(10.0, 20.0)
        })
    );
}

#[test]
fn a_point_outside_the_window_lands_on_nothing() {
    let context = context(vec![surface("only", (0.0, 0.0), (100, 100))], Vec::new());

    for point in [
        at(-1.0, 50.0),
        at(50.0, -1.0),
        at(100.0, 50.0),
        at(50.0, 100.0),
    ] {
        assert_eq!(
            context.target_at(point),
            None,
            "{point:?} is outside the window and outside every popup"
        );
    }
}

#[test]
fn a_surface_owns_its_top_left_corner_and_not_its_bottom_right() {
    let context = context(vec![surface("panel", (10.0, 10.0), (20, 20))], Vec::new());

    assert!(
        matches!(
            context.target_at(at(10.0, 10.0)),
            Some(HitTarget::Surface {
                surface: "panel",
                ..
            })
        ),
        "the corner a surface starts at belongs to it"
    );
    assert!(
        matches!(
            context.target_at(at(30.0, 20.0)),
            Some(HitTarget::Toplevel { .. })
        ),
        "the corner a surface ends at belongs to whatever is under it"
    );
    assert!(matches!(
        context.target_at(at(29.999, 29.999)),
        Some(HitTarget::Surface {
            surface: "panel",
            ..
        })
    ));
}

#[test]
fn a_subsurface_receives_the_point_in_its_own_coordinates() {
    let context = context(vec![surface("child", (30.0, 40.0), (20, 20))], Vec::new());

    assert_eq!(
        context.target_at(at(35.0, 45.0)),
        Some(HitTarget::Surface {
            surface: "child",
            origin: at(30.0, 40.0),
            local: at(5.0, 5.0),
        })
    );
}

#[test]
fn overlapping_surfaces_resolve_top_most_first() {
    // Collected bottom-most first, so the later entry is the one on top.
    let context = context(
        vec![
            surface("below", (0.0, 0.0), (50, 50)),
            surface("above", (10.0, 10.0), (20, 20)),
        ],
        Vec::new(),
    );

    assert!(matches!(
        context.target_at(at(15.0, 15.0)),
        Some(HitTarget::Surface {
            surface: "above",
            ..
        })
    ));
    assert!(
        matches!(
            context.target_at(at(5.0, 5.0)),
            Some(HitTarget::Surface {
                surface: "below",
                ..
            })
        ),
        "a point the top surface does not cover falls through to the one beneath"
    );
}

#[test]
fn a_surface_with_an_empty_input_region_is_skipped_for_the_one_beneath() {
    let mut transparent = surface("transparent", (0.0, 0.0), (50, 50));
    transparent.input = Some(region(&[]));
    let context = context(
        vec![surface("below", (0.0, 0.0), (50, 50)), transparent],
        Vec::new(),
    );

    assert!(
        matches!(
            context.target_at(at(25.0, 25.0)),
            Some(HitTarget::Surface {
                surface: "below",
                ..
            })
        ),
        "a surface that accepts input nowhere must not swallow the click"
    );
}

#[test]
fn an_input_region_narrows_a_surface_rather_than_replacing_it() {
    let mut narrowed = surface("narrowed", (10.0, 10.0), (40, 40));
    narrowed.input = Some(region(&[(0, 0, 10, 10)]));
    let context = context(vec![narrowed], Vec::new());

    assert!(matches!(
        context.target_at(at(15.0, 15.0)),
        Some(HitTarget::Surface {
            surface: "narrowed",
            ..
        })
    ));
    assert!(
        matches!(
            context.target_at(at(35.0, 35.0)),
            Some(HitTarget::Toplevel { .. })
        ),
        "a point inside the buffer but outside the region is not the surface's"
    );
}

#[test]
fn a_zero_sized_surface_receives_nothing() {
    let context = context(vec![surface("nothing", (10.0, 10.0), (0, 0))], Vec::new());

    assert!(matches!(
        context.target_at(at(10.0, 10.0)),
        Some(HitTarget::Toplevel { .. })
    ));
}

#[test]
fn a_surface_with_no_buffer_receives_nothing_in_the_window_tree() {
    let context = context(vec![bufferless("container", (0.0, 0.0))], Vec::new());

    assert!(
        matches!(
            context.target_at(at(10.0, 10.0)),
            Some(HitTarget::Toplevel { .. })
        ),
        "a container subsurface has nothing drawn in it to click on"
    );
}

#[test]
fn a_popup_over_the_window_takes_the_point_in_surface_local_coordinates() {
    let context = context(
        vec![surface("content", (0.0, 0.0), (100, 100))],
        vec![vec![surface("menu", (40.0, 40.0), (30, 30))]],
    );

    assert_eq!(
        context.target_at(at(50.0, 60.0)),
        Some(HitTarget::Popup {
            surface: "menu",
            origin: at(40.0, 40.0),
            local: at(10.0, 20.0),
        }),
        "a click over a popup belongs to the popup, not to the window under it"
    );
}

#[test]
fn a_point_outside_every_popup_falls_through_to_the_window() {
    let context = context(
        vec![surface("content", (0.0, 0.0), (100, 100))],
        vec![vec![surface("menu", (40.0, 40.0), (30, 30))]],
    );

    assert!(matches!(
        context.target_at(at(10.0, 10.0)),
        Some(HitTarget::Surface {
            surface: "content",
            ..
        })
    ));
}

#[test]
fn a_popup_reaching_past_the_window_still_receives() {
    // The client area is 100 by 100; the popup hangs off the right edge, which
    // is the case that makes popups worth testing before the bounds check.
    let context = context(
        Vec::new(),
        vec![vec![surface("menu", (80.0, 10.0), (40, 40))]],
    );

    assert_eq!(
        context.target_at(at(110.0, 20.0)),
        Some(HitTarget::Popup {
            surface: "menu",
            origin: at(80.0, 10.0),
            local: at(30.0, 10.0),
        }),
        "a popup outside the window is exactly what the bounds check would lose"
    );
}

#[test]
fn a_nested_popup_wins_over_the_one_that_opened_it() {
    // smithay reports popup trees deepest first, and the order is preserved.
    let context = context(
        Vec::new(),
        vec![
            vec![surface("submenu", (30.0, 30.0), (40, 40))],
            vec![surface("menu", (10.0, 10.0), (80, 80))],
        ],
    );

    assert!(
        matches!(
            context.target_at(at(40.0, 40.0)),
            Some(HitTarget::Popup {
                surface: "submenu",
                ..
            })
        ),
        "the point is inside both, and the deeper popup is the one on top"
    );
    assert!(matches!(
        context.target_at(at(15.0, 15.0)),
        Some(HitTarget::Popup {
            surface: "menu",
            ..
        })
    ));
}

#[test]
fn within_one_popup_tree_the_last_accepting_surface_wins() {
    // Collected bottom-to-top, so a subsurface committed over the popup's own
    // content is the one that receives.
    let context = context(
        Vec::new(),
        vec![vec![
            surface("menu", (10.0, 10.0), (50, 50)),
            surface("highlight", (20.0, 20.0), (10, 10)),
        ]],
    );

    assert!(matches!(
        context.target_at(at(25.0, 25.0)),
        Some(HitTarget::Popup {
            surface: "highlight",
            ..
        })
    ));
    assert!(matches!(
        context.target_at(at(15.0, 15.0)),
        Some(HitTarget::Popup {
            surface: "menu",
            ..
        })
    ));
}

#[test]
fn a_popup_surface_with_no_buffer_but_an_input_region_still_receives() {
    // The difference between the two acceptance rules, and the reason both are
    // ported: a client may set an input region on a surface it has not drawn.
    let mut invisible = bufferless("invisible", (10.0, 10.0));
    invisible.input = Some(region(&[(0, 0, 20, 20)]));
    let context = context(Vec::new(), vec![vec![invisible]]);

    assert_eq!(
        context.target_at(at(15.0, 15.0)),
        Some(HitTarget::Popup {
            surface: "invisible",
            origin: at(10.0, 10.0),
            local: at(5.0, 5.0),
        })
    );
    assert_eq!(
        context.target_at(at(35.0, 35.0)),
        Some(HitTarget::Toplevel {
            position: at(35.0, 35.0)
        }),
        "outside the region the popup claims nothing, so the window has it"
    );
}

#[test]
fn a_point_left_of_or_above_a_popup_surface_is_not_in_it() {
    let mut invisible = bufferless("invisible", (10.0, 10.0));
    invisible.input = Some(region(&[(-5, -5, 20, 20)]));
    let context = context(Vec::new(), vec![vec![invisible]]);

    assert_eq!(
        context.target_at(at(8.0, 12.0)),
        Some(HitTarget::Toplevel {
            position: at(8.0, 12.0)
        }),
        "a negative surface-local coordinate is refused before the region is consulted, as \
         upstream refuses it, so the point falls through to the window"
    );
}

#[test]
fn a_fractional_point_lands_in_the_pixel_it_falls_inside() {
    let mut narrowed = surface("narrowed", (0.0, 0.0), (10, 10));
    narrowed.input = Some(region(&[(2, 2, 1, 1)]));
    let context = context(vec![narrowed], Vec::new());

    assert!(
        matches!(
            context.target_at(at(2.9, 2.1)),
            Some(HitTarget::Surface {
                surface: "narrowed",
                ..
            })
        ),
        "a fractional coordinate belongs to the pixel below it"
    );
    assert!(matches!(
        context.target_at(at(3.0, 2.0)),
        Some(HitTarget::Toplevel { .. })
    ));
}
