//! A reference dropped after an external `lua_close` does not touch the closed state.

// The Luau C API comes from `liblovr.so`, which this crate's link directives name.
extern crate lunette_lovr;

use std::{cell::Cell, mem::ManuallyDrop, rc::Rc};

use mlua::{Function, Lua, UserData};

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
