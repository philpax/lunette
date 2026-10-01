return function(plugin)
  for _, mode in { 'rollback', 'explicit' } do
    local token = plugin.contract('audit/' .. mode, 1)
    local runtime = plugin.runtime()
    local loads = 0
    local handle
    local remaining_released = 0
    local definition = plugin.define({}, { service = token }, function(context)
      loads += 1
      context:effect(function()
        return function()
          remaining_released += 1
        end
      end)
      handle = context:effect(function()
        return function()
          error('inverse failed ' .. mode)
        end
      end)
      if mode == 'rollback' then
        error 'apply failed'
      end
      return { service = 42 }
    end)
    local instance = runtime:use(definition, {})
    instance:enable()
    if mode == 'explicit' then
      assert(not pcall(function()
        handle:dispose()
      end))
    end
    assert(not pcall(function()
      instance:enable()
    end), 'quarantined instance accepted enable')
    assert(loads == 1, 'cleanup failure allowed retry')
    instance:disable()
    assert(instance:state() == 'quarantined', 'cleanup failure was not quarantined')
    assert(
      string.find(instance:diagnostic() or '', 'inverse failed ' .. mode, 1, true),
      'quarantine diagnostic lost its cause: ' .. tostring(instance:diagnostic())
    )
    local duplicate = runtime:use(definition, {})
    assert(not pcall(function()
      duplicate:enable()
    end), 'cleanup failure released reservation')
    runtime:close()
    assert(remaining_released == 1, 'quarantine stranded remaining inverse')
  end
end
