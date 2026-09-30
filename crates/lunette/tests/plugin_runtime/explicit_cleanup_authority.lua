return function(plugin)
  for _, loading in { false, true } do
    for _, broken in { false, true } do
      local runtime = plugin.runtime()
      local childCalls = 0
      local childDefinition = plugin.define({}, {}, function()
        childCalls += 1
        return {}
      end)
      local acquired = 0
      local attempts
      local escaped
      local disposable
      local function disposeAndCheck(context)
        local ok = pcall(function()
          disposable:dispose()
        end)
        assert(ok ~= broken, 'explicit inverse outcome changed')
        assert(
          attempts ~= nil and not attempts.active and not attempts.effect and not attempts.child,
          'explicit inverse retains resource authority'
        )
        assert(acquired == 0 and childCalls == 0, 'explicit inverse ran acquisition')
        if not broken then
          assert(context:active(), 'successful explicit inverse revoked owner permanently')
          context:effect(function()
            acquired += 1
            return function()
              acquired -= 1
            end
          end)
          context:child(childDefinition, {}):enable()
        else
          assert(not context:active(), 'failed explicit inverse remains active')
          assert(not pcall(function()
            context:effect(function()
              acquired += 1
              return function() end
            end)
          end), 'failed explicit inverse restored resource authority')
        end
      end
      local definition = plugin.define({}, {}, function(context)
        escaped = context
        disposable = context:effect(function()
          return function()
            attempts = {
              active = context:active(),
              effect = pcall(function()
                context:effect(function()
                  acquired += 1
                  return function()
                    acquired -= 1
                  end
                end)
              end),
              child = pcall(function()
                context:child(childDefinition, {}):enable()
              end),
            }
            if broken then
              error 'explicit authority inverse failure'
            end
          end
        end)
        if loading then
          disposeAndCheck(context)
        end
        return {}
      end)
      runtime:use(definition, {}):enable()
      if not loading then
        disposeAndCheck(escaped)
      end
      assert(attempts ~= nil, 'initializer cleanup assertions did not run')
      if not broken then
        assert(acquired == 1 and childCalls == 1, 'successful cleanup did not restore live owner')
      end
      runtime:close()
      assert(acquired == 0, 'explicit cleanup left a resource live')
    end
  end
  local runtime = plugin.runtime()
  local events = {}
  local acquired = 0
  local childLoads = 0
  local childDefinition = plugin.define({}, {}, function()
    childLoads += 1
    return {}
  end)
  runtime
    :use(
      plugin.define({}, {}, function(context)
        local ok = pcall(function()
          context:effect(function()
            context:effect(function()
              acquired += 1
              return function()
                acquired -= 1
                table.insert(events, 'nested')
              end
            end)
            error 'caught acquisition failure'
          end)
        end)
        assert(not ok and context:active(), 'caught acquisition error revoked loading owner')
        context:effect(function()
          acquired += 1
          return function()
            acquired -= 1
            table.insert(events, 'after')
          end
        end)
        context:child(childDefinition, {}):enable()
        return {}
      end),
      {}
    )
    :enable()
  assert(acquired == 2 and childLoads == 1, 'caught acquisition error lost tracked effects or valid child authority')
  runtime:close()
  assert(acquired == 0 and table.concat(events, ',') == 'after,nested', 'caught acquisition cleanup order changed')
end
