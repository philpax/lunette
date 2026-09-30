return function(plugin)
  local first = require '@lunette-plugin'
  local second = require '@lunette-plugin'
  assert(rawequal(first, second))

  local initialized = false
  local definition = plugin.define(function(config)
    return config
  end, {}, {}, function(_context, _config, _provide)
    initialized = true
  end)
  assert(definition.required ~= nil)
  assert(definition.provided ~= nil)
  assert(definition.configWitness({ marker = true }).marker)
  assert(not initialized)
end
