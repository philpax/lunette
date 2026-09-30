//! Execution coverage for the neutral adoption provider.
//!
//! The plugin facade and all controlled providers are real. Native windows,
//! property storage, event registration, and layer/matrix primitives are fakes;
//! those are unmanaged boundaries owned by the host.

extern crate lunette_lovr;

use std::{cell::Cell, rc::Rc};

use lunette::plugin::{attachment, declarations};
use mlua::{Function, Lua, Table, UserData, Value};

fn state() -> mlua::Result<Lua> {
    let lua = Lua::new();
    lua.globals().set(
        "setreadonly",
        lua.create_function(|_, (table, readonly): (Table, bool)| {
            table.set_readonly(readonly);
            Ok(())
        })?,
    )?;

    let package = lua.create_table()?;
    let loaded = lua.create_table()?;
    let preload = lua.create_table()?;
    package.set("loaded", loaded)?;
    package.set("preload", preload.clone())?;
    lua.globals().set("package", package)?;
    lua.globals().set(
        "require",
        lua.create_function(|lua, name: String| {
            let package: Table = lua.globals().get("package")?;
            let loaded: Table = package.get("loaded")?;
            let preload: Table = package.get("preload")?;
            let cached: Value = loaded.get(name.clone())?;
            if !cached.is_nil() {
                return Ok(cached);
            }
            let loader: Function = preload.get(name.clone())?;
            let value: Value = loader.call(name.clone())?;
            let value = if value.is_nil() {
                Value::Boolean(true)
            } else {
                value
            };
            loaded.set(name, value.clone())?;
            Ok(value)
        })?,
    )?;

    let native = lua.create_table()?;
    declarations::install(&lua, &native)?;
    preload.set(
        "@lunette",
        lua.create_function(move |_, _: String| Ok(native.clone()))?,
    )?;

    for (name, source) in [
        (
            "@lunette-plugin",
            include_str!("../../../lua/lunette-plugin/init.lua"),
        ),
        (
            "@lunette-plugin/adapter",
            include_str!("../../../lua/lunette-plugin/adapter.lua"),
        ),
        (
            "@lunette-contracts/adoption",
            include_str!("../../../lua/lunette-contracts/adoption.lua"),
        ),
        (
            "@lunette-contracts/interaction",
            include_str!("../../../lua/lunette-contracts/interaction.lua"),
        ),
        (
            "@lunette-contracts/owner",
            include_str!("../../../lua/lunette-contracts/owner.lua"),
        ),
        (
            "@lunette-contracts/panels",
            include_str!("../../../lua/lunette-contracts/panels.lua"),
        ),
        (
            "@lunette-contracts/rules",
            include_str!("../../../lua/lunette-contracts/rules.lua"),
        ),
        (
            "@lunette-contracts/surface",
            include_str!("../../../lua/lunette-contracts/surface.lua"),
        ),
        (
            "@lunette-contracts/tags",
            include_str!("../../../lua/lunette-contracts/tags.lua"),
        ),
        (
            "@lunette-contracts/vocabulary",
            include_str!("../../../lua/lunette-contracts/vocabulary.lua"),
        ),
        (
            "@lunette-plugins/adoption",
            include_str!("../../../lua/lunette-plugins/adoption/init.lua"),
        ),
        (
            "@lunette-plugins/adoption/service",
            include_str!("../../../lua/lunette-plugins/adoption/service.lua"),
        ),
        (
            "@lunette-plugins/interaction",
            include_str!("../../../lua/lunette-plugins/interaction/init.lua"),
        ),
        (
            "@lunette-plugins/interaction/grab",
            include_str!("../../../lua/lunette-plugins/interaction/grab.lua"),
        ),
        (
            "@lunette-plugins/interaction/pose",
            include_str!("../../../lua/lunette-plugins/interaction/pose.lua"),
        ),
        (
            "@lunette-plugins/panels",
            include_str!("../../../lua/lunette-plugins/panels/init.lua"),
        ),
        (
            "@lunette-plugins/panels/events",
            include_str!("../../../lua/lunette-plugins/panels/events.lua"),
        ),
        (
            "@lunette-plugins/panels/layer",
            include_str!("../../../lua/lunette-plugins/panels/layer.lua"),
        ),
        (
            "@lunette-plugins/panels/raycast",
            include_str!("../../../lua/lunette-plugins/panels/raycast.lua"),
        ),
        (
            "@lunette-plugins/rules",
            include_str!("../../../lua/lunette-plugins/rules/init.lua"),
        ),
        (
            "@lunette-plugins/rules/policy",
            include_str!("../../../lua/lunette-plugins/rules/policy.lua"),
        ),
        (
            "@lunette-plugins/rules/service",
            include_str!("../../../lua/lunette-plugins/rules/service.lua"),
        ),
        (
            "@lunette-plugins/tags",
            include_str!("../../../lua/lunette-plugins/tags/init.lua"),
        ),
        (
            "@lunette-plugins/tags/service",
            include_str!("../../../lua/lunette-plugins/tags/service.lua"),
        ),
        (
            "@mullion/pose",
            include_str!("../../../lua/mullion/pose.lua"),
        ),
    ] {
        preload.set(name, lua.load(source).set_name(name).into_function()?)?;
    }

    lua.load(
        r#"
        claims = {}
        local native = require '@lunette'
        native.claimLayer = function(options)
          local claim = {
            dead = false,
            granted = false,
            width = options.width,
            height = options.height,
          }
          function claim:release()
            if self.dead then return false end
            self.dead = true
            return true
          end
          claims[#claims + 1] = claim
          return claim
        end
        local function matrix(value)
          local result = {}
          for index = 1, 16 do result[index] = value and value[index] or (index == 1 or index == 6 or index == 11 or index == 16) and 1 or 0 end
          function result:unpack() return table.unpack(self) end
          function result:set(other, ...)
            if type(other) == 'number' then
              local values = table.pack(other, ...)
              for index = 1, 16 do self[index] = values[index] end
            else
              for index = 1, 16 do self[index] = other[index] end
            end
            return self
          end
          function result:getPosition() return self[13], self[14], self[15] end
          function result:getOrientation() return 0, 0, 1, 0 end
          function result:scale() return self end
          function result:translate() return self end
          return result
        end
        lovr = { math = { newMat4 = matrix, mat4 = matrix } }
        "#,
    )
    .exec()?;

    Ok(lua)
}

struct SourcePayload(Rc<Cell<usize>>);

impl UserData for SourcePayload {}

impl Drop for SourcePayload {
    fn drop(&mut self) {
        self.0.set(self.0.get() + 1);
    }
}

#[test]
fn complete_placement_cleanup_attempts_all_operations_after_errors() -> mlua::Result<()> {
    for mode in ["direct", "adoption"] {
        for extra_failure in [false, true] {
            let lua = state()?;
            let fixture: Table = lua
                .load(include_str!("plugin_adoption/fixtures/adoption.lua"))
                .set_name("plugin_adoption/fixtures/adoption.lua")
                .eval()?;
            let run: Function = lua
                .load(include_str!("plugin_adoption/fixtures/cleanup_failure.lua"))
                .set_name("plugin_adoption/fixtures/cleanup_failure.lua")
                .eval()?;
            let dropped = Rc::new(Cell::new(0));
            let witness: Table = run.call((
                fixture,
                lua.create_userdata(SourcePayload(dropped.clone()))?,
                mode,
                extra_failure,
            ))?;
            let check: Function = witness.get("check")?;
            lua.gc_collect()?;
            lua.gc_collect()?;
            check.call::<()>(false)?;
            if mode == "direct" {
                assert_eq!(
                    dropped.get(),
                    1,
                    "failed cleanup retained its source payload"
                );
            }
            let errors = attachment::shutdown_all(&lua);
            assert!(!errors.is_empty(), "cleanup failure must remain visible");
            assert!(
                errors
                    .iter()
                    .any(|error| error.contains("fixture: membership remove failure")),
                "{errors:?}"
            );
            if extra_failure {
                assert!(
                    errors
                        .iter()
                        .any(|error| error.contains("fixture: implicit destroy failure")),
                    "{errors:?}"
                );
            }
            witness
                .get::<Function>("releaseCallbacks")?
                .call::<()>(())?;
            lua.gc_collect()?;
            lua.gc_collect()?;
            check.call::<()>(true)?;
            assert_eq!(
                dropped.get(),
                1,
                "closed failed cleanup retained its source payload"
            );
        }
    }
    Ok(())
}

#[test]
fn adoption_complete_placement_lifetime_releases_tags_and_sources() -> mlua::Result<()> {
    let lua = state()?;
    let fixture: Table = lua
        .load(include_str!("plugin_adoption/fixtures/adoption.lua"))
        .set_name("plugin_adoption/fixtures/adoption.lua")
        .eval()?;
    let cycle: Function = fixture.get("placementLifetime")?;
    let check: Function = fixture.get("checkPlacementCollection")?;
    let dropped = Rc::new(Cell::new(0));
    for (index, mode) in ["dispose", "caught", "failed-consumer", "disable"]
        .into_iter()
        .cycle()
        .take(24)
        .enumerate()
    {
        cycle.call::<()>((lua.create_userdata(SourcePayload(dropped.clone()))?, mode))?;
        lua.gc_collect()?;
        lua.gc_collect()?;
        check.call::<()>(())?;
        assert_eq!(
            dropped.get(),
            index + 1,
            "rules placement retained its source payload"
        );
    }
    let errors = attachment::shutdown_all(&lua);
    assert_eq!(
        errors.len(),
        6,
        "expected only failed-consumer initialization errors: {errors:?}"
    );
    assert!(
        errors
            .iter()
            .all(|error| error.contains("fixture: placement lifetime failure")),
        "{errors:?}"
    );
    Ok(())
}

#[test]
fn adoption_failed_consumer_initialization_rolls_back() -> mlua::Result<()> {
    let lua = state()?;
    let fixture: Table = lua
        .load(include_str!("plugin_adoption/fixtures/adoption.lua"))
        .set_name("plugin_adoption/fixtures/adoption.lua")
        .eval()?;
    fixture
        .get::<Function>("failInitialization")?
        .call::<()>(())?;
    let errors = attachment::shutdown_all(&lua);
    assert_eq!(
        errors.len(),
        1,
        "expected only the initialization error: {errors:?}"
    );
    assert!(
        errors[0].contains("fixture: onPlaced failure"),
        "{errors:?}"
    );
    Ok(())
}

#[test]
fn adoption_caught_enumeration_failure_cleans_up_and_allows_retry() -> mlua::Result<()> {
    let lua = state()?;
    let fixture: Table = lua
        .load(include_str!("plugin_adoption/fixtures/adoption.lua"))
        .set_name("plugin_adoption/fixtures/adoption.lua")
        .eval()?;
    fixture.get::<Function>("failEnumeration")?.call::<()>(())?;
    let errors = attachment::shutdown_all(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn adoption_cancelled_caller_and_copied_callbacks_are_inert() -> mlua::Result<()> {
    let lua = state()?;
    let fixture: Table = lua
        .load(include_str!("plugin_adoption/fixtures/adoption.lua"))
        .set_name("plugin_adoption/fixtures/adoption.lua")
        .eval()?;
    fixture.get::<Function>("cancelCaller")?.call::<()>(())?;
    let errors = attachment::shutdown_all(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn adoption_uses_real_provider_graph_and_preserves_native_windows() -> mlua::Result<()> {
    let lua = state()?;
    let _: Table = lua
        .load(include_str!("plugin_adoption/fixtures/adoption.lua"))
        .set_name("plugin_adoption/fixtures/adoption.lua")
        .eval()?;
    let errors = attachment::shutdown_all(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
