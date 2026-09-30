//! Soft reload witnesses for live plugin attachments and native clients.

#![expect(
    clippy::expect_used,
    reason = "the lifecycle witness uses expectations to report violated ownership contracts"
)]

use lunette::{
    plugin::{attachment, declarations},
    reload,
};
use lunette_compositor::{protocol::PixelSize, test_client::TestClient, testing::TestCompositor};
use mlua::{Lua, Table};

#[test]
fn soft_reload_retires_the_plugin_epoch_without_disturbing_a_live_client() -> mlua::Result<()> {
    let mut compositor = TestCompositor::new();
    let mut client = TestClient::connect(&mut compositor);
    client.open_toplevel(&mut compositor);
    client.attach_buffer(&mut compositor, PixelSize::new(320, 240));
    client.set_title(&mut compositor, "before reload");

    let before = compositor.snapshot();
    assert_eq!(before.windows.len(), 1, "the real client mapped one window");
    let before_window = before.windows[0].clone();
    assert_eq!(before_window.title.as_deref(), Some("before reload"));

    let lua = plugin_state()?;
    lua.load(
        r#"
        cleanup_order = {}
        old_token = plugin.contract('test/epoch', 1)
        local old_definition = plugin.define({}, {}, function(context, config)
          context:effect(function()
            return function()
              cleanup_order[#cleanup_order + 1] = 'runtime'
            end
          end)
          return {}
        end)
        local old_runtime = plugin.runtime()
        old_runtime:use(old_definition, {}):enable()

        package.preload.main = function()
          new_token = plugin.contract('test/epoch', 1)
          plugin.bind(new_token, table.freeze({}))
          local definition = plugin.define({}, {}, function(context, config)
            new_active = context:active()
            return {}
          end)
          new_runtime = plugin.runtime()
          new_runtime:use(definition, {}):enable()
          return {}
        end
        "#,
    )
    .exec()?;

    reload::reload(&lua, &|| {
        lua.load("cleanup_order[#cleanup_order + 1] = 'subscriptions'")
            .exec()
            .expect("subscription cleanup witness runs");
    })
    .map_err(mlua::Error::external)?;

    assert_eq!(
        lua.load("return table.concat(cleanup_order, ',')")
            .eval::<String>()?,
        "runtime,subscriptions"
    );
    assert!(lua.globals().get::<bool>("new_active")?);
    assert!(!attachment::callback_active(&lua));

    let plugin: Table = lua.globals().get("plugin")?;
    let bind = plugin.get::<mlua::Function>("bind")?;
    let old_token = lua.globals().get::<mlua::AnyUserData>("old_token")?;
    assert!(
        bind.call::<()>((old_token, lua.create_table()?)).is_err(),
        "a token from the retired epoch must not bind"
    );

    client.set_title(&mut compositor, "after reload");
    let after = compositor.snapshot();
    assert_eq!(after.windows.len(), 1, "the same client remains mapped");
    let after_window = &after.windows[0];
    let mut expected_window = before_window;
    expected_window.title = Some("after reload".to_owned());
    assert_eq!(after_window, &expected_window);

    client.disconnect(&mut compositor);
    Ok(())
}

fn plugin_state() -> mlua::Result<Lua> {
    let lua = Lua::new();
    attachment::install(&lua)?;
    let module = lua.create_table()?;
    declarations::install(&lua, &module)?;
    let plugin: Table = module.get("plugin")?;
    lua.globals().set("plugin", plugin)?;
    lua.load(
        r#"
        lovr = { handlers = {} }
        arg = {}
        package = { loaded = {}, preload = {} }
        require = function(name)
          if package.loaded[name] ~= nil then return package.loaded[name] end
          local loader = assert(package.preload[name], 'missing module: ' .. name)
          local value = loader()
          if value == nil then value = true end
          package.loaded[name] = value
          return value
        end
        "#,
    )
    .exec()?;
    Ok(lua)
}
