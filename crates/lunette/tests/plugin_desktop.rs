//! Shipped desktop behavior through real providers, facade, attachment, and reload.
extern crate lunette_lovr;

#[path = "plugin_desktop/mod.rs"]
mod plugin_desktop;

use lunette::reload;
use mlua::Function;

#[test]
fn shipped_graph_runs_frames_input_and_ten_production_reloads() -> mlua::Result<()> {
    let lua = plugin_desktop::state()?;
    plugin_desktop::start(&lua)?;
    plugin_desktop::execute(&lua, include_str!("plugin_desktop/startup.lua"))?;
    for _ in 0..10 {
        let forget: Function = lua.globals().get("forgetSubscriptions")?;
        reload::reload(&lua, &|| {
            forget
                .call::<()>(())
                .unwrap_or_else(|error| panic!("forget subscriptions: {error}"));
        })
        .unwrap_or_else(|error| panic!("production reload: {error}"));
        plugin_desktop::execute(&lua, include_str!("plugin_desktop/reloaded.lua"))?;
    }
    assert!(!plugin_desktop::callback(&lua, "quit")?.call::<bool>(())?);
    assert!(plugin_desktop::shutdown(&lua)?.is_empty());
    Ok(())
}

#[test]
fn optional_outages_and_policy_recovery_preserve_independent_scopes() -> mlua::Result<()> {
    let lua = plugin_desktop::state()?;
    plugin_desktop::execute(&lua, include_str!("plugin_desktop/outages.lua"))?;
    let errors = plugin_desktop::shutdown(&lua)?;
    assert!(
        errors
            .iter()
            .all(|error| error.starts_with("plugin graph: instance ")
                && error.contains(" requires missing contract ")),
        "{errors:?}"
    );
    Ok(())
}

#[test]
fn quit_save_returned_errors_and_exceptions_are_logged_without_veto() -> mlua::Result<()> {
    for mode in ["refuse", "throw"] {
        let lua = plugin_desktop::state()?;
        plugin_desktop::start(&lua)?;
        plugin_desktop::execute(
            &lua,
            "events.windows[1] = newWindow(1); emit('onWindowOpened', { window = events.windows[1] }); events.timeline = {}",
        )?;
        lua.globals()
            .get::<mlua::Table>("events")?
            .set("writeMode", mode)?;
        assert!(!plugin_desktop::callback(&lua, "quit")?.call::<bool>(())?);
        plugin_desktop::execute(
            &lua,
            "assert(events.timeline[1] == 'save'); assert(#events.logs == 1); assert(events.logs[1][2] == 'error'); assert(events.logs[1][1]:find('quit callback failed', 1, true)); assertResourcesReleased()",
        )?;
        assert!(plugin_desktop::shutdown(&lua)?.is_empty());
    }
    Ok(())
}

#[test]
fn policy_preserves_placement_precedence_and_write_refusal_through_outages() -> mlua::Result<()> {
    let lua = plugin_desktop::state()?;
    plugin_desktop::execute(&lua, include_str!("plugin_desktop/persistence.lua"))?;
    let errors = plugin_desktop::shutdown(&lua)?;
    assert!(
        errors
            .iter()
            .all(|error| error.starts_with("plugin graph: instance ")
                && error.contains(" requires missing contract ")),
        "{errors:?}"
    );
    Ok(())
}

#[test]
fn resource_and_callback_failure_witnesses_detect_faults() -> mlua::Result<()> {
    let lua = plugin_desktop::state()?;
    plugin_desktop::execute(
        &lua,
        "local plugin = require '@lunette-plugin'; local runtime = plugin.runtime(); local seat; runtime:use(plugin.define(function(config) return config end, {}, {}, function(ctx) ctx:effect(function() seat = require('@lunette').newSeat('leak'); return function() end end) end), {}):enable(); runtime:close(); local ok, message = pcall(assertResourcesReleased); assert(not ok and tostring(message):find('leaked native seat', 1, true), 'witness catches leaked plugin effect resource'); seat:destroy(); assertResourcesReleased()",
    )?;
    plugin_desktop::execute(&lua, include_str!("plugin_desktop/callback_failure.lua"))?;
    assert!(plugin_desktop::shutdown(&lua)?.is_empty());
    Ok(())
}
