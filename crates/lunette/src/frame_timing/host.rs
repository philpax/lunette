//! Opt-in coherent CPU frame observations; the host instruments its boot source without patching LÖVR callbacks.

use std::{cell::Cell, rc::Rc};

use mlua::{FromLua, Function, Lua, Table, Value};

use crate::{
    callback_error,
    events::ERROR,
    lua::{
        LuaTexture, Session,
        declarations::{AliasSpec, Aliased, Parameter, Type, Typed, of},
        values::Cancel,
    },
};

const KEY: &str = "lunette.frame-timing";
const LISTENER: &str = "lunette.frame-timing-listener";

/// The one public callback that receives a reused read-only primitive record.
pub(crate) struct Listener(pub Function);

impl FromLua for Listener {
    fn from_lua(value: Value, lua: &Lua) -> mlua::Result<Self> {
        Function::from_lua(value, lua).map(Self)
    }
}

pub(crate) struct FrameTiming;

impl Typed for FrameTiming {
    fn luau() -> Type {
        Type::Named("FrameTiming")
    }
}

impl Aliased for FrameTiming {
    const ALIAS: AliasSpec = AliasSpec {
        doc: "A reused coherent CPU frame record. Durations are seconds; heap values are net KiB. Missing phases are nil.",
        name: Self::luau,
        definition: |_| record_type(),
    };
}

fn record_type() -> Type {
    let mut fields = vec![];
    for name in [
        "sequence",
        "syncTime",
        "sync",
        "interval",
        "update",
        "draw",
        "graphicsSubmit",
        "headsetSubmit",
        "present",
        "gc",
        "observer",
        "heapSync",
        "heapUpdate",
        "heapDraw",
        "heapGraphicsSubmit",
        "heapHeadsetSubmit",
        "heapPresent",
        "heapGc",
        "nativeInterval",
        "nativeWork",
        "skipped",
        "refreshRate",
        "gcBudgetUs",
        "gcSteps",
    ] {
        fields.push(Parameter {
            name,
            ty: of::<Option<f64>>(),
        });
    }
    for name in [
        "active",
        "visible",
        "focused",
        "gpuTiming",
        "gcCycleCompleted",
        "gcOverrun",
        "antialias",
    ] {
        fields.push(Parameter {
            name,
            ty: of::<Option<bool>>(),
        });
    }
    fields.push(Parameter {
        name: "foveation",
        ty: of::<Option<String>>(),
    });
    fields.push(Parameter {
        name: "executionMode",
        ty: of::<Option<String>>(),
    });
    fields.push(Parameter {
        name: "supersample",
        ty: of::<Option<String>>(),
    });
    fields.push(Parameter {
        name: "betweenFrames",
        ty: of::<Option<f64>>(),
    });
    Type::Record(fields)
}

impl Typed for Listener {
    fn luau() -> Type {
        Type::Function {
            receiver: None,
            parameters: vec![Parameter {
                name: "record",
                ty: of::<FrameTiming>(),
            }],
            returns: Box::new(of::<()>()),
        }
    }
}

/// Installs an inactive sampler. The boot chunk receives it directly, outside the public module.
pub fn install(lua: &Lua, execution_mode: &str) -> mlua::Result<()> {
    let state: Table = lua
        .load(include_str!("sampler.luau"))
        .call(execution_mode)?;
    lua.set_named_registry_value(KEY, state)
}

/// Returns the host-owned sampler passed as the boot chunk's argument.
pub fn sampler(lua: &Lua) -> mlua::Result<Table> {
    lua.named_registry_value(KEY)
}

pub(crate) fn observe(lua: &Lua, listener: Listener) -> mlua::Result<Cancel> {
    let lovr: Table = lua.globals().get("lovr")?;
    if lovr.get::<Option<Table>>("timer")?.is_none() {
        return Err(mlua::Error::runtime(
            "frame timing: the timer module is disabled",
        ));
    }
    let state = sampler(lua)?;
    if state.get::<bool>("active")? {
        return Err(mlua::Error::runtime(
            "frame timing: an observer is already active",
        ));
    }
    state.get::<Function>("reset")?.call::<()>(())?;
    let generation = state
        .get::<Option<u64>>("generation")?
        .unwrap_or(0)
        .wrapping_add(1);
    state.set("generation", generation)?;
    state.set("active", true)?;
    lua.set_named_registry_value(LISTENER, listener.0)?;
    let active = Rc::new(Cell::new(true));
    Ok(Cancel(lua.create_function(move |lua, ()| {
        if active.replace(false) && sampler(lua)?.get::<u64>("generation")? == generation {
            sampler(lua)?.set("active", false)?;
            lua.unset_named_registry_value(LISTENER)?;
        }
        Ok(())
    })?))
}

/// Retires direct subscriptions at the same source-reload boundary as native events.
pub(crate) fn clear(lua: &Lua) -> mlua::Result<()> {
    if let Ok(state) = sampler(lua) {
        state.set("active", false)?;
        state.set(
            "generation",
            state
                .get::<Option<u64>>("generation")?
                .unwrap_or(0)
                .wrapping_add(1),
        )?;
        state.get::<Function>("reset")?.call::<()>(())?;
        lua.unset_named_registry_value(LISTENER)?;
    }
    Ok(())
}

/// Reports observer errors through the same stream as native event callbacks.
pub fn publish_reported<T: LuaTexture>(
    lua: &Lua,
    session: &Session<T>,
    between_seconds: Option<f64>,
) {
    if let Err(error) = publish(lua, between_seconds) {
        callback_error::report(
            lua,
            &session.listeners(ERROR),
            "frame timing observer",
            &error,
        );
    }
}

/// Answers whether timing work is requested; the disabled path samples no clock or heap.
pub fn active(lua: &Lua) -> mlua::Result<bool> {
    sampler(lua)?.get("active")
}

/// Marks the net heap immediately after scheduling, before optional control and compilation work.
pub fn collected(
    lua: &Lua,
    gc_seconds: f64,
    budget_us: u128,
    steps: u32,
    cycle_completed: bool,
    overrun: bool,
) -> mlua::Result<()> {
    let state = sampler(lua)?;
    if state.get::<bool>("active")? {
        state
            .get::<Function>("collected")?
            .call::<()>((gc_seconds, budget_us as f64))?;
        let row: Table = state.get("row")?;
        row.set("gcSteps", steps)?;
        row.set("gcCycleCompleted", cycle_completed)?;
        row.set("gcOverrun", overrun)?;
    }
    Ok(())
}

/// Publishes only rows whose sync boundary occurred with observation enabled.
pub fn publish(lua: &Lua, between_seconds: Option<f64>) -> mlua::Result<()> {
    let state = sampler(lua)?;
    if !state.get::<bool>("active")? {
        return Ok(());
    }
    let row: Table = state.get("row")?;
    if row.get::<Option<f64>>("syncTime")?.is_none() {
        return Ok(());
    }
    let row: Table = state.get::<Function>("finish")?.call(())?;
    row.set("betweenFrames", between_seconds)?;
    let listener: Function = lua.named_registry_value(LISTENER)?;
    let generation = state.get::<u64>("generation")?;
    row.set_readonly(true);
    let result = listener.call::<()>(row.clone());
    row.set_readonly(false);
    row.set("syncTime", Value::Nil)?;
    if result.is_err() && state.get::<u64>("generation")? == generation {
        state.set("active", false)?;
        lua.unset_named_registry_value(LISTENER)?;
    }
    result
}

/// Adds phase marks at exact known boot boundaries, rejecting upstream drift instead of partial instrumentation.
pub fn instrument_boot(source: &[u8]) -> Result<String, String> {
    let mut source = String::from_utf8(source.to_vec())
        .map_err(|error| format!("frame timing: boot source: {error}"))?;
    let replacements = [
        (
            "local lovr = lovr",
            "local lovr = lovr\nlocal frameTrace = ...",
        ),
        (
            "  require((main:gsub('%.luau?$', '')))",
            "  frameTrace.supersample = tostring(conf.headset and conf.headset.supersample)\n  frameTrace.antialias = conf.headset and conf.headset.antialias\n  require((main:gsub('%.luau?$', '')))",
        ),
        (
            "    local dt = 0\n    if lovr.headset then lovr.headset.update() end",
            "    local tracing = frameTrace.active\n    if tracing then frameTrace.begin() end\n    local dt = 0\n    if lovr.headset then lovr.headset.update() end\n    if tracing then frameTrace.sync() end",
        ),
        (
            "    if lovr.update then lovr.update(dt) end",
            "    if lovr.update then\n      if tracing then frameTrace.before() end\n      lovr.update(dt)\n      if tracing then frameTrace.mark('heapUpdate', 'update') end\n    end",
        ),
        (
            "      local window = lovr.graphics.getWindowPass()",
            "      if tracing then frameTrace.before() end\n      local window = lovr.graphics.getWindowPass()",
        ),
        (
            "        if headset or window then lovr.graphics.submit(headset, window) end\n        lovr.headset.submit()",
            "        if tracing then frameTrace.mark('heapDraw', 'draw') end\n        if headset or window then\n          lovr.graphics.submit(headset, window)\n          if tracing then frameTrace.mark('heapGraphicsSubmit', 'graphicsSubmit') end\n        end\n        lovr.headset.submit()\n        if tracing then frameTrace.mark('heapHeadsetSubmit', 'headsetSubmit') end",
        ),
        (
            "      elseif window and (not lovr.draw or not lovr.draw(window)) then\n        lovr.graphics.submit(window)\n      end\n      lovr.graphics.present()",
            "      else\n        local skip = window and lovr.draw and lovr.draw(window)\n        if tracing then frameTrace.mark('heapDraw', 'draw') end\n        if window and not skip then\n          lovr.graphics.submit(window)\n          if tracing then frameTrace.mark('heapGraphicsSubmit', 'graphicsSubmit') end\n        end\n      end\n      if tracing then frameTrace.before() end\n      lovr.graphics.present()\n      if tracing then frameTrace.mark('heapPresent', 'present') end",
        ),
        (
            "    elseif lovr.headset then\n      lovr.headset.submit()",
            "    elseif lovr.headset then\n      if tracing then frameTrace.before() end\n      lovr.headset.submit()\n      if tracing then frameTrace.mark('heapHeadsetSubmit', 'headsetSubmit') end",
        ),
    ];
    for (old, new) in replacements {
        if source.matches(old).count() != 1 {
            return Err(format!(
                "frame timing: boot instrumentation anchor changed: {old}"
            ));
        }
        source = source.replacen(old, new, 1);
    }
    Ok(source)
}
