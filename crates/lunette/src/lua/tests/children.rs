//! A window's popups and subsurfaces, as `window:getChildSurfaces()` lists
//! them: the snapshot's placement with each child's texture from the ledger.

use lunette_compositor::protocol::{
    ChildKind, ChildSurface, PixelSize, SourceCrop, Stacking, SurfaceOffset, WindowSnapshot,
};
use pretty_assertions::assert_eq;

use crate::{
    import::formats::Alpha,
    lua::tests::{FakeTexture, TestSession, lua, run, session, snapshot, surface_id, window},
    texture::TextureDescription,
};

const MENU: u64 = 20;
const VIDEO: u64 = 21;

fn child(raw: u64, kind: ChildKind, stacking: Stacking, x: i32, y: i32) -> ChildSurface {
    ChildSurface {
        surface: surface_id(raw),
        kind,
        position: SurfaceOffset { x, y },
        size: PixelSize::new(120, 60),
        source_crop: SourceCrop::new(0.0, 0.25, 1.0, 0.75).expect("ordered"),
        stacking,
    }
}

fn parent(children: Vec<ChildSurface>) -> WindowSnapshot {
    let mut parent = window(1, "editor", "editor", PixelSize::new(640, 480));
    parent.children = children;
    parent
}

fn install(session: &TestSession, raw: u64, texture: i64, alpha: Alpha) {
    session.with_textures(|textures| {
        textures.install(
            surface_id(raw),
            FakeTexture(texture),
            TextureDescription {
                size: PixelSize::new(240, 120),
                alpha,
            },
        )
    });
}

#[test]
fn a_window_lists_its_children_bottom_first_with_their_placement_and_texture() {
    let session = session(vec![parent(vec![
        child(VIDEO, ChildKind::Subsurface, Stacking::Below, 0, 10),
        child(MENU, ChildKind::Popup, Stacking::Above, -5, 300),
    ])]);
    install(&session, VIDEO, 41, Alpha::Opaque);
    install(&session, MENU, 42, Alpha::Present);
    let lua = lua(&session);

    let (count, id, kind, below, x, y, width, height, texture, opaque): (
        usize,
        u64,
        String,
        bool,
        i32,
        i32,
        u32,
        u32,
        i64,
        bool,
    ) = run(
        &lua,
        "local c = lunette.windows()[1]:getChildSurfaces()
         local video = c[1]
         return #c, video.id, video.kind, video.below, video.x, video.y, video.width,
             video.height, video.texture, video.opaque",
    );
    assert_eq!(count, 2);
    assert_eq!((id, kind.as_str(), below), (VIDEO, "subsurface", true));
    assert_eq!((x, y, width, height), (0, 10, 120, 60));
    assert_eq!((texture, opaque), (41, true));

    let (kind, below, x, y, texture, opaque): (String, bool, i32, i32, i64, bool) = run(
        &lua,
        "local menu = lunette.windows()[1]:getChildSurfaces()[2]
         return menu.kind, menu.below, menu.x, menu.y, menu.texture, menu.opaque",
    );
    assert_eq!((kind.as_str(), below), ("popup", false));
    assert_eq!((x, y), (-5, 300), "a child can reach outside its window");
    assert_eq!((texture, opaque), (42, false));

    let crop: (f64, f64, f64, f64) = run(
        &lua,
        "local crop = lunette.windows()[1]:getChildSurfaces()[2].crop
         return crop.x, crop.y, crop.width, crop.height",
    );
    assert_eq!(crop, (0.0, 0.25, 1.0, 0.5));
}

#[test]
fn a_child_without_a_texture_this_frame_is_left_out() {
    let session = session(vec![parent(vec![
        child(VIDEO, ChildKind::Subsurface, Stacking::Above, 0, 0),
        child(MENU, ChildKind::Popup, Stacking::Above, 10, 10),
    ])]);
    install(&session, MENU, 42, Alpha::Present);
    let lua = lua(&session);

    let (count, kind): (usize, String) = run(
        &lua,
        "local c = lunette.windows()[1]:getChildSurfaces() return #c, c[1].kind",
    );
    assert_eq!((count, kind.as_str()), (1, "popup"));
}

#[test]
fn a_window_without_children_and_a_dead_window_list_none() {
    let session = session(vec![parent(vec![child(
        MENU,
        ChildKind::Popup,
        Stacking::Above,
        0,
        0,
    )])]);
    install(&session, MENU, 42, Alpha::Present);
    let lua = lua(&session);
    assert_eq!(
        run::<usize>(
            &lua,
            "held = lunette.windows()[1] return #held:getChildSurfaces()"
        ),
        1
    );

    session.begin(snapshot(Vec::new(), Vec::new()));
    assert_eq!(
        run::<usize>(&lua, "return #held:getChildSurfaces()"),
        0,
        "a dead window's children are gone with it"
    );

    let bare = crate::lua::tests::session(vec![window(1, "htop", "foot", PixelSize::new(8, 8))]);
    let bare_lua = crate::lua::tests::lua(&bare);
    assert_eq!(
        run::<usize>(&bare_lua, "return #lunette.windows()[1]:getChildSurfaces()"),
        0
    );
}
