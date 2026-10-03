//! Host lifecycle witnesses for plugin attachment retirement.
//!
//! These tests use a real Lua state and the real attachment runtime. Native frame
//! teardown is represented by a fake phase, while external Lua close is real.

#![expect(
    clippy::expect_used,
    reason = "the lifecycle witness uses expectations to report violated ordering and ownership contracts"
)]

use std::{
    cell::{Cell, RefCell},
    io::{self, Write},
    mem::ManuallyDrop,
    rc::Rc,
    sync::{Arc, Mutex, Once},
};

use lunette::{
    plugin::{attachment, declarations},
    reload,
};
use mlua::{Function, Lua, Table, UserData, Value};
use tracing_subscriber::{filter::LevelFilter, fmt::MakeWriter};

#[test]
fn failure_shutdown_finishes_real_graph_before_native_and_external_close() -> mlua::Result<()> {
    let state = ExternalState::new();
    let dropped = Rc::new(Cell::new(false));
    install_failure_runtime(&state.lua, &dropped)?;
    state.lua.globals().set("config_witness", Value::Nil)?;
    let (logs, _log_capture) = capture_host_logs();

    let phases = Rc::new(RefCell::new(Vec::new()));
    let external = Rc::new(RefCell::new(Some(state)));
    let runtime_external = Rc::clone(&external);
    let dropped_runtime = Rc::clone(&dropped);
    let dropped_flush = Rc::clone(&dropped);
    let flush_external = Rc::clone(&external);
    let close_external = Rc::clone(&external);
    let subscriber_phase = Rc::clone(&phases);
    let flush_phase = Rc::clone(&phases);
    let native_phase = Rc::clone(&phases);
    let close_phase = Rc::clone(&phases);
    let mark_phase = Rc::clone(&phases);
    let runtime_phase = Rc::clone(&phases);
    let native_order = Rc::clone(&phases);
    let close_order = Rc::clone(&phases);
    let flushed_commands = Rc::new(RefCell::new(Vec::<String>::new()));
    let flush_commands = Rc::clone(&flushed_commands);

    lunette::plugin::host::terminal_shutdown(
        move || {
            let external = runtime_external.borrow();
            let lua = &external.as_ref().expect("state is open").lua;
            lunette::plugin::host::shutdown(lua, "terminal failure");
            lua.gc_collect()
                .expect("configuration userdata is collectible");
            assert!(
                dropped_runtime.get(),
                "the retained runtime released its config"
            );
            assert!(matches!(
                lua.globals()
                    .get::<Value>("retained_runtime")
                    .expect("retained runtime is readable"),
                Value::UserData(_)
            ));
            assert_eq!(
                lua.globals()
                    .get::<Table>("cleanup_events")
                    .expect("cleanup events are readable")
                    .sequence_values::<String>()
                    .collect::<mlua::Result<Vec<_>>>()
                    .expect("cleanup events are strings"),
                ["B", "A", "P"]
            );
            runtime_phase.borrow_mut().push("runtime");
        },
        move || subscriber_phase.borrow_mut().push("subscribers"),
        move || {
            let external = flush_external.borrow();
            let lua = &external.as_ref().expect("state is open").lua;
            assert_eq!(
                lua.globals()
                    .get::<Table>("cleanup_events")
                    .expect("cleanup events are readable")
                    .sequence_values::<String>()
                    .collect::<mlua::Result<Vec<_>>>()
                    .expect("cleanup events are strings"),
                ["B", "A", "P"]
            );
            assert!(dropped_flush.get(), "config drops before command delivery");
            let commands = lua
                .globals()
                .get::<Table>("cleanup_commands")
                .expect("cleanup commands are readable")
                .sequence_values::<String>()
                .collect::<mlua::Result<Vec<_>>>()
                .expect("cleanup commands are strings");
            *flush_commands.borrow_mut() = commands;
            flush_phase.borrow_mut().push("flush");
        },
        move || {
            assert_eq!(
                native_order.borrow().as_slice(),
                ["runtime", "subscribers", "flush"]
            );
            native_phase.borrow_mut().push("native");
        },
        move || {
            assert_eq!(
                close_order.borrow().as_slice(),
                ["runtime", "subscribers", "flush", "native"]
            );
            close_external
                .borrow_mut()
                .take()
                .expect("state is closed exactly once")
                .close_with(|| mark_phase.borrow_mut().push("mark-closed"));
            close_phase.borrow_mut().push("external-close");
        },
    );

    assert_eq!(
        phases.borrow().as_slice(),
        [
            "runtime",
            "subscribers",
            "flush",
            "native",
            "mark-closed",
            "external-close"
        ]
    );
    assert_eq!(flushed_commands.borrow().as_slice(), ["B", "A", "P"]);
    let log = logs.text();
    assert!(
        log.contains("terminal failure"),
        "host context was not logged: {log}"
    );
    assert!(
        log.contains("cleanup continued") && log.contains("shutdown cleanup failure"),
        "cleanup failure was swallowed: {log}"
    );
    // The disposal failure was raised to its caller before shutdown, and
    // shutdown reports only its own failures.
    assert!(
        !log.contains("explicit disposer failure"),
        "shutdown reported an earlier failure again: {log}"
    );
    drop(external);
    Ok(())
}

#[test]
fn reload_retires_the_attachment_before_rebuilding_the_epoch() -> mlua::Result<()> {
    let lua = configured_state()?;
    let module = lua.create_table()?;
    declarations::install(&lua, &module)?;
    let plugin: Table = module.get("plugin")?;
    lua.globals().set("plugin", plugin.clone())?;
    lua.load(
        r#"
        cleanup_order = {}
        old_token = plugin.contract('test/epoch', 1)
        old_active = false
        old_definition = plugin.define({}, {}, function(context, config)
          old_active = context:active()
          context:effect(function()
            return function()
              cleanup_order[#cleanup_order + 1] = 'runtime'
            end
          end)
          return {}
        end)
        old_runtime = plugin.runtime()
        old_instance = old_runtime:use(old_definition, {})
        old_instance:enable()
        "#,
    )
    .exec()?;

    let forget_subscriptions = || {
        lua.load("cleanup_order[#cleanup_order + 1] = 'subscriptions'")
            .exec()
            .expect("subscription cleanup witness runs");
    };
    set_reload_configuration(&lua)?;
    reload::reload(&lua, &forget_subscriptions).map_err(mlua::Error::external)?;

    assert_eq!(
        lua.load("return table.concat(cleanup_order, ',')")
            .eval::<String>()?,
        "runtime,subscriptions"
    );
    assert!(!lunette::plugin::host::callback_active(&lua));

    let old_token: mlua::AnyUserData = lua.globals().get("old_token")?;
    let bind: Function = plugin.get("bind")?;
    let wrapper = lua.create_table()?;
    wrapper.set_readonly(true);
    assert!(
        bind.call::<()>((old_token, wrapper)).is_err(),
        "a token from the retired epoch must not bind in the new epoch"
    );

    lua.globals().set("old_active", false)?;
    let (stale_ok, stale_error) = lua
        .load(
            "return pcall(function() local stale = new_runtime:use(old_definition, {}); stale:enable() end)",
        )
        .eval::<(bool, mlua::Value)>()?;
    assert!(
        !stale_ok,
        "a definition from the retired epoch must not activate in a new runtime"
    );
    let stale_message = stale_error.to_string()?;
    assert!(
        stale_message.contains("belongs to a retired contract epoch"),
        "a stale definition should be rejected when it is used, got {stale_message}"
    );
    assert!(!lua.globals().get::<bool>("old_active")?);

    assert!(
        lua.globals().get::<bool>("new_active")?,
        "the same contract identity must activate in the rebuilt epoch"
    );
    Ok(())
}

/// The boot path closes the Lua state externally and does not drop its mlua
/// handle, so a reference the host still holds is dropped after the state is
/// gone. The fork's closed-state guard is what makes that drop inert.
#[test]
fn a_reference_dropped_after_external_close_does_not_touch_the_state() -> mlua::Result<()> {
    let state = ExternalState::new();
    let dropped = Rc::new(Cell::new(false));
    let factory: Function = state
        .lua
        .load(
            "return function(witness) return function() assert(witness ~= nil); return 42 end end",
        )
        .eval()?;
    let callback: Function = factory.call(
        state
            .lua
            .create_userdata(DropWitness(Rc::clone(&dropped)))?,
    )?;
    drop(factory);
    assert_eq!(callback.call::<i64>(())?, 42);
    state.close();
    assert!(
        dropped.get(),
        "closing the state collects the callback's payload"
    );
    // Only dropping is valid here; calling the reference after close is not.
    drop(callback);
    Ok(())
}

fn set_reload_configuration(lua: &Lua) -> mlua::Result<()> {
    lua.load(
        r#"
        package.preload.main = function()
          new_token = plugin.contract('test/epoch', 1)
          plugin.bind(new_token, table.freeze({}))
          new_definition = plugin.define({}, {}, function(context, config)
            new_active = context:active()
            return {}
          end)
          new_runtime = plugin.runtime()
          new_instance = new_runtime:use(new_definition, {})
          new_instance:enable()
          return {}
        end
        "#,
    )
    .exec()
}

fn install_failure_runtime(lua: &Lua, dropped: &Rc<Cell<bool>>) -> mlua::Result<()> {
    attachment::install(lua)?;
    let module = lua.create_table()?;
    declarations::install(lua, &module)?;
    let plugin: Table = module.get("plugin")?;
    lua.globals().set("plugin", plugin)?;
    lua.globals().set(
        "config_witness",
        lua.create_userdata(DropWitness(Rc::clone(dropped)))?,
    )?;
    lua.load(
        r#"
        cleanup_events = {}
        cleanup_commands = {}
        resource = { alive = true }
        retained_runtime = plugin.runtime()
        local token = plugin.contract('test/failure', 1)
        local consumer = plugin.define({ service = token }, {}, function(context, config)
          context:effect(function()
            return function()
              assert(context:services().service == resource and resource.alive,
                'provider unavailable during A')
              table.insert(cleanup_events, 'A')
              table.insert(cleanup_commands, 'A')
              error('shutdown cleanup failure')
            end
          end)
          explicit_disposer = context:effect(function()
            return function()
              assert(config ~= nil)
              table.insert(cleanup_events, 'B')
              table.insert(cleanup_commands, 'B')
              error('explicit disposer failure')
            end
          end)
          return {}
        end)
        local provider = plugin.define({}, { service = token }, function(context)
          context:effect(function()
            return function()
              table.insert(cleanup_events, 'P')
              table.insert(cleanup_commands, 'P')
              resource.alive = false
            end
          end)
          return { service = resource }
        end)
        retained_runtime:use(provider, {}):enable()
        retained_runtime:use(consumer, config_witness):enable()
        assert(not pcall(function() explicit_disposer:dispose() end))
        assert(table.concat(cleanup_events, ',') == 'B')
        "#,
    )
    .exec()?;
    Ok(())
}

fn configured_state() -> mlua::Result<Lua> {
    let lua = Lua::new();
    attachment::install(&lua)?;
    lua.load(
        r#"
        lovr = { handlers = {} }
        arg = {}
        package = { loaded = {}, preload = {} }
        require = function(name)
          if package.loaded[name] ~= nil then return package.loaded[name] end
          local loader = assert(package.preload[name], 'missing module: ' .. name)
          local value = loader()
          if value == nil then value = true end
          package.loaded[name] = value
          return value
        end
        package.preload.main = function()
          function lovr.load() end
          return {}
        end
        "#,
    )
    .exec()?;
    Ok(lua)
}

struct ExternalState {
    lua: ManuallyDrop<Lua>,
    raw: *mut mlua::ffi::lua_State,
}

impl ExternalState {
    fn new() -> Self {
        let lua = Lua::new();
        let raw = lua.exec_raw_lua(|raw| raw.state());
        Self {
            lua: ManuallyDrop::new(lua),
            raw,
        }
    }

    fn close(self) {
        self.close_with(|| ());
    }

    fn close_with(self, mark_closed: impl FnOnce()) {
        self.lua.exec_raw_lua(|raw| raw.mark_closed());
        mark_closed();
        // SAFETY: the terminal seam has retired every callback and this is the
        // unique external state owner; no Lua callback is executing.
        unsafe { mlua::ffi::lua_close(self.raw) };
        std::mem::forget(self);
    }
}

impl Drop for ExternalState {
    fn drop(&mut self) {
        self.lua.exec_raw_lua(|raw| raw.mark_closed());
        // SAFETY: this is the unique owner, and no callback is executing.
        unsafe { mlua::ffi::lua_close(self.raw) };
    }
}

struct DropWitness(Rc<Cell<bool>>);

impl UserData for DropWitness {}

impl Drop for DropWitness {
    fn drop(&mut self) {
        self.0.set(true);
    }
}

#[derive(Clone, Default)]
struct HostLogs(Arc<Mutex<Vec<u8>>>);

impl HostLogs {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().expect("log lock is available")).into_owned()
    }
}

struct HostLogWriter(Option<HostLogs>);

impl Write for HostLogWriter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if let Some(logs) = &self.0 {
            logs.0
                .lock()
                .expect("log lock is available")
                .extend_from_slice(bytes);
        }
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

struct HostLogMakeWriter;

impl<'a> MakeWriter<'a> for HostLogMakeWriter {
    type Writer = HostLogWriter;

    fn make_writer(&'a self) -> Self::Writer {
        HOST_LOGS.with(|logs| HostLogWriter(logs.borrow().clone()))
    }
}

thread_local! {
    static HOST_LOGS: RefCell<Option<HostLogs>> = const { RefCell::new(None) };
}

struct HostLogCapture(Option<HostLogs>);

impl Drop for HostLogCapture {
    fn drop(&mut self) {
        HOST_LOGS.with_borrow_mut(|slot| *slot = self.0.take());
    }
}

fn capture_host_logs() -> (HostLogs, HostLogCapture) {
    static INSTALLED: Once = Once::new();
    INSTALLED.call_once(|| {
        let subscriber = tracing_subscriber::fmt()
            .with_ansi(false)
            .with_max_level(LevelFilter::TRACE)
            .with_writer(HostLogMakeWriter)
            .finish();
        tracing::subscriber::set_global_default(subscriber)
            .expect("no other subscriber is installed in this test binary");
    });
    let logs = HostLogs::default();
    let previous = HOST_LOGS.with_borrow_mut(|slot| slot.replace(logs.clone()));
    assert!(previous.is_none(), "log capture is not nested");
    (logs, HostLogCapture(previous))
}
