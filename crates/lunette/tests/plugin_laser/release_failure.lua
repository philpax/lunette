-- A laser's native release that fails while its owner unloads is that owner's
-- failure: the owner is quarantined, and the laser and interaction providers
-- keep serving other owners.
return function(plugin, modules)
  local function identity(value)
    return value
  end
  local function noInput()
    return nil
  end

  local runtime = plugin.runtime()
  runtime:use(modules.panels, {}):enable()
  local interactionInstance = runtime:use(modules.interaction, {})
  interactionInstance:enable()
  local laserInstance = runtime:use(modules.laser, {})
  laserInstance:enable()

  local held
  local consumer = runtime:use(
    plugin.define(identity, { laser = modules.laserCapability }, {}, function(context)
      held = context:require(modules.laserCapability):new(context, 'left', { readInput = noInput })
    end),
    {}
  )
  consumer:enable()
  assert(held and not held.dead, 'the consumer holds a laser')

  local failedReleases = 0
  local brokenSink = { dead = false }
  function brokenSink:button(_, pressed)
    if not pressed then
      failedReleases += 1
      error 'native laser release failed'
    end
  end
  held.pointer:setButton(true, brokenSink)

  consumer:disable()
  assert(failedReleases == 1 and held.dead, 'the release ran once')
  assert(consumer:state() == 'quarantined', 'the failing owner is quarantined: ' .. consumer:state())
  assert(laserInstance:state() == 'active', 'the laser provider is not quarantined: ' .. laserInstance:state())
  assert(
    interactionInstance:state() == 'active',
    'the interaction provider is not quarantined: ' .. interactionInstance:state()
  )

  local replacement
  local other = runtime:use(
    plugin.define(identity, { laser = modules.laserCapability }, {}, function(context)
      replacement = context:require(modules.laserCapability):new(context, 'left', { readInput = noInput })
    end),
    {}
  )
  other:enable()
  assert(other:state() == 'active' and replacement and not replacement.dead, 'the providers serve another owner')
  runtime:close()
end
