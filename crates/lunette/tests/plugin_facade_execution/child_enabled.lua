-- Context:child installs a child and enables it, so it loads with the
-- activation that installed it and is retired with that activation.
return function(plugin)
  local function identity(value)
    return value
  end

  local loads = 0
  local child = plugin.define(identity, {}, {}, function()
    loads += 1
  end)
  local installed
  local parent = plugin.define(identity, {}, {}, function(context)
    installed = context:child(child, {})
  end)

  local runtime = plugin.runtime()
  local parentInstance = runtime:use(parent, {})
  parentInstance:enable()
  assert(installed:state() == 'active', installed:state())
  assert(loads == 1)
  installed:enable()
  assert(loads == 1, 'enabling an enabled child changes nothing')
  parentInstance:disable()
  assert(installed:state() == 'removed', installed:state())
  runtime:close()
end
