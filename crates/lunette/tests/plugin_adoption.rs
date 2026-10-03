//! Execution coverage for the adoption provider, with native windows,
//! properties, events, and layer primitives faked.

extern crate lunette_lovr;

use std::{cell::Cell, rc::Rc};

use mlua::{Function, Lua, Table, UserData};

mod plugin_sources;
mod plugin_support;

fn state() -> mlua::Result<Lua> {
    let (lua, _) = plugin_support::module_state(plugin_sources::register)?;
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
                .load(include_str!("plugin_adoption/fixtures/adoption.luau"))
                .set_name("plugin_adoption/fixtures/adoption.luau")
                .eval()?;
            let run: Function = lua
                .load(include_str!(
                    "plugin_adoption/fixtures/cleanup_failure.luau"
                ))
                .set_name("plugin_adoption/fixtures/cleanup_failure.luau")
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
            // The cleanup failures are raised to the fixture's destroy or
            // dispose call, which asserts that they aggregate.
            let errors = plugin_support::shutdown(&lua);
            assert!(errors.is_empty(), "{errors:?}");
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
        .load(include_str!("plugin_adoption/fixtures/adoption.luau"))
        .set_name("plugin_adoption/fixtures/adoption.luau")
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
    let errors = plugin_support::shutdown(&lua);
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
        .load(include_str!("plugin_adoption/fixtures/adoption.luau"))
        .set_name("plugin_adoption/fixtures/adoption.luau")
        .eval()?;
    fixture
        .get::<Function>("failInitialization")?
        .call::<()>(())?;
    let errors = plugin_support::shutdown(&lua);
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
        .load(include_str!("plugin_adoption/fixtures/adoption.luau"))
        .set_name("plugin_adoption/fixtures/adoption.luau")
        .eval()?;
    fixture.get::<Function>("failEnumeration")?.call::<()>(())?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn adoption_install_needs_no_rules_dependency_from_its_caller() -> mlua::Result<()> {
    let lua = state()?;
    let fixture: Table = lua
        .load(include_str!("plugin_adoption/fixtures/adoption.luau"))
        .set_name("plugin_adoption/fixtures/adoption.luau")
        .eval()?;
    fixture
        .get::<Function>("installWithoutRules")?
        .call::<()>(())?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn adoption_cancelled_caller_and_copied_callbacks_are_inert() -> mlua::Result<()> {
    let lua = state()?;
    let fixture: Table = lua
        .load(include_str!("plugin_adoption/fixtures/adoption.luau"))
        .set_name("plugin_adoption/fixtures/adoption.luau")
        .eval()?;
    fixture.get::<Function>("cancelCaller")?.call::<()>(())?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}

#[test]
fn adoption_uses_real_provider_graph_and_preserves_native_windows() -> mlua::Result<()> {
    let lua = state()?;
    let _: Table = lua
        .load(include_str!("plugin_adoption/fixtures/adoption.luau"))
        .set_name("plugin_adoption/fixtures/adoption.luau")
        .eval()?;
    let errors = plugin_support::shutdown(&lua);
    assert!(errors.is_empty(), "cleanup errors: {errors:?}");
    Ok(())
}
