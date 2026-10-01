-- Disposing an effect whose instance was removed or whose runtime closed does nothing.
return function(plugin)
  local released = 0
  local effects = {}
  local definition = plugin.define({}, {}, function(context)
    table.insert(
      effects,
      context:effect(function()
        return function()
          released += 1
        end
      end)
    )
    return {}
  end, 'stale effects')
  local runtime = plugin.runtime()
  local instance = runtime:use(definition, {})
  instance:enable()
  instance:dispose()
  assert(instance:state() == 'removed' and released == 1)
  effects[1]:dispose()
  local closed = plugin.runtime()
  closed:use(definition, {}):enable()
  closed:close()
  assert(released == 2)
  effects[2]:dispose()
  assert(released == 2, 'a stale effect ran its inverse again')
  runtime:close()
end
