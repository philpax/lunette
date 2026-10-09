//! The soft reload, exercised by performing one.
//!
//! The binary cases reload against the module the host registered, the roots it mounted, and
//! the `main.luau` that `boot.lua` resolved; `session` records why they spawn it. The client
//! case connects a real Wayland client to lunette's compositor and reloads while it is
//! connected: a reload is confined to one Lua state and must not touch the client.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use lunette_compositor::{protocol::PixelSize, test_client::TestClient, testing::TestCompositor};
use mlua::{Function, Lua, Table};
use pretty_assertions::assert_eq;

use crate::session::assert_exit_status;

mod session;

/// Ten reloads in one session, each asserting the state the previous reload
/// left.
///
/// The fixture checks that `lovr.*` survives, that `boot.lua`'s own callback
/// defaults survive, that a callback the configuration stopped defining stops
/// being called, and that the standard library's modules are re-required. The
/// fixture quits 9 when every check holds and with a distinct status for each
/// check that does not.
#[test]
fn ten_reloads_leave_the_session_where_one_does() {
    assert_exit_status("reload", 9);
}

/// A reload whose configuration raises reports the error and leaves the
/// session running; it does not enter safe mode.
///
/// Safe mode is for a `main.luau` that fails to load at startup. Conflating the
/// two would replace a working session with the fallback over a typo the user
/// can fix and reload again.
#[test]
fn a_reload_that_fails_leaves_the_session_running_and_reloadable() {
    assert_exit_status("reload-failure", 9);
}

/// A client connected across a reload keeps its connection and its window.
#[test]
fn a_connected_client_does_not_notice_a_reload() {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);
    client.attach_buffer(&mut compositor, PixelSize::new(800, 600));
    client.settle(&mut compositor, |driver| {
        !driver.configure_serials().is_empty()
    });

    let before = compositor.snapshot();
    assert_eq!(
        before.windows.len(),
        1,
        "the client should have a window before the reload"
    );

    let lua = configured_state();
    lunette::reload::reload(&lua, &lunette::mirrors::NoMonitors, &|| ())
        .expect("the reload succeeds");

    // The client still communicates, and the compositor still responds. A
    // disconnected client's next round trip would fail at this point.
    client.set_title(&mut compositor, "still here");
    client.settle(&mut compositor, |_| true);

    let after = compositor.snapshot();
    assert_eq!(
        after.windows.len(),
        1,
        "the window should have survived the reload"
    );
    assert_eq!(
        after.windows[0].window, before.windows[0].window,
        "the identifier a reload does not change is what Lua re-associates on"
    );
    assert_eq!(
        after.windows[0].title.as_deref(),
        Some("still here"),
        "the client should still be talking to the compositor"
    );
}

/// Builds a Lua state with boot scaffolding and a runnable `main` module.
///
/// The module comes from `package.preload` to isolate compositor reload from filesystem
/// resolution. `require` must call the preload loader and cache its result in `loaded`;
/// otherwise the reload test could pass without reloading the module.
fn configured_state() -> Lua {
    let lua = Lua::new();
    lua.load(
        "lovr = {} lovr.handlers = setmetatable({}, { __index = lovr }) arg = {} \
         package = { preload = {}, loaded = {} } \
         require = function(name) \
           local loaded = package.loaded[name] \
           if loaded ~= nil then return loaded end \
           local loader = package.preload[name] \
           if loader == nil then error(\"module '\" .. name .. \"' not found\") end \
           local value = loader(name) \
           if value == nil then value = true end \
           package.loaded[name] = value \
           return value \
         end",
    )
    .exec()
    .expect("the boot scaffolding loads");

    let preload: Table = lua
        .globals()
        .get::<Table>("package")
        .expect("package exists")
        .get("preload")
        .expect("package.preload exists");
    let main: Function = lua
        .load("function lovr.draw() end")
        .set_name("@main.luau")
        .into_function()
        .expect("the configuration compiles");
    preload
        .set("main", main)
        .expect("the configuration is reachable");

    lua
}
