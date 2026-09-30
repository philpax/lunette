return function(plugin, modules)
  local runtime = plugin.runtime()
  local panelsInstance = runtime:use(modules.panels, {})
  local interactionInstance = runtime:use(modules.interaction, {})
  local laserInstance = runtime:use(modules.laser, {})
  local events = modules.events

  local callerDefinition = plugin.define(function(config)
    return config
  end, { laser = modules.laserCapability }, {}, function(context, _config, _provide)
    local service = context:require(modules.laserCapability)
    local borrowed = service:new(context, 'left', {
      seat = modules.seat,
      readInput = function()
        return nil
      end,
    })
    assert(borrowed.seat == modules.seat)
    assert(not borrowed.ownsSeat)
    assert(#service:all() == 1)

    local attached = service:attach(context, {
      seat = modules.seat,
      readInput = function()
        return nil
      end,
    })
    assert(#attached == 2)
    assert(service:forHand 'left' == borrowed)
    assert(#service:all() == 2)

    service:update {}
    assert(borrowed.input == nil)
    borrowed:destroy()
    assert(#service:all() == 1)
    assert(not modules.seat.dead)
    events.acquired = true
    events.service = service
  end)

  local caller = runtime:use(callerDefinition, {})
  panelsInstance:enable()
  interactionInstance:enable()
  laserInstance:enable()
  caller:enable()
  assert(events.acquired)
  caller:disable()
  assert(#events.service:all() == 0)
  runtime:close()
end
