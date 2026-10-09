local native = require '@lunette'

local function mutate(snapshot: native.PluginRuntimeSnapshot)
  local instance = snapshot.instances[1]
  snapshot.instances[1] = nil -- reject.
  instance.children[1] = nil -- reject.
  instance.effects[1] = nil -- reject.
  table.remove(snapshot.instances, 1) -- reject.
  table.remove(instance.bindings, 1) -- reject.
  table.remove(instance.effects, 1) -- reject.
end

return mutate
