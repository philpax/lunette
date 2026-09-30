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
    instance:enable()
    assert(loads == 1, 'cleanup failure allowed retry')
    instance:disable()
    assert(not pcall(function()
      runtime:use(definition, {})
    end), 'cleanup failure released reservation')
    runtime:close()
    assert(remaining_released == 1, 'quarantine stranded remaining inverse')
  end
end
