return function(plugin)
  local released = 0
  local runtime = plugin.runtime()
  local definition = plugin.define({}, {}, function(context)
    context:effect(function()
      return function()
        released += 1
      end
    end)
    return {}
  end)
  local instances = {}
  for i = 1, 300 do
    instances[i] = runtime:use(definition, {})
    instances[i]:enable()
  end
  runtime:close()
  assert(released == 300, 'shutdown stranded effects')
  local other = plugin.runtime()
  local pending = {}
  for i = 1, 300 do
    pending[i] = other:use(definition, {})
  end
  local trigger = other:use(
    plugin.define({}, {}, function(context)
      context:effect(function()
        return function()
          released += 1
        end
      end)
      for i = 1, 300 do
        pcall(function()
          pending[i]:enable()
        end)
      end
      other:close()
      return {}
    end),
    {}
  )
  trigger:enable()
  assert(released == 301, 'queued shutdown lost priority')
  assert(not pcall(function()
    other:use(definition, {})
  end), 'runtime not closed')
end
