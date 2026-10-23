#![expect(
    clippy::expect_used,
    reason = "integration tests report failures at the operation that violates the contract"
)]

use std::path::Path;

use lunette::execution::{self, ExecutionMode};
use mlua::{Function, Lua, Table};

#[path = "lua/state.rs"]
mod state;

const MODULE: &str = "@lunette-plugins/ui/host/private/shape";
const MODULE_PATH: &str = "@lunette-plugins/ui/host/private/shape.luau";
const SIBLING: &str = "@lunette-plugins/ui/host/private/records";

#[test]
fn routed_module_keeps_its_virtual_path_and_relative_imports() {
    let lua = new_lua();
    lua.set_app_data(state::BenchmarkLoader::default());
    let require = require_function(&lua);

    let shape: Table = require.call(MODULE).expect("the routed module loads");
    let source: String = lua
        .load("return debug.info(..., 's')")
        .call(
            shape
                .get::<Function>("toPanel")
                .expect("the module exports toPanel"),
        )
        .expect("the function's source is readable");
    assert_eq!(source, MODULE_PATH);
    require
        .call::<Table>(SIBLING)
        .expect("the sibling loads by its alias");

    let loader = lua
        .app_data_ref::<state::BenchmarkLoader>()
        .expect("the benchmark loader remains installed");
    assert_eq!(loader.loads.get(MODULE_PATH), Some(&1));
    assert_eq!(
        loader
            .loads
            .get("@lunette-plugins/ui/host/private/records.luau"),
        Some(&1),
        "the relative import and the alias share one cached load"
    );
}

#[test]
fn cleared_package_loaded_entry_loads_the_source_again() {
    let lua = new_lua();
    lua.set_app_data(state::BenchmarkLoader::default());
    let require = require_function(&lua);

    let first: Table = require.call(MODULE).expect("the first load succeeds");
    let clear_loaded: Function = lua
        .load("return function(name) package.loaded[name] = nil end")
        .eval()
        .expect("the package cache clearer is created");
    clear_loaded
        .call::<()>(MODULE)
        .expect("the module cache entry is cleared");
    let second: Table = require.call(MODULE).expect("the second load succeeds");

    assert!(
        !lua.load("return rawequal(...)")
            .call::<bool>((first, second))
            .expect("the modules are comparable"),
        "the module body runs again after cache clearing"
    );
    let loader = lua
        .app_data_ref::<state::BenchmarkLoader>()
        .expect("the benchmark loader remains installed");
    assert_eq!(loader.loads.get(MODULE_PATH), Some(&2));
}

#[test]
fn modules_load_normally_without_benchmark_loader_app_data() {
    let lua = new_lua();
    let shape: Table = require_function(&lua)
        .call(MODULE)
        .expect("the source module loads normally");

    assert!(
        shape
            .get::<Option<Function>>("toPanel")
            .expect("the source function is readable")
            .is_some(),
        "the source module is loaded when no benchmark loader is installed"
    );
}

#[test]
fn marked_module_uses_native_code_generation_when_supported() {
    let lua = state_lua();
    execution::enable_metrics(&lua).expect("compiler metrics are enabled");
    if !execution::supported() {
        let error = execution::configure(&lua, ExecutionMode::NativeMarked)
            .expect_err("unsupported native compilation is rejected");
        assert!(
            error
                .to_string()
                .contains("native compilation is not supported"),
            "native-marked module execution is unavailable on this build or CPU: {error}"
        );
        eprintln!(
            "native-marked module execution was not exercised: this build or CPU does not support CodeGen"
        );
        return;
    }
    execution::configure(&lua, ExecutionMode::NativeMarked)
        .expect("native-marked execution is supported");
    let mut loader = state::BenchmarkLoader::default();
    loader.marked.insert(MODULE_PATH.to_owned());
    lua.set_app_data(loader);
    let require = require_function(&lua);

    require
        .call::<Table>(SIBLING)
        .expect("the unmarked sibling loads");
    let unmarked = bound_native_functions(&lua);
    assert_eq!(unmarked, 0, "unmarked modules stay interpreted");
    require
        .call::<Table>(MODULE)
        .expect("the marked module loads through the C loader");
    assert!(
        bound_native_functions(&lua) > unmarked,
        "the marked module binds native code"
    );
}

fn bound_native_functions(lua: &Lua) -> u64 {
    execution::metrics(lua)
        .expect("compiler metrics are readable")
        .expect("compiler metrics are enabled")
        .nativeFunctionsBound
}

fn new_lua() -> Lua {
    let lua = state_lua();
    execution::configure(&lua, ExecutionMode::Interpreter)
        .expect("interpreter execution is supported");
    lua
}

fn state_lua() -> Lua {
    let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let roots = state::Roots::of_repository(repository);
    state::new(&roots).expect("the shared state harness builds a Lua state")
}

fn require_function(lua: &Lua) -> Function {
    lua.globals()
        .get("require")
        .expect("the shared state harness installs require")
}
