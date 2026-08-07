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

/// Where the shipped configuration is, in the working tree this test was built
/// from.
fn configuration_directory() -> PathBuf {
    // `crates/lunette` up two levels to the workspace root.
    let Some(root) = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2) else {
        panic!("the workspace root could not be derived from the manifest directory");
    };
    root.join("etc").join("xdg").join("lunette")
}
