//! The harness the native plugin test binaries share: the Lua state they
//! build, the failures an attachment reports, and a witness of what Lua
//! collects.

// `expect` would fail in a binary that uses every item, so this is an `allow`.
#![allow(
    dead_code,
    reason = "each test binary compiles this module and uses a different part of it"
)]

use std::{cell::Cell, rc::Rc};

use lunette::plugin::{
    attachment::{self, PluginFailure},
    declarations,
};
use mlua::{Lua, Table, UserData};

/// Builds a state for tests that drive the native plugin API directly, and
/// returns it with the native `plugin` table.
pub fn native_state() -> mlua::Result<(Lua, Table)> {
    let lua = Lua::new();
    collect_reports(&lua)?;
    let module = lua.create_table()?;
    declarations::install(&lua, &module)?;
    let plugin = module.get("plugin")?;
    Ok((lua, plugin))
}

#[derive(Default)]
struct Reports(Vec<String>);

/// Installs a reporter that records every plugin failure reported in `lua`.
fn collect_reports(lua: &Lua) -> mlua::Result<()> {
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

/// A userdata that records when Lua collects it.
pub struct DropWitness(pub Rc<Cell<bool>>);

impl UserData for DropWitness {}

impl Drop for DropWitness {
    fn drop(&mut self) {
        self.0.set(true);
    }
}
