return function(plugin, modules)
  local runtime = plugin.runtime()
  runtime:use(modules.drops, {}):enable()
  runtime:use(modules.focus, {}):enable()
  local interactionInstance = runtime:use(modules.interaction, {})
  local laserInstance = runtime:use(modules.laser, {})
  local events = modules.events

  local callerDefinition = plugin.define {
    name = 'callerDefinition',
    requires = { laser = modules.laserCapability },
    init = function(context, _config, _provide)
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
      assert(attached[1] == borrowed, "attach answers the owner's own laser for a hand it holds")
      assert(service:forHand 'left' == borrowed)
      assert(#service:all() == 2)
      local again = service:attach(context)
      assert(again[1] == attached[1] and again[2] == attached[2] and #service:all() == 2, 'attach is idempotent')

      service:update {}
      assert(borrowed.input == nil)
      borrowed:destroy()
      assert(#service:all() == 1)
      assert(not modules.seat.dead)
      events.acquired = true
      events.service = service
    end,
  }

  -- A hand has one laser, and attach never hands one owner another's.
  local rivalDefinition = plugin.define {
    name = 'rivalDefinition',
    requires = { laser = modules.laserCapability },
    init = function(context)
      local service = context:require(modules.laserCapability)
      local before = #service:all()
      assert(not pcall(function()
        service:attach(context)
      end), 'attach raises for a hand another owner holds')
      assert(#service:all() == before, 'a refused attach makes nothing')
      events.rivalRefused = true
    end,
  }

  local caller = runtime:use(callerDefinition, {})
  interactionInstance:enable()
  laserInstance:enable()
  caller:enable()
  assert(events.acquired)
  runtime:use(rivalDefinition, {}):enable()
  assert(events.rivalRefused)
  caller:disable()
  assert(#events.service:all() == 0)
  runtime:close()
end
