//! Policy integration through the production plugin facade and native lifecycle.

extern crate lunette_lovr;

mod plugin_sources;
mod plugin_support;

#[test]
fn policy_providers_compose_and_release_caller_resources() -> mlua::Result<()> {
    run(include_str!("plugin_policy/fixtures/policy.luau"))
}

#[test]
fn tags_are_held_excluded_laid_out_and_announced() -> mlua::Result<()> {
    run(include_str!("plugin_policy/fixtures/tags.luau"))
}

/// Runs a fixture against the real providers, with the native fixture's
/// layer claims and matrices.
fn run(fixture: &str) -> mlua::Result<()> {
    let (lua, _) = plugin_support::module_state(plugin_sources::register)?;
    lua.load(include_str!("plugin_policy/fixtures/native.luau"))
        .exec()?;
    lua.load(fixture).exec()?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
