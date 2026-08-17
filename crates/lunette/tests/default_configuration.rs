//! Linux-only: the shipped default configuration compiles under the Luau the
//! session runs it on.
//!
//! `etc/xdg/lunette/` is what a user with no configuration of their own gets, so
//! a syntax error in it reaches every fresh installation as a failed boot. It is
//! data rather than code as far as Cargo is concerned, and nothing else in the
//! workspace would look at it.
//!
//! This compiles the two files and no more. Running them needs a compositor, a
//! graphics device, and a headset, so what they do is a human gate; what is
//! checked here is that they parse, that they parse under Luau rather than
//! under some other Lua, and that the callbacks the session calls are the ones
//! they define.

use std::{
    fs,
    path::{Path, PathBuf},
};

// Unused as a name, and load-bearing as a link. The Lua this compiles under is
// the one `lunette-lovr` builds, and rustc emits its link flags only for a
// crate the binary actually depends on — so a test that never named `lunette`
// would link no Lua at all and fail with undefined symbols rather than with a
// verdict.
use lunette as _;
use lunette_compositor::protocol::KeyModifier;

/// An mlua state with LÖVR's fork library set opened on it, the way the real
/// session state has it (the session handlers and `mullion` read `package`).
fn session_lua() -> mlua::Lua {
    let lua = mlua::Lua::new();
    // SAFETY: the state is not mid-call; opening libraries is what production
    // does before any chunk runs.
    unsafe {
        lua.exec_raw_lua(|raw| mlua::ffi::luaL_openlibs(raw.state()));
    }
    lua
}
use mlua::{Function, Lua, Table};

/// The callbacks `main.lua` is expected to leave on `lovr`.
///
/// Named rather than counted: a configuration that stopped drawing would still
/// define some callbacks, and the gate this stands in for is that a terminal
/// appears and can be pointed at.
const CALLBACKS: &[&str] = &["load", "update", "draw", "quit", "keypressed"];

/// The events the shipped configuration subscribes to. Not `lovr` callbacks any
/// more: a subscription is a call, so what this checks is that the call was
/// made, which the stub records.
const SUBSCRIPTIONS: &[&str] = &["onWindowOpened", "onWindowClosed", "onProcessExited"];

#[test]
fn the_default_configuration_compiles() {
    let lua = session_lua();

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
    let lua = session_lua();
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

    let subscribed: Table = match lua.globals().get("subscribed") {
        Ok(subscribed) => subscribed,
        Err(error) => panic!("the stub's record could not be read: {error}"),
    };
    for name in SUBSCRIPTIONS {
        let called: Option<bool> = match subscribed.get(*name) {
            Ok(called) => called,
            Err(error) => panic!("lunette.{name} could not be read: {error}"),
        };
        assert!(
            called.unwrap_or(false),
            "the configuration should subscribe through lunette.{name}"
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
    let lua = session_lua();
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
        .load("local rules = require '@mullion/rules'\nfor _, source in ipairs(rules.sources()) do\n  if source.name == 'mullion.persist' then return true end\nend\nreturn false")
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
            "local rules = require '@mullion/rules'\nlocal names = {}\nfor _, source in \
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
    // A `require` answering an empty table is enough for every module the
    // configuration reaches except `lunette`, whose subscriptions it calls at
    // the top level rather than only from inside a callback.
    let subscribed = lua.create_table()?;
    lua.globals().set("subscribed", &subscribed)?;
    lua.globals().set(
        "require",
        lua.create_function(move |lua, name: String| {
            let module = lua.create_table()?;
            if name == "@lunette" {
                for register in SUBSCRIPTIONS {
                    let seen = lua.globals().get::<Table>("subscribed")?;
                    module.set(
                        *register,
                        lua.create_function(move |lua, _: mlua::Function| {
                            seen.set(*register, true)?;
                            lua.create_function(|_, ()| Ok(()))
                        })?,
                    )?;
                }
            }
            Ok(module)
        })?,
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

    // The standard-library loader, in Rust: LÖVR's production loader reads the
    // mounted virtual filesystem, which this test has no `lovr.filesystem` for.
    // The same shape — resolve `?.lua` against `package.path`, read the file,
    // load it — is what makes `require 'mullion.adopt'` resolve here the way
    // the session's does.
    let loaders: Table = package.get("loaders")?;
    let path_loader =
        lua.create_function(|lua, name: String| -> mlua::Result<mlua::MultiValue> {
            let package: Table = lua.globals().get("package")?;
            let path: String = package.get("path")?;
            for template in path.split(';').filter(|part| !part.is_empty()) {
                let module_path = name.strip_prefix("@mullion").map_or_else(
                    || name.replace('.', "/"),
                    |suffix| format!("mullion{suffix}"),
                );
                let candidate = template.replace('?', &module_path);
                if let Ok(source) = std::fs::read_to_string(&candidate) {
                    let function = lua
                        .load(&source)
                        .set_name(format!("={candidate}"))
                        .into_function()?;
                    return Ok(vec![mlua::Value::Function(function)].into());
                }
            }
            // A loader that finds nothing returns nil, and `require` moves on to
            // the next loader.
            Ok(Vec::new().into())
        })?;
    // Position 2, matching LÖVR's `luax_registerloader(L, luaLoader, 2, 0)`;
    // position 1 is preload, which production consults first.
    loaders.set(2, path_loader)?;

    let lunette = lua.create_table()?;
    // Each records that it was called and answers a cancel function, which is
    // the shape the real module has.
    let subscribed = lua.create_table()?;
    for name in [
        "onWindowOpened",
        "onWindowClosed",
        "onTitleChanged",
        "onMonitorAdded",
        "onProcessExited",
        "onProcessOutput",
        "onLayerGranted",
        "onLayerRevoked",
        "onError",
    ] {
        let seen = subscribed.clone();
        lunette.set(
            name,
            lua.create_function(move |lua, _: mlua::Function| {
                seen.set(name, true)?;
                lua.create_function(|_, ()| Ok(()))
            })?,
        )?;
    }
    lua.globals().set("subscribed", subscribed)?;
    // The real names rather than a list written out here: this table is a fake
    // of lunette's own module, and a fake that invents values is a test that
    // passes against an API nothing has.
    lunette.set(
        "modifierNames",
        lua.create_function(|_, ()| Ok(KeyModifier::NAMES.to_vec()))?,
    )?;
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
    loaded.set("@lunette", lunette)?;

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
