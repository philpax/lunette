//! Interaction and focus lifecycle and behavior through the production plugin facade.
extern crate lunette_lovr;

use mlua::Lua;

mod plugin_sources;
mod plugin_support;

fn state() -> mlua::Result<Lua> {
    let (lua, _) = plugin_support::module_state(plugin_sources::register)?;
    Ok(lua)
}

#[test]
fn pointers_share_grab_state_and_release_on_owner_cleanup() -> mlua::Result<()> {
    let lua = state()?;
    lua.load(include_str!("plugin_interaction/runtime.luau"))
        .set_name("interaction/runtime")
        .exec()?;
    // The first failing release is raised to the fixture's destroy call. The
    // second fails while its owner unloads, so it is reported against that
    // owner, and nothing else is.
    let errors = plugin_support::shutdown(&lua);
    assert!(
        errors.len() == 1 && errors[0].contains("native button release failed"),
        "unexpected cleanup errors: {errors:?}"
    );
    Ok(())
}

#[test]
fn focus_grants_are_held_per_owner_and_seat_and_announced() -> mlua::Result<()> {
    let lua = state()?;
    lua.load(include_str!("plugin_interaction/focus.luau"))
        .set_name("interaction/focus")
        .exec()?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "unexpected cleanup errors: {errors:?}");
    Ok(())
}
