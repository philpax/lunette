//! Tests panic propagation through Rust plugin callbacks. Lua tests cover the other
//! attachment cases.

extern crate lunette_lovr;

use std::panic::{AssertUnwindSafe, catch_unwind};

use lunette::plugin::attachment;
use mlua::Function;

mod plugin_support;

/// Enables an instance whose initializer calls `panic_now`, leaving its
/// runtime in the global `panicking_runtime`.
const PANIC: &str = r#"
return function(plugin)
  panicking_runtime = plugin.runtime()
  local definition = plugin.define({}, {}, function()
    panic_now()
    return {}
  end, 'panicking initializer')
  panicking_runtime:use(definition, {}):enable()
end
"#;

/// Asserts that the runtime the panic unwound through, and a fresh one, keep
/// serving requests.
const AFTER_PANIC: &str = r#"
return function(plugin)
  local loads = 0
  local definition = plugin.define({}, {}, function()
    loads += 1
    return {}
  end, 'after panic')
  local instance = panicking_runtime:use(definition, {})
  instance:enable()
  assert(loads == 1 and instance:state() == 'active', 'the runtime stayed wedged after a panic')
  local fresh = plugin.runtime()
  fresh:use(definition, {}):enable()
  assert(loads == 2)
  fresh:close()
end
"#;

#[test]
fn a_panicking_callback_does_not_wedge_the_attachment() -> mlua::Result<()> {
    let (lua, plugin) = plugin_support::native_state()?;
    lua.globals().set(
        "panic_now",
        lua.create_function(|_, ()| -> mlua::Result<()> {
            panic!("plugin callback panic");
        })?,
    )?;
    let panicking: Function = lua.load(PANIC).set_name("panic").eval()?;
    let unwound = catch_unwind(AssertUnwindSafe(|| panicking.call::<()>((plugin.clone(),))));
    assert!(unwound.is_err(), "the panic did not reach the caller");
    assert!(
        !attachment::callback_active(&lua),
        "the callback depth outlived the panic"
    );
    let after: Function = lua.load(AFTER_PANIC).set_name("after_panic").eval()?;
    after.call::<()>((plugin,))?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "{errors:?}");
    Ok(())
}
