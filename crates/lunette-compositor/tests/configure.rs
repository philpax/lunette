//! Toplevel configures requested through `Command::ConfigureWindow`.
//!
//! A configure stays pending until the client commits with its serial
//! acknowledged. While it is pending, a request for the same size is not sent
//! again.

#[allow(
    dead_code,
    reason = "each integration test binary is its own crate and uses a subset of the harness"
)]
mod harness;

use harness::{WINDOW_SIZE, only_window, with_one_window};
use lunette_compositor::protocol::{Command, PixelSize, ToplevelStates, WindowId};
use pretty_assertions::assert_eq;

const REQUESTED: PixelSize = PixelSize::new(800, 600);

fn configure(window: WindowId) -> Command {
    Command::ConfigureWindow {
        window,
        size: Some(REQUESTED),
        states: ToplevelStates::new(),
    }
}

#[test]
fn a_commit_that_has_not_acknowledged_a_configure_leaves_it_pending() {
    let (mut compositor, mut client) = with_one_window();
    let window = only_window(&compositor).window;

    compositor.send(configure(window));
    client.settle(&mut compositor, |driver| {
        driver.toplevel_size == Some((800, 600))
    });
    let sent = client.driver().configure_serials().len();

    // The client commits new content without acknowledging the configure, so
    // the commit carries the older serial.
    client.attach_buffer(&mut compositor, WINDOW_SIZE);

    compositor.send(configure(window));
    client.settle_quiet(&mut compositor);

    assert_eq!(
        client.driver().configure_serials().len(),
        sent,
        "the first configure is still pending, so the same size is not sent again"
    );
}

#[test]
fn a_commit_that_acknowledges_a_configure_settles_it() {
    let (mut compositor, mut client) = with_one_window();
    let window = only_window(&compositor).window;

    compositor.send(configure(window));
    client.settle(&mut compositor, |driver| {
        driver.toplevel_size == Some((800, 600))
    });
    let sent = client.driver().configure_serials().len();

    client.acknowledge_toplevel_configure();
    client.attach_buffer(&mut compositor, REQUESTED);
    assert_eq!(only_window(&compositor).size, REQUESTED);

    compositor.send(configure(window));
    client.settle(&mut compositor, |driver| {
        driver.configure_serials().len() > sent
    });

    assert_eq!(
        client.driver().configure_serials().len(),
        sent + 1,
        "the acknowledged configure is no longer pending, so a new request is sent"
    );
}
