return function(plugin)
  local token = plugin.contract('test/malformed', 1)
  local wrapper = {}
  setreadonly(wrapper, true)
  plugin.bind(token, wrapper)
  local bad = plugin.define({}, { service = token }, function(_, _)
    return { wrong = true }
  end)
  local runtime = plugin.runtime()
  local instance = runtime:use(bad, {})
  instance:enable()
  runtime:close()
end
