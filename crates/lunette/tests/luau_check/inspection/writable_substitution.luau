local native = require '@lunette'

local function needsInstances(values: { native.PluginInstanceSnapshot })
  table.remove(values, 1)
end

local function needsEffects(values: { native.PluginEffectSnapshot })
  table.remove(values, 1)
end

local function needsIds(values: { string })
  table.remove(values, 1)
end

local function substitute(snapshot: native.PluginRuntimeSnapshot)
  local instance = snapshot.instances[1]
  local instances: { native.PluginInstanceSnapshot } = snapshot.instances -- reject.
  local effects: { native.PluginEffectSnapshot } = instance.effects -- reject.
  local children: { string } = instance.children -- reject.
  needsInstances(snapshot.instances) -- reject.
  needsEffects(instance.effects) -- reject.
  needsIds(instance.children) -- reject.
  return instances, effects, children
end

return substitute
