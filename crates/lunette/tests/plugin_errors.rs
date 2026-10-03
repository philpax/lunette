//! Integration coverage for the error stream provider.
//!
//! The plugin facade and runtime and the error stream provider are real
//! checked-in implementations. The fixture keeps the `onError` subscription
//! list, and errors reach its listeners through the real callback boundary,
//! `lunette::callback_error`, whose log output the test captures.

extern crate lunette_lovr;

use std::{
    io,
    sync::{Arc, Mutex},
};

use lunette::callback_error::{TracedError, report_traced};
use mlua::{Function, Lua, Table, Value};
use tracing_subscriber::fmt::MakeWriter;

mod plugin_sources;
mod plugin_support;

fn state() -> mlua::Result<Lua> {
    let (lua, _) = plugin_support::module_state(plugin_sources::register)?;
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
fn the_stream_limits_records_and_delivers_native_errors_and_unloads_safely() -> mlua::Result<()> {
    let lua = state()?;
    let fixture: Function = lua
        .load(include_str!("plugin_errors/errors.luau"))
        .set_name("plugin_errors/errors.luau")
        .eval()?;

    fixture.call::<Value>(())?;
    // The three malformed configurations the fixture enables fail their
    // activations, and nothing else is reported.
    let errors = plugin_support::shutdown(&lua);
    assert_eq!(errors.len(), 3, "{errors:?}");
    assert!(
        errors
            .iter()
            .all(|error| error.contains("plugin errors: option ")),
        "{errors:?}"
    );
    Ok(())
}
