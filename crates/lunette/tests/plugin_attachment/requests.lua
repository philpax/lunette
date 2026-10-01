-- Requests apply in order and fail at the call that made them.
return function(plugin)
  local runtime = plugin.runtime()
  local function empty()
    return {}
  end
  local removed = runtime:use(plugin.define({}, {}, empty, 'removed'), {})
  removed:dispose()
  assert(removed:state() == 'removed', 'a disposed idle instance was not removed')
  local target = runtime:use(plugin.define({}, {}, empty, 'target'), {})
  local observed = {}
  local host = runtime:use(
    plugin.define({}, {}, function()
      observed.removed = pcall(function()
        removed:enable()
      end)
      target:enable()
      target:dispose()
      observed.retired = pcall(function()
        target:enable()
      end)
      return {}
    end, 'host'),
    {}
  )
  host:enable()
  assert(observed.removed == false, 'a request for a removed instance was accepted')
  assert(observed.retired == false, 'a retired instance accepted enable')
  assert(host:state() == 'active', 'a rejected request failed the loading instance: ' .. host:state())
  assert(target:state() == 'removed', 'enable followed by dispose left the target ' .. target:state())
  runtime:close()
  assert(not pcall(function()
    host:enable()
  end), 'a closed runtime accepted a request')
end
