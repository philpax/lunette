return function(plugin)
  local runtime = plugin.runtime()
  local instance
  local released = 0
  local reached = false
  local definition = plugin.define({}, {}, function(context)
    local ok = pcall(function()
      context:effect(function()
        instance:disable()
        return function()
          local acquired = 0
          assert(not context:active(), 'cancelled rollback context remains active')
          assert(not pcall(function()
            context:effect(function()
              acquired += 1
              return function() end
            end)
          end), 'cancelled rollback accepts effects')
          assert(acquired == 0, 'cancelled rollback ran acquisition body')
          assert(not pcall(function()
            context:child(
              plugin.define({}, {}, function()
                return {}
              end),
              {}
            )
          end), 'cancelled rollback accepts children')
          released += 1
        end
      end)
    end)
    assert(not ok, 'cancelled acquisition returned success')
    assert(released == 1, 'returned inverse not rolled back')
    local forbidden_calls = 0
    assert(not pcall(function()
      context:effect(function()
        forbidden_calls += 1
        return function() end
      end)
    end))
    assert(forbidden_calls == 0, 'cancelled context invoked acquisition')
    reached = true
    return {}
  end)
  instance = runtime:use(definition, {})
  instance:enable()
  assert(reached, 'initializer boundary assertions failed')
  assert(released == 1)
  runtime:close()
end
