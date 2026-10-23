use mlua::{Lua, Value};

use super::*;

fn protected() -> Lua {
    let lua = Lua::new();
    protect(&lua).expect("a fresh state is protected");
    lua
}

fn error(lua: &Lua, source: &str) -> String {
    lua.load(source)
        .exec()
        .expect_err("the chunk raises")
        .to_string()
}

#[test]
fn builtins_keep_working_through_the_protected_globals() {
    let lua = protected();
    let (minimum, kind, packed, count): (f64, String, f64, usize) = lua
        .load(
            "local t = {} for key, value in pairs({ a = 1, b = 2 }) do t[key] = value end \
             return math.min(3, 2), type(t), buffer.readf32(buffer.create(4), 0), select('#', 1, 2, 3)",
        )
        .eval()
        .expect("builtins run");
    assert_eq!(
        (minimum, kind.as_str(), packed, count),
        (2.0, "table", 0.0, 3)
    );
}

#[test]
fn library_tables_are_read_only() {
    let lua = protected();
    for source in [
        "math.min = function() return 0 end",
        "string.custom = 1",
        "table.insert = nil",
        "os.date = function() return '' end",
    ] {
        let message = error(&lua, source);
        assert!(message.contains("readonly"), "{source}: {message}");
    }
}

#[test]
fn rebinding_a_protected_global_raises_an_error_that_names_it() {
    let lua = protected();
    for (name, source) in [
        ("math", "math = {}"),
        ("type", "type = function() return 'number' end"),
        ("pairs", "pairs = next"),
    ] {
        let message = error(&lua, source);
        assert!(
            message.contains(&format!(
                "standard library global {name} cannot be replaced"
            )),
            "{source}: {message}"
        );
    }
    let kind: String = lua.load("return type(1)").eval().expect("type still runs");
    assert_eq!(kind, "number");
}

#[test]
fn other_globals_and_their_tables_stay_writable() {
    let lua = protected();
    let (first, second, field): (i64, i64, i64) = lua
        .load(
            "counter = 1 counter = counter + 1 lovr = { update = 1 } lovr.update = 3 \
             return counter, rawget(_G, 'counter'), lovr.update",
        )
        .eval()
        .expect("ordinary globals are writable");
    assert_eq!((first, second, field), (2, 2, 3));
}

#[test]
fn imports_see_tables_rebound_after_the_chunk_loaded() {
    let lua = protected();
    lua.load("settings = { value = 1 }")
        .exec()
        .expect("the global is defined");
    let read = lua
        .load("return settings.value")
        .into_function()
        .expect("the import loads");
    lua.load("settings = { value = 2 }")
        .exec()
        .expect("the global is rebound");
    assert_eq!(read.call::<i64>(()).expect("the import runs"), 2);
}

#[test]
fn builtin_names_that_were_absent_are_not_reserved() {
    let lua = Lua::new();
    lua.globals()
        .raw_set("unpack", Value::Nil)
        .expect("the name is cleared");
    protect(&lua).expect("the state is protected");
    lua.load("unpack = function() return 'mine' end")
        .exec()
        .expect("an absent builtin name stays free");
}

#[test]
fn a_global_table_with_a_metatable_is_left_alone() {
    let lua = Lua::new();
    lua.globals()
        .set_metatable(Some(lua.create_table().expect("a metatable")))
        .expect("the metatable is set");
    let message = protect(&lua)
        .expect_err("protection refuses an existing metatable")
        .to_string();
    assert!(message.contains("already has a metatable"), "{message}");
}
