local native = require '@lunette'

local function mutate(snapshot: native.PluginRuntimeSnapshot)
  local instance = snapshot.instances[1]
  snapshot.instances[1] = instance -- reject.
  snapshot.diagnostics[1] = snapshot.diagnostics[1] -- reject.
  instance.required[1] = instance.required[1] -- reject.
  instance.provided[1] = instance.provided[1] -- reject.
  instance.bindings[1] = instance.bindings[1] -- reject.
  instance.failedBindings[1] = instance.failedBindings[1] -- reject.
  instance.children[1] = 'other' -- reject.
  instance.dependents[1] = 'other' -- reject.
  instance.blockers[1] = instance.blockers[1] -- reject.
  instance.blockers[1].instanceIds[1] = 'other' -- reject.
  instance.effects[1] = instance.effects[1] -- reject.
end

return mutate
