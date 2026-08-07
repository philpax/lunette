//! What a client says it is drawing, and what reaches Lua.
//!
//! `wp_content_type_v1` is a hint and nothing more. There is no handler trait,
//! no events, and no way to ask; a client sets a value or it does not. Adoption
//! is thin and inconsistent, so a client playing video may report nothing at
//! all — which is why the compositor reports the hint rather than acting on it,
//! and `mullion.pacing` combines it with a commit-rate heuristic to decide what
//! is exempt from throttling.
//!
//! Driven over a real `wayland-client`: the whole subject is a value arriving
//! on the wire and being promoted at a commit.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

#[allow(
    dead_code,
    reason = "each integration test binary is its own crate and uses a subset of the harness"
)]
mod harness;

use lunette_compositor::{protocol::ContentType, test_client::TestClient};
use pretty_assertions::assert_eq;
use wayland_client::protocol::wl_surface::WlSurface;

use crate::harness::{only_window, with_one_window};

/// The window's surface, which is what a content type is set on.
fn surface(client: &TestClient) -> WlSurface {
    client
        .surface()
        .cloned()
        .expect("the harness opened a toplevel")
}

#[test]
fn a_client_that_says_nothing_reports_none() {
    let (compositor, _client) = with_one_window();

    assert_eq!(
        only_window(&compositor).content_type,
        ContentType::None,
        "the protocol's own default, and the honest answer for a client that never set one"
    );
}

#[test]
fn a_client_saying_video_reports_video() {
    let (mut compositor, mut client) = with_one_window();
    let surface = surface(&client);

    client.set_content_type(&mut compositor, &surface, ContentType::Video, true);

    assert_eq!(only_window(&compositor).content_type, ContentType::Video);
}

#[test]
fn each_of_the_protocol_s_types_reaches_the_snapshot() {
    for content_type in [ContentType::Photo, ContentType::Video, ContentType::Game] {
        let (mut compositor, mut client) = with_one_window();
        let surface = surface(&client);

        client.set_content_type(&mut compositor, &surface, content_type, true);

        assert_eq!(only_window(&compositor).content_type, content_type);
    }
}

#[test]
fn the_hint_takes_effect_at_the_commit_and_not_before() {
    let (mut compositor, mut client) = with_one_window();
    let surface = surface(&client);

    // Set but not committed. `wp_content_type_v1` is double-buffered like
    // everything else a client sets, so a compositor reading the pending value
    // would describe a state the client has not asked for yet.
    client.set_content_type(&mut compositor, &surface, ContentType::Video, false);
    assert_eq!(
        only_window(&compositor).content_type,
        ContentType::None,
        "the request alone must not take effect"
    );

    client.commit(&mut compositor, &surface);
    assert_eq!(only_window(&compositor).content_type, ContentType::Video);
}

#[test]
fn a_client_taking_the_hint_back_reports_none_again() {
    let (mut compositor, mut client) = with_one_window();
    let surface = surface(&client);

    client.set_content_type(&mut compositor, &surface, ContentType::Video, true);
    assert_eq!(only_window(&compositor).content_type, ContentType::Video);

    // A video player that stopped playing. The value is a hint the client
    // maintains, not a property it sets once.
    client.set_content_type(&mut compositor, &surface, ContentType::None, true);
    assert_eq!(only_window(&compositor).content_type, ContentType::None);
}
