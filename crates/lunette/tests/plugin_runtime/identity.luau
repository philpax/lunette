return function(plugin)
  local token = plugin.contract('test/identity', 1)
  local wrapper = { marker = {} }
  setreadonly(wrapper, true)
  plugin.bind(token, wrapper)
  local definition = plugin.define({}, { service = token }, function(_, config)
    return { service = config.service }
  end)
  local first = plugin.runtime()
  local second = plugin.runtime()
  local first_instance = first:use(definition, { service = wrapper })
  local second_instance = second:use(definition, { service = wrapper })
  first_instance:enable()
  second_instance:enable()
  first:close()
  second_instance:reload { service = wrapper }
  local third = plugin.runtime()
  local third_instance = third:use(definition, { service = wrapper })
  third_instance:enable()
  third:close()
  second:close()
end
