//! Collects the plugin failures an attachment reports, so a test can assert on
//! them together with the failures its shutdown returns.

use std::rc::Rc;

use lunette::plugin::attachment::{self, PluginFailure};
use mlua::Lua;

#[derive(Default)]
struct Reports(Vec<String>);

/// Installs a reporter that records every plugin failure reported in `lua`.
pub fn collect_reports(lua: &Lua) -> mlua::Result<()> {
    lua.set_app_data(Reports::default());
    attachment::set_reporter(
        lua,
        Rc::new(|lua: &Lua, failure: &PluginFailure| {
            if let Some(mut reports) = lua.app_data_mut::<Reports>() {
                reports.0.push(failure.to_string());
            }
        }),
    )?;
    Ok(())
}

/// Shuts the attachment down and returns every failure reported so far,
/// followed by the failures of the shutdown itself.
pub fn shutdown(lua: &Lua) -> Vec<String> {
    let failures = attachment::shutdown_all(lua);
    let mut errors = lua
        .app_data_mut::<Reports>()
        .map(|mut reports| std::mem::take(&mut reports.0))
        .unwrap_or_default();
    errors.extend(failures.iter().map(ToString::to_string));
    errors
}
