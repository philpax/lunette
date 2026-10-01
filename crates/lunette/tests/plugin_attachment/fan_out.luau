-- A provider reload drains and reloads many dependents in one drain.
return function(plugin)
  local token = plugin.contract('audit/fan-out', 1)
  local runtime = plugin.runtime()
  local provider = runtime:use(
    plugin.define({}, { service = token }, function()
      return { service = {} }
    end, 'fan-out provider'),
    {}
  )
  provider:enable()
  local loads = 0
  local consumer = plugin.define({ service = token }, {}, function()
    loads += 1
    return {}
  end, 'fan-out consumer')
  local consumers = {}
  for index = 1, 200 do
    consumers[index] = runtime:use(consumer, {})
    consumers[index]:enable()
  end
  assert(loads == 200)
  provider:reload {}
  assert(loads == 400, 'a provider reload stranded dependents: ' .. loads)
  for _, instance in consumers do
    assert(instance:state() == 'active')
  end
  runtime:close()
end
