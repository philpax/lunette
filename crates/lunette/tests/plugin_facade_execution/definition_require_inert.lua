return function(plugin)
  local first = require '@lunette-plugin'
  local second = require '@lunette-plugin'
  assert(rawequal(first, second))

  local initialized = false
  local definition = plugin.define {
    name = 'definition',
    init = function(_context, _config, _provide)
      initialized = true
    end,
  }
  assert(definition.name == 'definition')
  assert(definition.requires ~= nil and next(definition.requires) == nil)
  assert(definition.provides ~= nil and next(definition.provides) == nil)
  assert(not initialized)
end
