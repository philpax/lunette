//! Generated LÖVR declarations describe the public tables exported by the linked runtime.

use std::{collections::BTreeSet, error::Error, mem::ManuallyDrop};

use lunette_lovr::{BOOT_LUA, analyze::surface, raw};
use mlua::{Lua, Table, Value, ffi};
use pretty_assertions::assert_eq;

type TestResult = Result<(), Box<dyn Error>>;

#[test]
fn definitions_match_the_linked_runtime() -> TestResult {
    let declarations = surface(include_str!("../../../etc/lunette/definitions.luau"))?;
    for math_globals in [true, false] {
        compare_runtime(math_globals, &declarations)?;
    }
    Ok(())
}

fn compare_runtime(math_globals: bool, declarations: &[surface::Member]) -> TestResult {
    let state = Runtime::new();
    let lua = &state.lua;
    let mut baseline = public_keys(&lua.globals())?;
    // These native types belong to the LÖVR surface even though luaL_openlibs installs their globals.
    baseline.remove("vector");
    baseline.remove("quaternion");
    let package: Table = lua.globals().get("package")?;
    let preload: Table = package.get("preload")?;
    assert!(
        matches!(preload.raw_get::<Value>("lovr.audio")?, Value::Function(_)),
        "the linked runtime must register its audio loader"
    );
    // The native opener initializes miniaudio even with audio.start=false. This registers the same functions without it.
    // SAFETY: the callback follows the Lua C function protocol and registers only the linked runtime's immutable table.
    let audio = unsafe { lua.create_c_function(register_audio)? };
    preload.set("lovr.audio", audio)?;
    // Defining boot callbacks does not run the returned coroutine or start the session.
    let _: mlua::Thread = lua.load(BOOT_LUA).set_name("@boot.lua").eval()?;
    lua.globals().set("mathGlobals", math_globals)?;
    lua.load(
        r#"
        lovr = require('lovr')
        lovr._setConf({
          audio = { start = false },
          headset = { connect = false },
          math = { globals = mathGlobals },
          thread = { workers = 0 }
        })
        for name in pairs(package.preload) do
          if string.sub(name, 1, 5) == 'lovr.' then
            lovr[string.sub(name, 6)] = require(name)
          end
        end
        "#,
    )
    .exec()?;

    lua.globals().raw_set("mathGlobals", Value::Nil)?;
    let mut roots = public_keys(&lua.globals())?
        .difference(&baseline)
        .cloned()
        .collect::<BTreeSet<_>>();
    roots.extend(declarations.iter().map(|entry| entry.path[0].clone()));
    let failures = mismatches(&lua.globals(), &roots, declarations)?;
    assert!(
        failures.is_empty(),
        "runtime definition mismatches (math.globals={math_globals}):\n{}",
        failures.join("\n")
    );

    if math_globals {
        let without_run = declarations
            .iter()
            .filter(|entry| entry.path != ["lovr", "run"])
            .cloned()
            .collect::<Vec<_>>();
        assert!(
            mismatches(&lua.globals(), &roots, &without_run)?
                .contains(&"undeclared runtime member: lovr.run".to_owned())
        );
        let lovr: Table = lua.globals().raw_get("lovr")?;
        let saved: Value = lovr.raw_get("getVersion")?;
        lovr.raw_set("getVersion", Value::Nil)?;
        let removed = mismatches(&lua.globals(), &roots, declarations)?;
        lovr.raw_set("getVersion", saved)?;
        assert!(removed.contains(&"absent runtime member: lovr.getVersion".to_owned()));
    }
    Ok(())
}

#[test]
fn an_undeclared_runtime_member_is_reported() -> TestResult {
    let lua = Lua::new();
    let globals: Table = lua
        .load("return { lovr = { nested = { added = function() end } } }")
        .eval()?;
    let declarations = surface("declare lovr: { nested: {} }")?;
    assert_eq!(
        mismatches(
            &globals,
            &BTreeSet::from(["lovr".to_owned()]),
            &declarations
        )?,
        vec!["undeclared runtime member: lovr.nested.added"]
    );
    Ok(())
}

#[test]
fn an_absent_declared_global_is_reported() -> TestResult {
    let lua = Lua::new();
    let declarations = surface("declare io: { write: (string) -> () }")?;
    let failures = mismatches(
        &lua.globals(),
        &BTreeSet::from(["io".to_owned()]),
        &declarations,
    )?;
    assert!(
        failures.contains(&"absent runtime member: io".to_owned()),
        "{failures:?}"
    );
    Ok(())
}

#[test]
fn an_absent_nested_member_is_reported_but_optional_callbacks_are_not() -> TestResult {
    let lua = Lua::new();
    let globals: Table = lua.load("return { lovr = { math = {} } }").eval()?;
    let declarations = surface(
        "type Module = { missing: () -> () }\ndeclare lovr: { math: Module, draw: ((number) -> ())? }",
    )?;
    assert_eq!(
        mismatches(
            &globals,
            &BTreeSet::from(["lovr".to_owned()]),
            &declarations
        )?,
        vec!["absent runtime member: lovr.math.missing"]
    );
    Ok(())
}

#[test]
fn optional_tables_require_their_members_when_present() -> TestResult {
    let lua = Lua::new();
    let declarations = surface("declare lovr: { module: { required: number }? }")?;
    let roots = BTreeSet::from(["lovr".to_owned()]);
    let absent: Table = lua.load("return { lovr = {} }").eval()?;
    assert!(mismatches(&absent, &roots, &declarations)?.is_empty());
    let present: Table = lua.load("return { lovr = { module = {} } }").eval()?;
    assert_eq!(
        mismatches(&present, &roots, &declarations)?,
        vec!["absent runtime member: lovr.module.required"]
    );
    Ok(())
}

#[test]
fn aliases_are_walked_at_every_public_path() -> TestResult {
    let lua = Lua::new();
    let globals: Table = lua
        .load("local t = { member = true } return { first = t, second = t }")
        .eval()?;
    let declarations =
        surface("type Module = { member: boolean } declare first: Module declare second: Module")?;
    assert!(
        mismatches(
            &globals,
            &BTreeSet::from(["first".to_owned(), "second".to_owned()]),
            &declarations
        )?
        .is_empty()
    );
    Ok(())
}

#[test]
fn a_non_string_runtime_key_fails_instead_of_being_coerced() -> TestResult {
    let lua = Lua::new();
    let globals: Table = lua.load("return { lovr = { [1] = true } }").eval()?;
    let declarations = surface("declare lovr: {}")?;
    assert!(
        mismatches(
            &globals,
            &BTreeSet::from(["lovr".to_owned()]),
            &declarations
        )
        .is_err()
    );
    Ok(())
}

#[test]
fn finite_declared_paths_through_a_cycle_are_checked() -> TestResult {
    let lua = Lua::new();
    let globals: Table = lua
        .load("local t = { member = true } t.self = t return { root = t }")
        .eval()?;
    let roots = BTreeSet::from(["root".to_owned()]);
    let declarations =
        surface("declare root: { member: boolean, self: { member: boolean, absent: number } }")?;
    assert_eq!(
        mismatches(&globals, &roots, &declarations)?,
        vec!["absent runtime member: root.self.absent"]
    );
    Ok(())
}

#[test]
fn string_indexers_declare_dynamic_functions_but_not_nested_tables() -> TestResult {
    let lua = Lua::new();
    let declarations = surface("declare handlers: { [string]: ((...any) -> ...any)? }")?;
    let roots = BTreeSet::from(["handlers".to_owned()]);
    let functions: Table = lua
        .load("return { handlers = { event = function() end } }")
        .eval()?;
    assert!(mismatches(&functions, &roots, &declarations)?.is_empty());
    let invalid: Table = lua.load("return { handlers = { event = {} } }").eval()?;
    assert_eq!(
        mismatches(&invalid, &roots, &declarations)?,
        vec!["non-function indexed runtime member: handlers.event"]
    );
    Ok(())
}

#[test]
fn indexed_tables_validate_named_members_and_paths_through_cycles() -> TestResult {
    let lua = Lua::new();
    let declarations =
        surface("declare root: { value: number, self: { [string]: ((...any) -> ...any)? } }")?;
    let cyclic: Table = lua
        .load("local t = { value = 1 } t.self = t return { root = t }")
        .eval()?;
    assert_eq!(
        mismatches(&cyclic, &BTreeSet::from(["root".to_owned()]), &declarations)?,
        vec![
            "non-function indexed runtime member: root.self.self",
            "non-function indexed runtime member: root.self.value"
        ]
    );
    let declarations =
        surface("declare handlers: { event: () -> (), [string]: ((...any) -> ...any)? }")?;
    let named: Table = lua.load("return { handlers = { event = {} } }").eval()?;
    assert_eq!(
        mismatches(
            &named,
            &BTreeSet::from(["handlers".to_owned()]),
            &declarations
        )?,
        vec!["non-function indexed runtime member: handlers.event"]
    );
    Ok(())
}

#[test]
fn implementation_fields_and_cycles_do_not_hide_public_members() -> TestResult {
    let lua = Lua::new();
    let globals: Table = lua
        .load("local t = { _private = {} } t.self = t t.extra = true return { lovr = t }")
        .eval()?;
    let declarations = surface("declare lovr: { self: {} }")?;
    assert_eq!(
        mismatches(
            &globals,
            &BTreeSet::from(["lovr".to_owned()]),
            &declarations
        )?,
        vec!["undeclared runtime member: lovr.extra"]
    );
    Ok(())
}

fn mismatches(
    globals: &Table,
    roots: &BTreeSet<String>,
    declarations: &[surface::Member],
) -> mlua::Result<Vec<String>> {
    let declared = declarations
        .iter()
        .map(|entry| entry.path.clone())
        .collect::<BTreeSet<_>>();
    let mut live = BTreeSet::new();
    for root in roots {
        let value: Value = globals.raw_get(root.as_str())?;
        walk(value, vec![root.clone()], &mut Vec::new(), &mut live)?;
    }
    let mut failures = Vec::new();
    for path in live.difference(&declared) {
        let indexed = declarations.iter().any(|entry| {
            entry.string_indexed
                && path.len() == entry.path.len() + 1
                && path.starts_with(&entry.path)
        });
        if !indexed {
            failures.push(format!("undeclared runtime member: {}", path.join(".")));
        }
    }
    for entry in declarations {
        if entry.string_indexed
            && let Value::Table(table) = lookup(globals, &entry.path)?
        {
            for key in public_keys(&table)? {
                if !matches!(table.raw_get::<Value>(key.as_str())?, Value::Function(_)) {
                    let mut path = entry.path.clone();
                    path.push(key);
                    failures.push(format!(
                        "non-function indexed runtime member: {}",
                        path.join(".")
                    ));
                }
            }
        }
        let mut absent_optional_ancestor = false;
        for ancestor in declarations {
            if ancestor.optional
                && entry.path.starts_with(&ancestor.path)
                && lookup(globals, &ancestor.path)?.is_nil()
            {
                absent_optional_ancestor = true;
                break;
            }
        }
        if !entry.optional && !absent_optional_ancestor && lookup(globals, &entry.path)?.is_nil() {
            failures.push(format!("absent runtime member: {}", entry.path.join(".")));
        }
    }
    failures.sort();
    Ok(failures)
}

fn lookup(globals: &Table, path: &[String]) -> mlua::Result<Value> {
    let mut value = Value::Table(globals.clone());
    for key in path {
        let Value::Table(table) = value else {
            return Ok(Value::Nil);
        };
        value = table.raw_get(key.as_str())?;
    }
    Ok(value)
}

fn walk(
    value: Value,
    path: Vec<String>,
    ancestors: &mut Vec<*const std::ffi::c_void>,
    live: &mut BTreeSet<Vec<String>>,
) -> mlua::Result<()> {
    if value.is_nil() {
        return Ok(());
    }
    live.insert(path.clone());
    if let Value::Table(table) = value {
        let pointer = table.to_pointer();
        if ancestors.contains(&pointer) {
            return Ok(());
        }
        ancestors.push(pointer);
        for key in public_keys(&table)? {
            let mut child = path.clone();
            child.push(key.clone());
            walk(table.raw_get(key.as_str())?, child, ancestors, live)?;
        }
        ancestors.pop();
    }
    Ok(())
}

fn public_keys(table: &Table) -> mlua::Result<BTreeSet<String>> {
    let mut keys = BTreeSet::new();
    for pair in table.clone().pairs::<Value, Value>() {
        let (key, _) = pair?;
        let Value::String(key) = key else {
            return Err(mlua::Error::external(
                "runtime definition surface: a public table has a non-string key",
            ));
        };
        let key = key.to_str()?.to_owned();
        if !key.starts_with('_') {
            keys.insert(key);
        }
    }
    Ok(keys)
}

unsafe extern "C-unwind" fn register_audio(state: *mut ffi::lua_State) -> std::ffi::c_int {
    // SAFETY: Lua supplies a live state, and lovrAudio is the sentinel-terminated array used by luaopen_lovr_audio.
    // No registered function is called, and no audio userdata or finalizer is created.
    unsafe {
        ffi::lua_newtable(state);
        ffi::luaL_register(state, std::ptr::null(), &raw const lovrAudio);
    }
    1
}

unsafe extern "C" {
    // The C symbol is an array. Its first element gives luaL_register the sentinel-terminated sequence.
    static lovrAudio: ffi::luaL_Reg;
}

struct Runtime {
    lua: ManuallyDrop<Lua>,
}

impl Runtime {
    fn new() -> Self {
        let lua = Lua::new();
        lua.exec_raw_lua(|lua| {
            // SAFETY: this is the unique state owner, and the boot sequence uses these same calls.
            unsafe {
                raw::luax_setmainthread(lua.state().cast());
                ffi::luaL_openlibs(lua.state());
                raw::luax_preload(lua.state().cast());
            }
        });
        Self {
            lua: ManuallyDrop::new(lua),
        }
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        let state = self.lua.exec_raw_lua(|lua| {
            lua.mark_closed();
            lua.state()
        });
        // SAFETY: no Lua call is executing, and this owner closes the state once, including LÖVR finalizers.
        // The mlua allocation owner is forgotten, as in the session boot path, because its destructor accesses the closed state.
        unsafe { raw::luax_close(state.cast()) };
    }
}
