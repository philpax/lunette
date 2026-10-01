//! Integration coverage for the error-display provider.
//!
//! The plugin facade and runtime and the error-display provider are real
//! checked-in implementations. The fixture keeps the `onError` subscription
//! list, and errors reach its listeners through the real callback boundary,
//! `lunette::callback_error`, whose log output the test captures.

extern crate lunette_lovr;

use std::{
    io,
    sync::{Arc, Mutex},
};

use lunette::{
    callback_error::{TracedError, report_traced},
    plugin::declarations,
};
use mlua::{Function, Lua, Table, Value};
use tracing_subscriber::fmt::MakeWriter;

mod plugin_sources;
mod plugin_support;

fn state() -> mlua::Result<Lua> {
    let lua = Lua::new();
    plugin_support::collect_reports(&lua)?;
    lua.globals().set(
        "setreadonly",
        lua.create_function(|_, (table, readonly): (Table, bool)| {
            table.set_readonly(readonly);
            Ok(())
        })?,
    )?;

    let package = lua.create_table()?;
    let loaded = lua.create_table()?;
    let preload = lua.create_table()?;
    package.set("loaded", loaded)?;
    package.set("preload", preload.clone())?;
    lua.globals().set("package", package)?;
    lua.globals().set(
        "require",
        lua.create_function(|lua, name: String| {
            let package: Table = lua.globals().get("package")?;
            let loaded: Table = package.get("loaded")?;
            let preload: Table = package.get("preload")?;
            let cached: Value = loaded.get(name.clone())?;
            if !cached.is_nil() {
                return Ok(cached);
            }
            let loader: Function = preload.get(name.clone())?;
            let value: Value = loader.call(name.clone())?;
            let value = if value.is_nil() {
                Value::Boolean(true)
            } else {
                value
            };
            loaded.set(name, value.clone())?;
            Ok(value)
        })?,
    )?;

    let native = lua.create_table()?;
    declarations::install(&lua, &native)?;
    preload.set(
        "@lunette",
        lua.create_function(move |_, _: String| Ok(native.clone()))?,
    )?;

    plugin_sources::register(&lua, &preload)?;
    install_native_error(&lua)?;

    Ok(lua)
}

/// A log sink the boundary's `tracing` output is captured into.
#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl io::Write for Captured {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0
            .lock()
            .map_err(|_| io::Error::other("captured log poisoned"))?
            .extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl<'writer> MakeWriter<'writer> for Captured {
    type Writer = Captured;

    fn make_writer(&'writer self) -> Self::Writer {
        self.clone()
    }
}

/// `nativeError(message, traceback)` reports through the real callback
/// boundary to the fixture's live `onError` listeners and answers what the
/// boundary logged.
fn install_native_error(lua: &Lua) -> mlua::Result<()> {
    let report = lua.create_function(|lua, (message, traceback): (String, String)| {
        let subscriptions: Table = lua.globals().get("subscriptions")?;
        let listeners = subscriptions
            .sequence_values::<Function>()
            .collect::<mlua::Result<Vec<_>>>()?;
        let captured = Captured::default();
        let subscriber = tracing_subscriber::fmt()
            .with_writer(captured.clone())
            .with_ansi(false)
            .finish();
        tracing::subscriber::with_default(subscriber, || {
            report_traced(lua, &listeners, &TracedError { message, traceback });
        });
        let logged = captured
            .0
            .lock()
            .map_err(|_| mlua::Error::runtime("captured log poisoned"))?
            .clone();
        Ok(String::from_utf8_lossy(&logged).into_owned())
    })?;
    lua.globals().set("nativeError", report)
}

#[test]
fn provider_preserves_native_errors_while_displaying_and_unloading_safely() -> mlua::Result<()> {
    let lua = state()?;
    let fixture: Function = lua
        .load(include_str!("plugin_error_display/error_display.lua"))
        .set_name("plugin_error_display/error_display.lua")
        .eval()?;

    fixture.call::<Value>(())?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
