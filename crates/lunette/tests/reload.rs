//! The soft reload, driven by doing one.
//!
//! `lunette-v1.AC5.4` is about a reload applying an edited configuration without
//! disconnecting any client, and about teardown hooks running so that timers and
//! signal connections do not accumulate. Neither half can be established by
//! asserting a flag, so this file establishes them by reloading.
//!
//! The two halves need different apparatus and are both here.
//!
//! The first drives the real binary against a fixture configuration, the way
//! `exit_status.rs` does and for the same reason: the module has to be the one
//! the host registered, the standard library the one the host mounted, and
//! `main.lua` the file `boot.lua` resolved. A unit test on a Lua state a test
//! built has none of those. The fixtures switch the audio, graphics, and headset
//! modules off and open no window, so no display, no XR runtime, and no sound
//! device is needed, and each run points `XDG_DATA_HOME` at a temporary
//! directory of its own.
//!
//! The second connects a real Wayland client to lunette's own compositor and
//! reloads while it is connected. What it establishes is narrow and worth
//! stating: not that the reload knows about the client, but that it does not
//! touch it. A reload is confined to one Lua state, the compositor thread and
//! every connection it holds live in Rust, and `docs/architecture.md` records
//! the rule that makes that safe — Rust holds no long-lived reference into Lua.
//! This is what would fail if a later change reached across that line.

#![expect(
    clippy::expect_used,
    reason = "a failed expectation is how a test reports a failure; the ban is on production code"
)]

use std::{
    path::{Path, PathBuf},
    process::Command,
};

use lunette_compositor::{protocol::PixelSize, test_client::TestClient, testing::TestCompositor};
use mlua::{Function, Lua, Table};
use pretty_assertions::assert_eq;
use tempfile::TempDir;

/// Ten reloads in one session, each one asserting what the last left behind.
///
/// The fixture checks that `lovr.*` survives, that `boot.lua`'s own callback
/// defaults survive, that a callback the configuration stopped defining stops
/// being called, that the standard library's modules are re-required, and that
/// the teardown registry holds the same hooks after the tenth reload as after
/// the first. It quits 9 when every one of those held, and with a distinct
/// status for each that did not.
#[test]
fn ten_reloads_leave_the_session_where_one_does() {
    assert_exit_status("reload", 9);
}

/// A reload whose configuration raises reports it and leaves the session
/// running, rather than falling into safe mode.
///
/// Safe mode is for a `main.lua` that fails to load at startup. Conflating the
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
    lunette::reload::reload(&lua, &|| ()).expect("the reload succeeds");

    // The client is still able to speak, and the compositor still answers: a
    // disconnected client's next round trip is what would fail here.
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

/// A Lua state with the scaffolding `boot.lua` leaves and a `main` module that
/// runs, so the reload above is a whole reload rather than one that fails at its
/// last step.
///
/// `main` arrives through `package.preload` rather than through a file, because
/// this case is about the compositor and not about the filesystem. The `require`
/// here therefore honours `preload` and caches into `loaded`, as Lua's does: one
/// that only read `loaded` would answer nil for the module a reload is meant to
/// run, and the last step of the reload would do nothing while the test still
/// passed.
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
        .set_name("@main.lua")
        .into_function()
        .expect("the configuration compiles");
    preload
        .set("main", main)
        .expect("the configuration is reachable");

    lua
}

/// Runs the binary against the named fixture and asserts the status it exited
/// with.
///
/// The child's stderr and stdout are quoted on failure: the fixtures print which
/// assertion did not hold, and a Lua error arrives on stderr and nowhere else.
fn assert_exit_status(fixture: &str, expected: i32) {
    let directory = fixture_directory(fixture);
    assert!(
        directory.join("lunette").join("main.lua").is_file(),
        "the {fixture} fixture is missing its main.lua"
    );

    // Per run, for the reason `exit_status.rs` records: `boot.lua` creates
    // `$XDG_DATA_HOME/LOVR/<identity>` on every run, and two runs sharing a leaf
    // race to create it.
    let data_directory = match TempDir::with_prefix("lunette-reload-") {
        Ok(directory) => directory,
        Err(error) => panic!("a temporary data directory could not be created: {error}"),
    };

    let run = Command::new(env!("CARGO_BIN_EXE_lunette"))
        // Removed for the reason `HOME` is: a developer's shell exports it to
        // point a session at the working copy, and a fixture that is mislaid
        // would otherwise load the shipped configuration and pass confusingly.
        .env_remove("LUNETTE_CONFIG_PATH")
        .env("XDG_CONFIG_HOME", &directory)
        .env("XDG_DATA_HOME", data_directory.path())
        // Removed so that the developer's own configuration cannot be reached
        // if the fixture is ever mislaid, which would turn a missing fixture
        // into a confusing pass.
        .env_remove("HOME")
        .env("LUNETTE_STDLIB_PATH", standard_library())
        .output();
    let output = match run {
        Ok(output) => output,
        Err(error) => panic!("the lunette binary could not be run: {error}"),
    };

    assert_eq!(
        output.status.code(),
        Some(expected),
        "the {fixture} fixture should have exited {expected}; stdout was:\n{}\nstderr was:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn fixture_directory(fixture: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(fixture)
}

/// The `lua/` directory of the working tree this test was built from, which is
/// what the run mounts: the fixture requires the standard library as it is, not
/// a copy assembled for it.
fn standard_library() -> PathBuf {
    // `crates/lunette` up two levels to the workspace root.
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    let lua = root.join("lua");
    assert!(
        lua.join("mullion").join("teardown.lua").is_file(),
        "{} should hold the standard library",
        lua.display()
    );
    lua
}
