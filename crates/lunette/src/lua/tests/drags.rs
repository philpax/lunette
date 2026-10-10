//! Drag handles: what `seat.drag` reports while a client drags, and the icon's
//! texture, which comes from the ledger as a window's does.

use lunette_compositor::protocol::{
    DragIcon, DragId, DragSnapshot, PixelSize, SeatSnapshot, SourceCrop, SurfaceOffset,
};
use pretty_assertions::assert_eq;

use super::*;
use crate::{
    control::{
        answer,
        wire::{Handle, HandleId, HandleKind, Reply, Value},
    },
    import::formats::Alpha,
    lua::tests::seats::{seat, seated},
    texture::TextureDescription,
};

const ICON_SURFACE: u64 = 7;

fn drag_id(raw: u64) -> DragId {
    DragId::new(raw).expect("non-zero")
}

fn icon() -> DragIcon {
    DragIcon {
        surface: surface_id(ICON_SURFACE),
        size: PixelSize::new(32, 24),
        source_crop: SourceCrop::new(0.0, 0.0, 0.5, 1.0).expect("ordered"),
        offset: SurfaceOffset { x: -4, y: -6 },
    }
}

/// The default seat, carrying `drag` when one is given.
fn dragging(drag: Option<DragSnapshot>) -> Arc<Snapshot> {
    let mut carrier: SeatSnapshot = seat(DEFAULT_SEAT.get(), "lunette", "us");
    carrier.drag = drag;
    seated(Vec::new(), vec![carrier])
}

fn install_icon(session: &TestSession, texture: i64, alpha: Alpha) {
    session.with_textures(|textures| {
        textures.install(
            surface_id(ICON_SURFACE),
            FakeTexture(texture),
            TextureDescription {
                size: PixelSize::new(64, 24),
                alpha,
            },
        )
    });
}

#[test]
fn a_seat_carries_no_drag_until_a_client_starts_one() {
    let session = session(Vec::new());
    session.begin(dragging(None));
    let lua = lua(&session);

    assert!(run::<bool>(
        &lua,
        "return lunette.defaultSeat().drag == nil"
    ));
}

#[test]
fn a_drag_reports_its_icon_s_size_offset_crop_and_texture() {
    let session = session(Vec::new());
    session.begin(dragging(Some(DragSnapshot {
        drag: drag_id(3),
        icon: Some(icon()),
    })));
    install_icon(&session, 42, Alpha::Present);
    let lua = lua(&session);

    let (id, dead, width, height, x, y, opaque): (u64, bool, u32, u32, i32, i32, bool) = run(
        &lua,
        "local d = lunette.defaultSeat().drag
         return d.id, d.dead, d.width, d.height, d.x, d.y, d.opaque",
    );
    assert_eq!((id, dead), (3, false));
    assert_eq!((width, height), (32, 24));
    assert_eq!(
        (x, y),
        (-4, -6),
        "the icon's corner sits up and left of the pointer"
    );
    assert!(!opaque);

    let (texture, left, top, width, height): (i64, f64, f64, f64, f64) = run(
        &lua,
        "local d = lunette.defaultSeat().drag
         return d:getTexture(), d:getSourceCrop()",
    );
    assert_eq!(texture, 42);
    assert_eq!((left, top, width, height), (0.0, 0.0, 0.5, 1.0));
}

#[test]
fn a_drag_without_an_icon_has_no_texture_and_no_size() {
    let session = session(Vec::new());
    session.begin(dragging(Some(DragSnapshot {
        drag: drag_id(3),
        icon: None,
    })));
    let lua = lua(&session);

    let (width, height, texture, stable): (u32, u32, bool, bool) = run(
        &lua,
        "local d = lunette.defaultSeat().drag
         return d.width, d.height, d:getTexture(), d:stabilize()",
    );
    assert_eq!((width, height), (0, 0));
    assert!(!texture);
    assert!(!stable);
}

#[test]
fn a_stabilized_icon_keeps_its_identity_while_the_client_s_buffers_rotate() {
    let session = session(Vec::new());
    let carrying = || {
        dragging(Some(DragSnapshot {
            drag: drag_id(3),
            icon: Some(icon()),
        }))
    };
    session.begin(carrying());
    install_icon(&session, 42, Alpha::Present);
    let lua = lua(&session);

    let (stable, imported): (i64, i64) = run(
        &lua,
        "held = lunette.defaultSeat().drag return held:stabilize(), held:getTexture()",
    );
    assert_ne!(stable, imported, "the copy is lunette's, not the client's");

    install_icon(&session, 43, Alpha::Present);
    session.begin(carrying());
    let (after, rotated): (i64, i64) = run(&lua, "return held:stabilize(), held:getTexture()");
    assert_eq!(after, stable);
    assert_eq!(rotated, 43);
}

#[test]
fn a_held_drag_goes_dead_when_it_ends_and_the_next_is_another_drag() {
    let session = session(Vec::new());
    session.begin(dragging(Some(DragSnapshot {
        drag: drag_id(3),
        icon: Some(icon()),
    })));
    install_icon(&session, 42, Alpha::Present);
    let lua = lua(&session);
    run::<()>(&lua, "held = lunette.defaultSeat().drag");

    session.begin(dragging(None));
    let (dead, width, texture): (bool, u32, bool) =
        run(&lua, "return held.dead, held.width, held:getTexture()");
    assert!(dead);
    assert_eq!(width, 32, "a dead handle answers with its last values");
    assert!(!texture, "a dead drag has no texture to give");

    session.begin(dragging(Some(DragSnapshot {
        drag: drag_id(4),
        icon: None,
    })));
    let (still_dead, same, again): (bool, bool, bool) = run(
        &lua,
        "local next = lunette.defaultSeat().drag
         return held.dead, held == next, next == lunette.defaultSeat().drag",
    );
    assert!(
        still_dead,
        "another drag on the seat does not revive this one"
    );
    assert!(!same);
    assert!(again, "two reads of one drag compare equal");
}

#[test]
fn an_opaque_icon_buffer_is_reported_opaque() {
    let session = session(Vec::new());
    session.begin(dragging(Some(DragSnapshot {
        drag: drag_id(3),
        icon: Some(icon()),
    })));
    install_icon(&session, 42, Alpha::Opaque);
    let lua = lua(&session);

    assert!(run::<bool>(
        &lua,
        "return lunette.defaultSeat().drag.opaque"
    ));
}

#[test]
fn lunctl_names_a_drag_by_its_kind_and_id() {
    let session = session(Vec::new());
    session.begin(dragging(Some(DragSnapshot {
        drag: drag_id(3),
        icon: None,
    })));
    let lua = lua(&session);

    match answer(&lua, "return lunette.defaultSeat().drag") {
        Reply::Returned(values) => assert_eq!(
            values,
            [Value::Handle(Handle {
                kind: HandleKind::Drag,
                id: Some(HandleId::Number(3)),
            })]
        ),
        other => panic!("expected a return, and lunctl answered {other:?}"),
    }
}
