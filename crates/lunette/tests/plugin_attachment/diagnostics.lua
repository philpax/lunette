-- Instance state and diagnostics are visible from Lua.
return function(plugin)
  local token = plugin.contract('audit/diagnostics', 1)
  local runtime = plugin.runtime()
  local failing = runtime:use(
    plugin.define({}, {}, function()
      error 'audit initializer failure'
    end, 'audit failing plugin'),
    {}
  )
  failing:enable()
  assert(failing:state() == 'failed', 'a failed load ended as ' .. failing:state())
  local diagnostic = failing:diagnostic() or ''
  assert(string.find(diagnostic, 'audit failing plugin', 1, true), diagnostic)
  assert(string.find(diagnostic, 'audit initializer failure', 1, true), diagnostic)
  local waiting = runtime:use(
    plugin.define({ service = token }, {}, function()
      return {}
    end, 'audit waiting consumer'),
    {}
  )
  waiting:enable()
  assert(waiting:state() == 'inactive')
  local reason = waiting:diagnostic() or ''
  assert(string.find(reason, 'waiting for a provider of audit/diagnostics@1', 1, true), reason)
  local provider = runtime:use(
    plugin.define({}, { service = token }, function()
      return { service = {} }
    end, 'audit provider'),
    {}
  )
  provider:enable()
  assert(waiting:state() == 'active' and waiting:diagnostic() == nil, 'a published instance kept its diagnostic')
  runtime:close()
  assert(waiting:state() == 'removed')
end
