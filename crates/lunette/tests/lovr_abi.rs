//! The mlua and LÖVR forks agree on the ABI that `liblovr.so` exports.
//!
//! mlua-sys's mirror of `lua_CompileOptions` must match the Luau the library exports. A missing
//! field shifts every later one without a link or type error, so each compile-option case checks
//! that one option changes the bytecode.
//!
//! A reference dropped after an external `lua_close` must not touch the closed state.
//!
//! Native key-event snapshots must survive LÖVR's Lua event binding. Native injection replaces
//! the host keyboard boundary, so OS modifier acquisition is not checked. The event queue is
//! process-global, and only the key-event case touches it.

use std::{cell::Cell, ffi::c_int, mem::ManuallyDrop, rc::Rc};

use lunette_lovr::raw::{
    Event, EventData, EventType, EventType_EVENT_KEYPRESSED, EventType_EVENT_KEYRELEASED, KeyEvent,
    lovrEventPush, luax_close, os_key_modifiers,
};
use mlua::{Function, Lua, MultiValue, Table, UserData, Value, chunk::Compiler, ffi::lua_State};
use pretty_assertions::assert_eq;

unsafe extern "C-unwind" {
    fn luaopen_lovr_event(state: *mut lua_State) -> c_int;
}

#[test]
fn a_mutable_global_disables_the_import_of_its_fields() -> mlua::Result<()> {
    let source = "return g.x";
    let imported = Compiler::new().compile(source)?;
    let looked_up = Compiler::new().add_mutable_global("g").compile(source)?;
    assert_ne!(imported, looked_up);
    Ok(())
}

#[test]
fn a_disabled_builtin_is_not_compiled_into_a_fastcall() -> mlua::Result<()> {
    let source = "local n = ... return math.abs(n)";
    let fastcall = Compiler::new().compile(source)?;
    let call = Compiler::new()
        .add_disabled_builtin("math.abs")
        .compile(source)?;
    assert_ne!(fastcall, call);
    Ok(())
}

/// The boot path closes the Lua state externally, so a reference the host holds is
/// dropped after the state is gone. The mlua fork's closed-state guard makes that drop inert.
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
    drop(callback);
    Ok(())
}

struct ExternalState {
    lua: ManuallyDrop<Lua>,
    raw: *mut lua_State,
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
        self.lua.exec_raw_lua(|raw| raw.mark_closed());
        // SAFETY: this is the unique owner, and no callback is executing.
        unsafe { mlua::ffi::lua_close(self.raw) };
    }
}

/// A userdata that records when Lua collects it.
struct DropWitness(Rc<Cell<bool>>);

impl UserData for DropWitness {}

impl Drop for DropWitness {
    fn drop(&mut self) {
        self.0.set(true);
    }
}

#[test]
fn key_events_preserve_arguments_and_frozen_modifier_snapshots() -> mlua::Result<()> {
    // The queue is process-global, so all cases share one opener.
    let state = EventState::new();
    let lua: &Lua = &state.lua;
    // SAFETY: the opener follows the Lua C function protocol, and both callers
    // use the Luau ABI exported by liblovr.so.
    let open = unsafe { lua.create_c_function(luaopen_lovr_event)? };
    let event: Table = open.call(())?;
    let poll: Function = event.get("poll")?;
    let next: Function = poll.call(())?;
    assert!(
        next.call::<MultiValue>(())?.is_empty(),
        "the queue starts empty"
    );

    let assert_frozen: Function = lua
        .load(
            r#"
            return function(modifiers)
              assert(table.isfrozen(modifiers), 'modifiers are frozen')
              assert(not pcall(function() modifiers.shift = true end), 'modifiers reject assignment')
            end
            "#,
        )
        .eval()?;

    // Between the two modified events each field is seen both true and false.
    let cases = [
        KeyCase {
            kind: KeyKind::Pressed,
            scancode: 1,
            repeat: true,
            modifiers: modifiers(0b10_1010),
            has_modifiers: true,
        },
        KeyCase {
            kind: KeyKind::Released,
            scancode: 2,
            repeat: false,
            modifiers: modifiers(0b01_0101),
            has_modifiers: true,
        },
        KeyCase {
            kind: KeyKind::Pressed,
            scancode: 3,
            repeat: false,
            modifiers: modifiers(0),
            has_modifiers: false,
        },
        KeyCase {
            kind: KeyKind::Released,
            scancode: 4,
            repeat: false,
            modifiers: modifiers(0),
            has_modifiers: false,
        },
    ];
    for case in &cases {
        push_key(*case);
    }

    for case in cases {
        let values: MultiValue = next.call(())?;
        let modifiers_index = match case.kind {
            KeyKind::Pressed => {
                assert_eq!(values.len(), 5, "pressed arguments: {case:?}");
                assert_eq!(
                    values.get(3),
                    Some(&Value::Boolean(case.repeat)),
                    "{case:?}"
                );
                4
            }
            KeyKind::Released => {
                assert_eq!(values.len(), 4, "released arguments: {case:?}");
                3
            }
        };
        assert_string(&values[0], case.kind.name())?;
        assert_string(&values[1], "a")?;
        assert_eq!(values[2], Value::Integer(case.scancode.into()), "{case:?}");

        match (case.has_modifiers, &values[modifiers_index]) {
            (true, Value::Table(table)) => {
                assert_modifiers(table, case.modifiers)?;
                assert_frozen.call::<()>(table.clone())?;
            }
            (false, Value::Nil) => {}
            (_, actual) => {
                panic!("key events: {case:?} received unexpected modifiers {actual:?}");
            }
        }
    }
    assert!(
        next.call::<MultiValue>(())?.is_empty(),
        "the queue is drained"
    );
    Ok(())
}

struct EventState {
    lua: ManuallyDrop<Lua>,
    raw: *mut lua_State,
}

impl EventState {
    fn new() -> Self {
        let lua = Lua::new();
        let raw = lua.exec_raw_lua(|raw| raw.state());
        Self {
            lua: ManuallyDrop::new(lua),
            raw,
        }
    }
}

impl Drop for EventState {
    fn drop(&mut self) {
        self.lua.exec_raw_lua(|raw| raw.mark_closed());
        // SAFETY: all functions and tables drop before this unique state owner, and luax_close releases the event module.
        unsafe { luax_close(self.raw.cast()) };
    }
}

#[derive(Clone, Copy, Debug)]
enum KeyKind {
    Pressed,
    Released,
}

impl KeyKind {
    fn native(self) -> EventType {
        match self {
            Self::Pressed => EventType_EVENT_KEYPRESSED,
            Self::Released => EventType_EVENT_KEYRELEASED,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Pressed => "keypressed",
            Self::Released => "keyreleased",
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct KeyCase {
    kind: KeyKind,
    scancode: u32,
    repeat: bool,
    modifiers: os_key_modifiers,
    has_modifiers: bool,
}

fn modifiers(bits: u8) -> os_key_modifiers {
    os_key_modifiers {
        shift: bits & 1 != 0,
        control: bits & 2 != 0,
        alt: bits & 4 != 0,
        super_: bits & 8 != 0,
        capsLock: bits & 16 != 0,
        numLock: bits & 32 != 0,
    }
}

fn push_key(case: KeyCase) {
    let event = Event {
        type_: case.kind.native(),
        data: EventData {
            key: KeyEvent {
                // OS_KEY_A is the first os_key enum variant, not an evdev code.
                code: 0,
                scancode: case.scancode,
                repeat: case.repeat,
                modifiers: case.modifiers,
                hasModifiers: case.has_modifiers,
            },
        },
    };
    // SAFETY: the opener initialized the queue, the tag matches the union member, and lovrEventPush copies the event.
    unsafe { lovrEventPush(event) };
}

fn assert_string(value: &Value, expected: &str) -> mlua::Result<()> {
    let Value::String(string) = value else {
        panic!("key events: expected string {expected:?}, received {value:?}");
    };
    assert_eq!(string.to_str()?.as_ref(), expected);
    Ok(())
}

fn assert_modifiers(table: &Table, expected: os_key_modifiers) -> mlua::Result<()> {
    let fields = [
        ("shift", expected.shift),
        ("control", expected.control),
        ("alt", expected.alt),
        ("super", expected.super_),
        ("capsLock", expected.capsLock),
        ("numLock", expected.numLock),
    ];
    let entries = table
        .clone()
        .pairs::<String, Value>()
        .collect::<mlua::Result<Vec<_>>>()?;
    assert_eq!(
        entries.len(),
        fields.len(),
        "the snapshot has exactly six fields"
    );
    for (field, value) in fields {
        assert_eq!(
            table.get::<Value>(field)?,
            Value::Boolean(value),
            "modifier {field}"
        );
    }
    Ok(())
}
