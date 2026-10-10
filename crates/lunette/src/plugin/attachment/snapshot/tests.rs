//! Native Lua inspection tests use the real graph, callbacks, and userdata methods.

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
fn snapshots_are_detached_and_reentrant_during_load_and_cleanup() -> mlua::Result<()> {
    let lua = lua()?;
    lua.load(
        r#"
        local p = native.plugin
        local runtime = p.runtime()
        local foreign = p.runtime()
        local loading, effect, child
        local childDefinition = p.define({}, {}, function() return {} end, 'child')
        local definition = p.define({}, {}, function(context)
            loading = runtime:snapshot()
            assert(runtime:ownerId(context) == loading.instances[1].id)
            assert(foreign:ownerId(context) == nil)
            assert(loading.draining and loading.instances[1].state == 'loading')
            assert(loading.instances[1].authority == 'resources')
            child = context:child(childDefinition, nil)
            effect = context:effect(function()
                return function()
                    local cleaning = runtime:snapshot()
                    assert(cleaning.instances[1].authority == 'cleanup')
                    assert(cleaning.instances[1].effects[1].state == 'cleaning')
                    assert(not context:active())
                end
            end)
            return {}
        end, 'label')
        local instance = runtime:use(definition, nil)
        instance:enable()
        local active = runtime:snapshot()
        assert(active.instances[1].id == instance:id())
        assert(active.instances[1].children[1] == child:id())
        assert(active.instances[2].parentId == instance:id())
        assert(active.instances[1].state == 'active' and active.instances[1].enabled)
        assert(active.instances[1].effects[1].state == 'armed')
        effect:dispose()
        assert(runtime:snapshot().instances[1].effects[1].state == 'disarmed')
        assert(active.instances[1].effects[1].state == 'armed')
        assert(loading.instances[1].state == 'loading')
        runtime:close()
        local closed = runtime:snapshot()
        assert(closed.closed and #closed.instances == 0)
        foreign:close()
    "#,
    )
    .exec()
}

#[test]
fn snapshots_expose_bindings_and_quarantine() -> mlua::Result<()> {
    let lua = lua()?;
    lua.load(r#"
        local p = native.plugin
        local wrapper = p.contract('inspection/exact', 4)
        local runtime = p.runtime()
        local providerDefinition = p.define({}, {service = wrapper}, function() return {service = {}} end, 'provider')
        local first = runtime:use(providerDefinition, nil)
        local second = runtime:use(providerDefinition, nil)
        local consumer = runtime:use(p.define({input = wrapper}, {}, function(_, fail)
            if fail then error('load failed') end
            return {}
        end, 'consumer'), true)
        first:enable()
        consumer:enable()
        local initial = runtime:snapshot()
        local failed = initial.instances[3]
        assert(failed.state == 'failed')
        assert(#failed.bindings == 0 and #failed.failedBindings == 1)
        local historical = failed.failedBindings[1]
        assert(historical.providerId == first:id() and historical.current)
        assert(historical.generationId == initial.instances[1].generationId)
        assert(historical.contract.display == 'inspection/exact@4')
        first:disable()
        assert(not runtime:snapshot().instances[3].failedBindings[1].current)
        second:enable()
        consumer:requestReload(false)
        runtime:drain()
        local recovered = runtime:snapshot()
        local node = recovered.instances[3]
        assert(node.state == 'active' and #node.failedBindings == 0)
        assert(node.bindings[1].providerId == second:id() and node.bindings[1].current)
        assert(node.bindings[1].generationId == recovered.instances[2].generationId)
        assert(recovered.instances[2].dependents[1] == consumer:id())
        assert(not pcall(function() node.bindings[1].providerId = first:id() end))
        assert(historical.current, 'a snapshot is detached from later state')
        runtime:close()

        local runtime = p.runtime()
        local retained
        local instance = runtime:use(p.define({}, {}, function(context)
            retained = context
            context:effect(function()
                return function() error('inverse failed') end
            end)
            return {}
        end, 'cleanup failure'), nil)
        instance:enable()
        instance:disable()
        local quarantined = runtime:snapshot().instances[1]
        assert(quarantined.state == 'quarantined' and quarantined.cleanupFailed)
        assert(quarantined.diagnostic ~= nil and quarantined.lastFailure ~= nil)
        assert(not pcall(function() retained:effect(function() error('must not acquire') end) end))
        runtime:close()
    "#).exec()
}
