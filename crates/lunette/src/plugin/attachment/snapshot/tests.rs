//! Native Lua inspection tests use the real graph, callbacks, and userdata methods.

use lunette_luau::Typed;
use mlua::Lua;

use crate::plugin::declarations;

fn lua() -> mlua::Result<Lua> {
    let lua = Lua::new();
    let native = lua.create_table()?;
    declarations::install(&lua, &native)?;
    lua.globals().set("native", native)?;
    Ok(lua)
}

#[test]
fn snapshot_lists_declare_readonly_indexers_without_changing_vec_types() {
    assert_eq!(
        super::SnapshotList::<String>::luau().to_string(),
        "{ read [number]: string }"
    );
    assert_eq!(Vec::<String>::luau().to_string(), "{ string }");
    let output = crate::lua::declarations::render();
    for record in crate::plugin::attachment::snapshot_records() {
        for field in record.fields {
            let ty = (field.ty)();
            if matches!(ty, lunette_luau::Type::ReadonlyArray(_)) {
                assert!(output.contains(&format!("read {}: {ty},", field.name)));
            }
            assert!(
                !matches!(ty, lunette_luau::Type::Array(_)),
                "writable snapshot field {}.{}",
                record.name,
                field.name
            );
        }
    }
}

#[test]
fn effect_history_is_complete_until_next_load_or_removal_and_retains_no_callbacks()
-> mlua::Result<()> {
    let lua = lua()?;
    lua.load(r#"
        local p = native.plugin
        local runtime = p.runtime()
        local context
        local cleaned = 0
        local weakCallbacks = setmetatable({}, {__mode = 'k'})
        local instance = runtime:use(p.define({}, {}, function(current)
            context = current
            return {}
        end, 'history'), nil)
        instance:enable()
        local activation = runtime:snapshot().instances[1].activationId
        for _ = 1, 512 do
            local effect = context:effect(function()
                local inverse = function() cleaned += 1 end
                weakCallbacks[inverse] = true
                return inverse
            end)
            effect:dispose()
        end
        local history = runtime:snapshot()
        assert(cleaned == 512 and #history.instances[1].effects == 512)
        for index, effect in history.instances[1].effects do
            assert(effect.ownerId == instance:id() and effect.sourceId == instance:id())
            assert(effect.activationId == activation and effect.ordinal == tostring(index - 1))
            assert(effect.state == 'disarmed')
        end
        historyFixture = {callbacks = weakCallbacks, history = history, runtime = runtime}
        historyFixture.finish = function()
        instance:disable()
        assert(#runtime:snapshot().instances[1].effects == 512)
        assert(cleaned == 512)
        instance:reload(nil)
        local reloaded = runtime:snapshot()
        assert(reloaded.instances[1].activationId ~= activation)
        assert(#reloaded.instances[1].effects == 0)
        assert(#history.instances[1].effects == 512)
        local replacement = context:effect(function()
            local inverse = function() cleaned += 1 end
            weakCallbacks[inverse] = true
            return inverse
        end)
        replacement:dispose()
        local latest = runtime:snapshot()
        assert(#latest.instances[1].effects == 1 and latest.instances[1].effects[1].ordinal == '512')
        instance:dispose()
        assert(#runtime:snapshot().instances == 0 and #latest.instances[1].effects == 1)
        runtime:close()
        historyFixture.latest = latest
        end
    "#).exec()?;
    lua.gc_collect()?;
    lua.load(
        r#"
        assert(next(historyFixture.callbacks) == nil)
        assert(#historyFixture.runtime:snapshot().instances[1].effects == 512)
        historyFixture.finish()
        historyFixture.finish = nil
    "#,
    )
    .exec()?;
    lua.gc_collect()?;
    lua.load(
        r#"
        assert(next(historyFixture.callbacks) == nil)
        assert(#historyFixture.history.instances[1].effects == 512)
        assert(#historyFixture.latest.instances[1].effects == 1)
        historyFixture = nil
    "#,
    )
    .exec()
}

#[test]
fn snapshots_are_detached_immutable_and_reentrant_during_load_and_cleanup() -> mlua::Result<()> {
    let lua = lua()?;
    lua.load(r#"
        local p = native.plugin
        local runtime = p.runtime()
        local foreign = p.runtime()
        local cleaned = 0
        local loading, cleaning, effect, retained
        local definition = p.define({}, {}, function(context)
            retained = context
            loading = runtime:snapshot()
            assert(runtime:ownerId(context) == loading.instances[1].id)
            assert(foreign:ownerId(context) == nil)
            assert(loading.draining and loading.instances[1].state == 'loading')
            assert(loading.instances[1].authority == 'resources')
            effect = context:effect(function()
                return function()
                    cleaned += 1
                    cleaning = runtime:snapshot()
                    assert(cleaning.instances[1].authority == 'cleanup')
                    assert(cleaning.instances[1].effects[1].state == 'cleaning')
                    assert(not context:active())
                    assert(runtime:ownerId(context) == cleaning.instances[1].id)
                    assert(foreign:ownerId(context) == nil)
                end
            end)
            return {}
        end, 'duplicate name')
        local instance = runtime:use(definition, nil)
        local other = runtime:use(definition, nil)
        assert(instance:id() ~= other:id())
        assert(runtime:owns(instance) and not foreign:owns(instance))
        local inactive = runtime:snapshot()
        assert(not inactive.draining and not inactive.instances[1].enabled)
        instance:enable()
        local active = runtime:snapshot()
        assert(active.instances[1].id == instance:id())
        assert(active.instances[1].state == 'active' and active.instances[1].enabled)
        assert(active.instances[1].generationId == active.instances[1].activationId)
        assert(active.instances[1].effects[1].state == 'armed')
        assert(active.instances[1].effects[1].ownerId == instance:id())
        assert(active.instances[1].effects[1].sourceId == instance:id())
        assert(cleaned == 0)
        for _, operation in {
            function() active.closed = true end,
            function() active.instances[1].state = 'failed' end,
            function() active.instances[1].effects[1].state = 'disarmed' end,
            function() table.insert(active.instances, {}) end,
            function() active.instances[1] = nil end,
            function() table.remove(active.instances, 1) end,
            function() active.instances[1].effects[1] = nil end,
            function() table.remove(active.instances[1].effects, 1) end,
        } do
            assert(not pcall(operation))
        end
        effect:dispose()
        assert(cleaned == 1)
        local disarmed = runtime:snapshot()
        assert(disarmed.instances[1].effects[1].state == 'disarmed')
        assert(disarmed.instances[1].authority == 'resources')
        instance:disable()
        assert(cleaned == 1)
        assert(active.instances[1].state == 'active')
        assert(loading.instances[1].state == 'loading')
        runtime:close()
        local closed = runtime:snapshot()
        assert(closed.closed and closed.closing and closed.shutdownRequested and not closed.draining)
        assert(#closed.instances == 0)
        assert(runtime:owns(instance))
        assert(runtime:ownerId(retained) == instance:id())
        assert(foreign:ownerId(retained) == nil)
        foreign:close()
    "#).exec()
}

#[test]
fn snapshots_keep_exact_current_and_failed_binding_ids_and_freeze_their_nested_data()
-> mlua::Result<()> {
    let lua = lua()?;
    lua.load(r#"
        local p = native.plugin
        local token = p.contract('inspection/exact', 4)
        local wrapper = table.freeze({})
        p.bind(token, wrapper)
        local runtime = p.runtime()
        local providerDefinition = p.define({}, {service = wrapper}, function() return {service = {}} end, 'same label')
        local first = runtime:use(providerDefinition, nil)
        local second = runtime:use(providerDefinition, nil)
        local consumer = runtime:use(p.define({input = wrapper}, {}, function(_, fail)
            if fail then error('load failed') end
            return {}
        end, 'same label'), true)
        first:enable()
        consumer:enable()
        local initial = runtime:snapshot()
        local failed = initial.instances[3]
        assert(failed.id == consumer:id() and failed.state == 'failed')
        assert(#failed.bindings == 0 and #failed.failedBindings == 1)
        local historicalBinding = failed.failedBindings[1]
        assert(historicalBinding.providerId == first:id() and historicalBinding.current)
        assert(historicalBinding.generationId == initial.instances[1].generationId)
        assert(historicalBinding.contract.name == 'inspection/exact' and historicalBinding.contract.schema == 4)
        assert(historicalBinding.contract.display == 'inspection/exact@4')
        assert(#initial.instances[1].dependents == 0)
        first:disable()
        local unavailable = runtime:snapshot()
        local old = unavailable.instances[3].failedBindings[1]
        assert(old.providerId == first:id() and old.generationId == historicalBinding.generationId and not old.current)
        second:enable()
        assert(runtime:snapshot().instances[3].failedBindings[1].providerId == second:id())
        consumer:reload(false)
        local recovered = runtime:snapshot()
        local node = recovered.instances[3]
        assert(node.id == consumer:id() and node.state == 'active')
        assert(#node.failedBindings == 0 and #node.bindings == 1)
        assert(node.bindings[1].providerId == second:id() and node.bindings[1].current)
        assert(node.bindings[1].generationId == recovered.instances[2].generationId)
        assert(node.bindings[1].generationId ~= historicalBinding.generationId)
        assert(recovered.instances[2].dependents[1] == consumer:id())
        for _, operation in {
            function() node.bindings[1] = nil end,
            function() node.bindings[1].providerId = first:id() end,
            function() node.bindings[1].contract.schema = 7 end,
            function() failed.failedBindings[1] = nil end,
            function() historicalBinding.current = false end,
            function() historicalBinding.contract.name = 'other' end,
            function() node.required[1].contract.display = 'other' end,
        } do
            assert(not pcall(operation))
        end
        assert(historicalBinding.current)
        runtime:close()
    "#).exec()
}

#[test]
fn snapshots_do_not_plan_or_consume_pending_diagnostics() -> mlua::Result<()> {
    let lua = lua()?;
    lua.load(r#"
        local p = native.plugin
        local token = p.contract('inspection/missing', 2)
        local wrapper = table.freeze({})
        p.bind(token, wrapper)
        local runtime = p.runtime()
        local instance = runtime:use(p.define({clock = wrapper}, {}, function() error('must not load') end, 'waiting'), nil)
        instance:enable()
        local snapshot = runtime:snapshot()
        local node = snapshot.instances[1]
        assert(node.id == instance:id() and node.state == 'inactive' and node.enabled)
        assert(node.required[1].field == 'clock')
        assert(node.required[1].contract.name == 'inspection/missing')
        assert(node.required[1].contract.schema == 2)
        assert(node.required[1].contract.display == 'inspection/missing@2')
        assert(node.blockers[1].kind == 'missingProvider' and #node.bindings == 0)
        runtime:close()
    "#).exec()?;
    let runtime = crate::plugin::attachment::runtime(&lua, ())?;
    {
        let wrapper = lua.create_table()?;
        wrapper.set_readonly(true);
        let token =
            crate::plugin::attachment::contract(&lua, ("inspection/pending".to_owned(), 1))?;
        let userdata = lua.create_userdata(token)?;
        crate::plugin::attachment::bind(
            &lua,
            (
                userdata.borrow::<crate::plugin::attachment::PluginContractToken>()?,
                crate::plugin::attachment::Unknown(mlua::Value::Table(wrapper.clone())),
            ),
        )?;
        let required = lua.create_table()?;
        required.set("service", wrapper)?;
        let definition = crate::plugin::attachment::define(
            &lua,
            (
                crate::plugin::attachment::Unknown(mlua::Value::Table(required)),
                crate::plugin::attachment::Unknown(mlua::Value::Table(lua.create_table()?)),
                crate::plugin::attachment::PluginInit(lua.create_function(|_, ()| Ok(()))?),
                Some("pending diagnostic".to_owned()),
            ),
        )?;
        let instance = crate::plugin::attachment::lifecycle::use_definition(
            &runtime.state,
            definition.data,
            mlua::Value::Nil,
            None,
        )?;
        let mut state = runtime.state.borrow_mut();
        state
            .graph
            .request(crate::plugin::graph::Intent::Enable(instance.id))
            .map_err(mlua::Error::external)?;
        assert!(state.graph.next_action().is_none());
    }
    let before = runtime.state.borrow().graph.snapshot();
    let _first = super::snapshot(&runtime.state)?;
    let _second = super::snapshot(&runtime.state)?;
    assert_eq!(before, runtime.state.borrow().graph.snapshot());
    assert_eq!(
        runtime.state.borrow_mut().graph.take_diagnostics(),
        before.diagnostics
    );
    Ok(())
}

#[test]
fn inspection_refuses_a_mutably_borrowed_runtime_without_panicking() -> mlua::Result<()> {
    let lua = lua()?;
    let runtime = crate::plugin::attachment::runtime(&lua, ())?;
    let state = runtime.state.borrow_mut();
    let result = super::snapshot(&runtime.state);
    assert!(result.is_err());
    drop(state);
    assert!(super::snapshot(&runtime.state).is_ok());
    Ok(())
}

#[test]
fn snapshots_keep_last_failure_after_recovery_and_report_live_children() -> mlua::Result<()> {
    let lua = lua()?;
    lua.load(
        r#"
        local p = native.plugin
        local runtime = p.runtime()
        local child
        local childDefinition = p.define({}, {}, function() return {} end, 'same label')
        local definition = p.define({}, {}, function(context, fail)
            if fail then error('initialization failed') end
            child = context:child(childDefinition, nil)
            child:enable()
            return {}
        end, 'same label')
        local instance = runtime:use(definition, true)
        instance:enable()
        local failed = runtime:snapshot().instances[1]
        assert(failed.state == 'failed' and failed.lastFailure ~= nil)
        instance:reload(false)
        local recovered = runtime:snapshot()
        assert(recovered.instances[1].state == 'active')
        assert(recovered.instances[1].lastFailure == failed.lastFailure)
        assert(recovered.instances[1].diagnostic == nil)
        assert(#recovered.instances == 2)
        assert(recovered.instances[1].children[1] == child:id())
        assert(recovered.instances[2].parentId == instance:id())
        assert(recovered.instances[2].id ~= instance:id())
        instance:disable()
        assert(#runtime:snapshot().instances == 1)
        runtime:close()
    "#,
    )
    .exec()
}

#[test]
fn snapshots_expose_quarantine_and_cleanup_without_rearming_resources() -> mlua::Result<()> {
    let lua = lua()?;
    lua.load(
        r#"
        local p = native.plugin
        local runtime = p.runtime()
        local unloading, retained
        local instance = runtime:use(p.define({}, {}, function(context)
            retained = context
            context:effect(function()
                return function()
                    unloading = runtime:snapshot()
                    assert(unloading.instances[1].state == 'unloading')
                    assert(not unloading.instances[1].enabled)
                    assert(unloading.instances[1].effects[1].state == 'cleaning')
                    error('inverse failed')
                end
            end)
            return {}
        end, 'cleanup failure'), nil)
        instance:enable()
        instance:disable()
        local snapshot = runtime:snapshot()
        assert(snapshot.instances[1].state == 'quarantined')
        assert(snapshot.instances[1].cleanupFailed)
        assert(snapshot.instances[1].diagnostic ~= nil)
        assert(snapshot.instances[1].lastFailure ~= nil)
        assert(snapshot.instances[1].effects[1].state == 'disarmed')
        assert(snapshot.instances[1].authority == 'cleanup')
        assert(not retained:active())
        assert(not pcall(function() retained:effect(function() error('must not acquire') end) end))
        runtime:close()
    "#,
    )
    .exec()
}
