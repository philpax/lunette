return function(plugin)
  local parent_token = plugin.contract('test/parent', 1)
  local child_token = plugin.contract('test/child', 1)
  local parent_wrapper = { marker = {} }
  local child_wrapper = { marker = {} }
  setreadonly(parent_wrapper, true)
  setreadonly(child_wrapper, true)
  plugin.bind(parent_token, parent_wrapper)
  plugin.bind(child_token, child_wrapper)
  local events = {}
  local child_definition = plugin.define({}, { child = child_token }, function(context, config)
    context:effect(function()
      return function()
        table.insert(events, 'child-release')
      end
    end)
    return { child = config.child }
  end)
  local parent_definition = plugin.define({}, { parent = parent_token }, function(context, config)
    local child = context:child(child_definition, { child = config.parent })
    child:enable()
    context:effect(function()
      return function()
        table.insert(events, 'parent-release')
      end
    end)
    return { parent = config.parent }
  end)
  local runtime = plugin.runtime()
  local parent = runtime:use(parent_definition, { parent = parent_wrapper })
  parent:enable()
  parent:disable()
  runtime:close()
  assert(events[1] == 'child-release' and events[2] == 'parent-release')
end
