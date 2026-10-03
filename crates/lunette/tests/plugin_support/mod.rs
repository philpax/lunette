//! The harness the plugin test binaries share: the Lua states they build, the
//! failures an attachment reports, and a witness of what Lua collects.

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
use mlua::{Function, Lua, Table, UserData, Value};

/// Builds a state for tests that drive the native plugin API directly, and
/// returns it with the native `plugin` table.
pub fn native_state() -> mlua::Result<(Lua, Table)> {
    let lua = base_state()?;
    let module = lua.create_table()?;
    declarations::install(&lua, &module)?;
    let plugin = module.get("plugin")?;
    Ok((lua, plugin))
}

/// Builds a state for tests that require Lua modules, and returns it with the
/// native module that `@lunette` resolves to, so a test can add its fakes.
///
/// `require` resolves through `package.loaded` and `package.preload`, as the
/// session's does, and caches `true` for a module that returns nothing. A
/// reload clears `package.loaded`, so nothing outside it holds a module.
/// `register` adds the test's modules to the preload table.
pub fn module_state(
    register: impl FnOnce(&Lua, &Table) -> mlua::Result<()>,
) -> mlua::Result<(Lua, Table)> {
    let lua = base_state()?;
    let package = lua.create_table()?;
    let preload = lua.create_table()?;
    package.set("loaded", lua.create_table()?)?;
    package.set("preload", preload.clone())?;
    lua.globals().set("package", package)?;
    lua.globals()
        .set("require", lua.create_function(require)?)?;

    let native = lua.create_table()?;
    declarations::install(&lua, &native)?;
    preload.set("@lunette", {
        let native = native.clone();
        lua.create_function(move |_, _: String| Ok(native.clone()))?
    })?;
    register(&lua, &preload)?;
    Ok((lua, native))
}

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

/// A userdata that records when Lua collects it.
pub struct DropWitness(pub Rc<Cell<bool>>);

impl UserData for DropWitness {}

impl Drop for DropWitness {
    fn drop(&mut self) {
        self.0.set(true);
    }
}

/// A state that collects plugin failures and carries the globals fixtures use:
/// `setreadonly` and `collectResources`.
fn base_state() -> mlua::Result<Lua> {
    let lua = Lua::new();
    collect_reports(&lua)?;
    lua.globals().set(
        "setreadonly",
        lua.create_function(|_, (table, readonly): (Table, bool)| {
            table.set_readonly(readonly);
            Ok(())
        })?,
    )?;
    lua.globals().set(
        "collectResources",
        lua.create_function(|lua, ()| lua.gc_collect())?,
    )?;
    Ok(lua)
}

fn require(lua: &Lua, name: String) -> mlua::Result<Value> {
    let package: Table = lua.globals().get("package")?;
    let loaded: Table = package.get("loaded")?;
    let cached: Value = loaded.get(name.as_str())?;
    if !cached.is_nil() {
        return Ok(cached);
    }
    let preload: Table = package.get("preload")?;
    let loader: Function = preload
        .get::<Option<Function>>(name.as_str())?
        .ok_or_else(|| mlua::Error::runtime(format!("unknown module {name}")))?;
    let value = match loader.call(name.as_str())? {
        Value::Nil => Value::Boolean(true),
        value => value,
    };
    loaded.set(name, value.clone())?;
    Ok(value)
}
