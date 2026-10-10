//! Covers the decoration mode a toplevel negotiates through `xdg-decoration`.

use lunette_compositor::{
    test_client::{DecorationMode, TestClient},
    testing::TestCompositor,
};

fn with_one_toplevel() -> (TestCompositor, TestClient) {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);
    (compositor, client)
}

#[test]
fn a_toplevel_that_asks_to_draw_its_own_decorations_is_allowed_to() {
    let (mut compositor, mut client) = with_one_toplevel();

    client.request_decoration(&mut compositor, DecorationMode::ClientSide);

    assert_eq!(
        client.driver().decoration_mode,
        Some(DecorationMode::ClientSide)
    );
}

#[test]
fn a_toplevel_that_asks_for_server_side_decorations_gets_them() {
    let (mut compositor, mut client) = with_one_toplevel();

    client.request_decoration(&mut compositor, DecorationMode::ClientSide);
    client.request_decoration(&mut compositor, DecorationMode::ServerSide);

    assert_eq!(
        client.driver().decoration_mode,
        Some(DecorationMode::ServerSide)
    );
}

#[test]
fn a_toplevel_that_withdraws_its_preference_returns_to_server_side_decorations() {
    let (mut compositor, mut client) = with_one_toplevel();

    client.request_decoration(&mut compositor, DecorationMode::ClientSide);
    client.unset_decoration(&mut compositor, DecorationMode::ServerSide);

    assert_eq!(
        client.driver().decoration_mode,
        Some(DecorationMode::ServerSide)
    );
}
