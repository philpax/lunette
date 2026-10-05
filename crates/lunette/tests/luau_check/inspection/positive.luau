local native = require '@lunette'

local function summarize(runtime: native.PluginRuntime): string
  local snapshot = runtime:snapshot()
  local names: { string } = {}
  for _, instance in snapshot.instances do
    local identity: string = instance.id
    local lifecycle: native.PluginState = instance.state
    table.insert(names, identity .. ':' .. lifecycle)
    for _, capability in instance.required do
      local contract: native.PluginContractSnapshot = capability.contract
      table.insert(names, capability.field .. '=' .. contract.display)
    end
    for _, capability in instance.provided do
      table.insert(names, capability.contract.name .. '@' .. tostring(capability.contract.schema))
    end
    for _, binding in instance.bindings do
      table.insert(names, binding.providerId .. ':' .. binding.generationId .. ':' .. tostring(binding.current))
    end
    for _, binding in instance.failedBindings do
      table.insert(names, binding.contract.display)
    end
    for _, childId in instance.children do
      table.insert(names, childId)
    end
    for _, dependentId in instance.dependents do
      table.insert(names, dependentId)
    end
    for _, effect in instance.effects do
      local state: native.PluginEffectState = effect.state
      table.insert(names, effect.ownerId .. ':' .. effect.sourceId .. ':' .. effect.ordinal .. ':' .. state)
    end
    for _, blocker in instance.blockers do
      table.insert(names, blocker.message)
      for _, relatedId in blocker.instanceIds do
        table.insert(names, relatedId)
      end
    end
  end
  for _, diagnostic in snapshot.diagnostics do
    table.insert(names, diagnostic.instanceId .. ':' .. diagnostic.severity .. ':' .. diagnostic.blocker.message)
  end
  local first = snapshot.instances[1]
  if first then
    table.insert(names, first.name)
  end
  return tostring(#snapshot.instances) .. ':' .. table.concat(names, ',')
end

return summarize
