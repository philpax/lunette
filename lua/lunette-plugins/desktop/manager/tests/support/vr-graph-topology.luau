local plugin = require '@lunette-plugin'
local schema = require '@lunette-plugin/schema'
local surfaces = require '@lunette-contracts/surfaces'
local quad = require '@lunette-contracts/quad'

local topology = {}

function topology.new(scope)
  local first = plugin.capability { name = 'local/vr-graph-first-' .. scope, schema = 1 }
  local second = plugin.capability { name = 'local/vr-graph-second-' .. scope, schema = 1 }
  local middle = plugin.capability { name = 'local/vr-graph-middle-' .. scope, schema = 1 }
  local result = {}
  local child = plugin.define { name = 'next-owned', init = function() end }
  local provider = plugin.define {
    name = 'next-provider',
    provides = { first = first, second = second },
    init = function(context, _settings, publish)
      publish:provide(first, {})
      publish:provide(second, {})
      result.child = context:child(child, {})
      result.child:enable()
    end,
  }
  local relay = plugin.define {
    name = 'next-middle',
    requires = { first = first, second = second },
    provides = { middle = middle },
    init = function(context, _settings, publish)
      context:require(first)
      context:require(second)
      publish:provide(middle, {})
    end,
  }
  local leaf = plugin.consumer({
    name = 'next-leaf',
    requires = { middle = middle },
    schema = schema.object {
      enabled = schema.default(schema.boolean())(true),
      mode = schema.default(schema.union(schema.literal<<'first'>> 'first', schema.literal<<'second'>> 'second')) 'first',
      title = schema.default(schema.string()) 'initial',
    },
    init = function(context, settings)
      context:require(middle)
      result.settings = settings
    end,
  }).definition
  result.entries = {
    { id = 'next-provider', definition = provider },
    { id = 'next-middle', definition = relay },
    { id = 'next-leaf', definition = leaf },
    { id = 'next-unrelated', definition = plugin.define { name = 'next-unrelated', init = function() end } },
  }
  function result:ids(env)
    return {
      provider = assert(env:entry 'next-provider').instanceId,
      middle = assert(env:entry 'next-middle').instanceId,
      leaf = assert(env:entry 'next-leaf').instanceId,
      unrelated = assert(env:entry 'next-unrelated').instanceId,
      child = self.child:id(),
    }
  end
  return result
end

function topology.application(env)
  local window = env.native.newWindow(71, 'vr-graph-application')
  local target = {
    dead = false,
    grabbable = false,
    pose = lovr.math.newMat4():translate(2, 1.2, -1),
    width = 1,
    height = 0.5,
    pixelWidth = window.width,
    pixelHeight = window.height,
  }
  function target:raycast(origin, direction)
    return quad.hit(self, origin, direction)
  end
  function target:project(origin, direction)
    return quad.project(self, origin, direction)
  end
  function target:sink()
    return window.sink
  end
  env.services.surfaces:offer(env.owner, {
    name = 'vr-graph-application',
    list = function()
      return { target }
    end,
  })
  env.owner:effect(function()
    return function()
      target.dead = true
    end
  end)
  return {
    pose = target.pose,
    width = target.width,
    height = target.height,
    logicalWidth = target.pixelWidth,
    logicalHeight = target.pixelHeight,
    visible = true,
  },
    window
end

return topology
