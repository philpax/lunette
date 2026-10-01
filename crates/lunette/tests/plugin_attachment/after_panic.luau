-- The runtime keeps serving requests after a callback panicked.
return function(plugin)
  local loads = 0
  local definition = plugin.define({}, {}, function()
    loads += 1
    return {}
  end, 'after panic')
  local instance = panicking_runtime:use(definition, {})
  instance:enable()
  assert(loads == 1 and instance:state() == 'active', 'the runtime stayed wedged after a panic')
  local fresh = plugin.runtime()
  fresh:use(definition, {}):enable()
  assert(loads == 2)
  fresh:close()
end
