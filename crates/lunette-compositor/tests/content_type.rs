//! Exercises `wp_content_type_v1` through a real `wayland-client` connection.
//! The suite covers the protocol's `None` default and every non-default variant
//! in lunette's closed set, and verifies that committed client state reaches the
//! window snapshot.
//!
//! The tests use the in-process compositor seam, not direct state mutation.
//! The harness follows configure-before-buffer ordering and retains each
//! surface's content-type object for the surface lifetime.
//!
//! `wp_content_type_v1` is a client-provided hint, not a detector. The compositor
//! reports it without applying rendering policy; Lua combines it with other
//! signals.

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

    // The pending value moves into effect only when the surface commits.
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

    // A client can replace the hint after a commit; it is not one-time.
    client.set_content_type(&mut compositor, &surface, ContentType::None, true);
    assert_eq!(only_window(&compositor).content_type, ContentType::None);
}
