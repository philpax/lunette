//! The shipped configuration and the examples parse and activate their real
//! provider graphs.
extern crate lunette_lovr;

#[path = "plugin_desktop/mod.rs"]
mod plugin_desktop;

use std::{
    fs,
    path::{Path, PathBuf},
};

#[test]
fn shipped_configuration_files_compile() -> mlua::Result<()> {
    let lua = plugin_desktop::state()?;
    let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../etc/xdg/lunette");
    for name in ["main.luau", "conf.luau"] {
        let path = directory.join(name);
        let source = fs::read_to_string(&path).map_err(mlua::Error::external)?;
        lua.load(&source).set_name(name).into_function()?;
    }
    assert!(plugin_desktop::shutdown(&lua)?.is_empty());
    Ok(())
}

#[test]
fn definitions_are_inert_and_default_load_activates_real_providers() -> mlua::Result<()> {
    let lua = plugin_desktop::state()?;
    plugin_desktop::execute(
        &lua,
        "require 'main'; assert(#events.spawned == 0 and #events.claims == 0 and #events.seats == 0 and events.reads == 0); for name in pairs(events.subscriptions) do assert(subscriptionCount(name) == 0) end",
    )?;
    plugin_desktop::start(&lua)?;
    plugin_desktop::execute(
        &lua,
        "assert(#events.spawned == 1 and #events.seats == 2 and events.reads == 1 and events.enumerations == 2); assert(subscriptionCount('onWindowOpened') == 1); assert(subscriptionCount('onError') == 1)",
    )?;
    assert!(
        !plugin_desktop::callback(&lua, "draw")?.call::<bool>(
            lua.globals()
                .get::<mlua::Table>("events")?
                .get::<mlua::Table>("pass")?
        )?
    );
    assert!(!plugin_desktop::callback(&lua, "quit")?.call::<bool>(())?);
    assert!(plugin_desktop::shutdown(&lua)?.is_empty());
    Ok(())
}

#[test]
fn the_keyboard_example_runs_its_patched_desktop() -> mlua::Result<()> {
    let lua = plugin_desktop::state_for(Path::new("examples/keyboard"))?;
    plugin_desktop::execute(&lua, include_str!("plugin_desktop/example_keyboard.luau"))?;
    assert!(plugin_desktop::shutdown(&lua)?.is_empty());
    Ok(())
}

#[test]
fn the_layout_example_arranges_by_grid_and_follows_the_head() -> mlua::Result<()> {
    let lua = plugin_desktop::state_for(Path::new("examples/layout"))?;
    plugin_desktop::execute(&lua, include_str!("plugin_desktop/example_layout.luau"))?;
    assert!(plugin_desktop::shutdown(&lua)?.is_empty());
    Ok(())
}

#[test]
fn the_desktop_example_changes_behaviour_through_hooks_and_bindings() -> mlua::Result<()> {
    let lua = plugin_desktop::state_for(Path::new("examples/desktop"))?;
    plugin_desktop::execute(&lua, include_str!("plugin_desktop/example_desktop.luau"))?;
    assert!(plugin_desktop::shutdown(&lua)?.is_empty());
    Ok(())
}

#[test]
fn the_first_plugin_example_runs_its_inserted_plugins() -> mlua::Result<()> {
    let lua = plugin_desktop::state_for(Path::new("examples/first-plugin"))?;
    plugin_desktop::execute(
        &lua,
        include_str!("plugin_desktop/example_first_plugin.luau"),
    )?;
    assert!(plugin_desktop::shutdown(&lua)?.is_empty());
    Ok(())
}
