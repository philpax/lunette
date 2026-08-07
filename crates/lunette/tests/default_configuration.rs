//! Linux-only: the shipped default configuration compiles under the LuaJIT the
//! session runs it on.
//!
//! `etc/xdg/lunette/` is what a user with no configuration of their own gets, so
//! a syntax error in it reaches every fresh installation as a failed boot. It is
//! data rather than code as far as Cargo is concerned, and nothing else in the
//! workspace would look at it.
//!
//! This compiles the two files and no more. Running them needs a compositor, a
//! graphics device, and a headset, so what they do is a human gate; what is
//! checked here is that they parse, that they parse under LuaJIT rather than
//! under some other Lua, and that the callbacks the session calls are the ones
//! they define.

use std::{
    fs,
    path::{Path, PathBuf},
};

// Unused as a name, and load-bearing as a link. The LuaJIT this compiles under
// is the one `lunette-lovr` builds, and rustc emits its link flags only for a
// crate the binary actually depends on — so a test that never named `lunette`
// would link no Lua at all and fail with undefined symbols rather than with a
// verdict.
use lunette as _;
use mlua::{Function, Lua, Table};

/// The callbacks `main.lua` is expected to leave on `lovr`.
///
/// Named rather than counted: a configuration that stopped drawing would still
/// define some callbacks, and the gate this stands in for is that a terminal
/// appears and can be pointed at.
const CALLBACKS: &[&str] = &[
    "load",
    "update",
    "draw",
    "quit",
    "keypressed",
    "lunwindowopened",
    "lunwindowclosed",
    "lunprocessexited",
];

#[test]
fn the_default_configuration_compiles() {
    let lua = Lua::new();

    for name in ["main.lua", "conf.lua"] {
        let path = configuration_directory().join(name);
        let source = match fs::read_to_string(&path) {
            Ok(source) => source,
            Err(error) => panic!("{} could not be read: {error}", path.display()),
        };

        if let Err(error) = lua.load(&source).set_name(name).into_function() {
            panic!("{} did not compile: {error}", path.display());
        }
    }
}

/// The chunk defines the callbacks the session calls, and defines them on
/// `lovr`.
///
/// It runs against a `lovr` and a `require` that answer with empty tables, so
/// nothing past the assignments themselves is exercised: the module bodies are
/// never reached and no compositor is spoken to. A callback the configuration
/// stopped defining is the defect this catches.
#[test]
fn the_default_configuration_defines_the_callbacks_the_session_calls() {
    let lua = Lua::new();
    let path = configuration_directory().join("main.lua");
    let source = match fs::read_to_string(&path) {
        Ok(source) => source,
        Err(error) => panic!("{} could not be read: {error}", path.display()),
    };

    let lovr = match stub_environment(&lua) {
        Ok(lovr) => lovr,
        Err(error) => panic!("the stub environment could not be built: {error}"),
    };

    if let Err(error) = lua.load(&source).set_name("main.lua").exec() {
        panic!("{} did not run against the stubs: {error}", path.display());
    }

    for name in CALLBACKS {
        let defined: Option<Function> = match lovr.get(*name) {
            Ok(defined) => defined,
            Err(error) => panic!("lovr.{name} could not be read: {error}"),
        };
        assert!(
            defined.is_some(),
            "the configuration should define lovr.{name}"
        );
    }
}

/// `lovr.load` runs against the real standard library.
///
/// The stub run above deliberately reaches no module body, which leaves the one
/// place every `mullion` call in this configuration lives — `lovr.load` — with
/// no coverage at all. A configuration that passed the wrong kind of value to a
/// module would compile, define its callbacks, and raise on the first frame of
/// every fresh installation, which is the exact case safe mode exists for.
///
/// So this one resolves `require` through the repository's `lua/` tree and runs
/// the callback. The only fakes are the two things a module reaches the outside
/// world through: `lunette`, whose real seat and spawn calls want a compositor,
/// and `lovr`, whose filesystem here holds no saved arrangement. Everything
/// between them is the code a session runs.
#[test]
fn the_default_configuration_loads_against_the_standard_library() {
    let lua = Lua::new();
    let path = configuration_directory().join("main.lua");
    let source = match fs::read_to_string(&path) {
        Ok(source) => source,
        Err(error) => panic!("{} could not be read: {error}", path.display()),
    };

    let lovr = match session_environment(&lua) {
        Ok(lovr) => lovr,
        Err(error) => panic!("the session environment could not be built: {error}"),
    };

    if let Err(error) = lua.load(&source).set_name("main.lua").exec() {
        panic!("{} did not run: {error}", path.display());
    }

    let load: Function = match lovr.get("load") {
        Ok(load) => load,
        Err(error) => panic!("lovr.load could not be read: {error}"),
    };
    if let Err(error) = load.call::<()>(()) {
        panic!("lovr.load raised: {error}");
    }

    // The arrangement source is what `lovr.load` had to reach `mullion.persist`
    // to register, so its absence would mean the callback ran and did nothing.
    let registered: bool = match lua
        .load("local rules = require 'mullion.rules'\nfor _, source in ipairs(rules.sources()) do\n  if source.name == 'mullion.persist' then return true end\nend\nreturn false")
        .eval()
    {
        Ok(registered) => registered,
        Err(error) => panic!("the registered sources could not be read: {error}"),
    };
    assert!(
        registered,
        "lovr.load should register the saved arrangement as a rules source"
    );

    // The store source is the other half, and the one AC5.4 rests on: without
    // it a reload places every surviving window by rule and a hand-arranged
    // workspace comes back scrambled.
    let sources: Vec<String> = match lua
        .load(
            "local rules = require 'mullion.rules'\nlocal names = {}\nfor _, source in \
             ipairs(rules.sources()) do names[#names + 1] = source.name end\nreturn names",
        )
        .eval::<Vec<String>>()
    {
        Ok(sources) => sources,
        Err(error) => panic!("the registered sources could not be read: {error}"),
    };
    assert_eq!(
        sources,
        vec![
            "mullion.rules".to_owned(),
            "mullion.persist".to_owned(),
            "mullion.adopt".to_owned(),
        ],
        "the sources should compose from the rules table up to the live property store"
    );
}

/// A `lovr` global and a `require` that answer with fresh empty tables.
///
/// Every field read of one of those tables answers `nil`, which is enough for a
/// chunk whose top level only requires modules and assigns callbacks. A chunk
/// that started calling into a module at load time would fail here, and that is
/// the right report: doing so at load time is what this configuration must not
/// do, because the graphics module and the compositor do not exist yet.
fn stub_environment(lua: &Lua) -> mlua::Result<Table> {
    let lovr = lua.create_table()?;
    lua.globals().set("lovr", &lovr)?;
    lua.globals().set(
        "require",
        lua.create_function(|lua, _: String| lua.create_table())?,
    )?;
    Ok(lovr)
}

/// A `lovr` global and a `require` that resolve the real standard library.
///
/// `require` is left alone and `package.path` is pointed at the repository's
/// `lua/` tree instead, so the modules that load are the installed ones. Two
/// fakes stand in for the outside world, and nothing else is stubbed:
///
/// - `lunette`, whose `newSeat` and `spawn` want a compositor. A seat that
///   answered nothing would be a laser holding nil, so the fake answers the
///   shape the real one does.
/// - `lovr`, whose `filesystem` holds no saved arrangement, which is what a
///   fresh installation has.
fn session_environment(lua: &Lua) -> mlua::Result<Table> {
    let package: Table = lua.globals().get("package")?;
    let root = standard_library();
    package.set(
        "path",
        format!("{root}/?.lua;{root}/?/init.lua", root = root.display()),
    )?;

    let lunette = lua.create_table()?;
    lunette.set(
        "newSeat",
        lua.create_function(|lua, _: mlua::MultiValue| {
            let seat = lua.create_table()?;
            seat.set("dead", false)?;
            seat.set(
                "setFocus",
                lua.create_function(|_, _: mlua::MultiValue| Ok(true))?,
            )?;
            seat.set(
                "destroy",
                lua.create_function(|_, _: mlua::MultiValue| Ok(true))?,
            )?;
            Ok(seat)
        })?,
    )?;
    lunette.set(
        "spawn",
        lua.create_function(|lua, _: mlua::MultiValue| {
            let process = lua.create_table()?;
            process.set("id", 1)?;
            Ok(process)
        })?,
    )?;
    // Empty, which is what a session that has just started has: the adoption
    // this drives is for the windows a *reload* found already open.
    lunette.set(
        "windows",
        lua.create_function(|lua, ()| lua.create_table())?,
    )?;
    let loaded: Table = package.get("loaded")?;
    loaded.set("lunette", lunette)?;

    let filesystem = lua.create_table()?;
    filesystem.set(
        "read",
        lua.create_function(|_, _: mlua::MultiValue| Ok(mlua::Value::Nil))?,
    )?;
    filesystem.set(
        "getSaveDirectory",
        lua.create_function(|_, ()| Ok("/a/save/directory"))?,
    )?;
    let lovr = lua.create_table()?;
    lovr.set("filesystem", filesystem)?;
    lua.globals().set("lovr", &lovr)?;
    Ok(lovr)
}

/// Where the shipped configuration is, in the working tree this test was built
/// from.
fn configuration_directory() -> PathBuf {
    workspace_root().join("etc").join("xdg").join("lunette")
}

/// Where the `mullion` standard library is, in the same tree.
fn standard_library() -> PathBuf {
    workspace_root().join("lua")
}

fn workspace_root() -> PathBuf {
    // `crates/lunette` up two levels to the workspace root.
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    root.to_path_buf()
}
