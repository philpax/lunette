return function(plugin, modules)
  local runtime = plugin.runtime()
  local panels = runtime:use(modules.panels, {})
  local interaction = runtime:use(modules.interaction, {})
  local laser = runtime:use(modules.laser, {})
  local events = modules.events

  local callerDefinition = plugin.define(function(config)
    return config
  end, {
    laser = modules.laserCapability,
    interaction = modules.interactionCapability,
  }, {}, function(context)
    local service = context:require(modules.laserCapability)
    events.service = service
    events.interaction = context:require(modules.interactionCapability)
    local leftInput = {
      pose = lovr.math.newMat4(),
      origin = vector.pack(0, 0, 0),
      direction = vector.pack(0, 0, -1),
      trigger = false,
      grip = false,
      dt = 1 / 60,
    }
    local rightInput = {
      pose = lovr.math.newMat4(),
      origin = vector.pack(0, 0, 0),
      direction = vector.pack(0, 1, 0),
      trigger = false,
      grip = false,
      dt = 1 / 60,
    }
    events.inputs = { left = leftInput, right = rightInput }
    local function readInput(hand)
      events.inputCalls[hand] = (events.inputCalls[hand] or 0) + 1
      return events.inputs[hand]
    end

    local weakResources = setmetatable({}, { __mode = 'v' })
    for cycle = 1, 12 do
      do
        local temporary = service:new(context, 'left', { readInput = readInput })
        local seat = temporary.seat
        weakResources[1], weakResources[2] = temporary, temporary.pointer
        assert(temporary:destroy())
        assert(seat.dead)
        assert(not temporary:destroy())
      end
      collectResources()
      collectResources()
      assert(weakResources[1] == nil and weakResources[2] == nil, 'destroyed laser or pointer retained')
    end
    local borrowed = service:new(context, 'left', { seat = modules.borrowedSeat, readInput = readInput })
    local attached = service:attach(context, { readInput = readInput })
    assert(attached[1] == borrowed)
    assert(attached[2].hand == 'right')
    assert(attached[2].seat ~= modules.borrowedSeat)
    assert(#service:all() == 2)
    assert(#events.interaction:pointers() == 2)

    events.service = service
    if not events.firstService then
      events.firstService = service
      events.borrowed = borrowed
      events.borrowedSeat = modules.borrowedSeat
      events.ownedSeat = attached[2].seat
    else
      events.replacementService = service
      events.replacementOwnedSeat = attached[2].seat
    end
  end)

  local caller = runtime:use(callerDefinition, {})
  panels:enable()
  interaction:enable()
  laser:enable()
  caller:enable()

  events.service:update {}
  assert(events.inputCalls.left == 1)
  assert(events.inputCalls.right == 1)
  events.service:draw(modules.pass)
  assert(events.pass.lineCalls == 2)
  assert(events.pass.sphereCalls == 0)
  assert(events.pass.depthTestCalls == 4)
  assert(events.pass.depthWriteCalls == 4)

  local hit = {
    dead = false,
    raycast = function(_, _, direction)
      if direction.y > 0.5 then
        return nil
      end
      return 1, 2, 3
    end,
    onHover = function()
      events.surfaceHover = (events.surfaceHover or 0) + 1
    end,
  }
  events.service:update { hit }
  assert(events.inputCalls.left == 2)
  assert(events.inputCalls.right == 2)
  assert(events.surfaceHover == 1)
  assert(events.haptic['hand/left'] == 1)
  assert(events.haptic['hand/right'] == nil)
  assert(events.lastHaptic[1] == 'hand/left')
  assert(events.lastHaptic[2] == events.service.STYLE.hapticStrength)
  assert(events.lastHaptic[3] == events.service.STYLE.hapticDuration)
  assert(events.lastHaptic[4] == 0)

  events.service:draw(modules.pass)
  assert(events.pass.lineCalls == 4)
  assert(events.pass.sphereCalls == 1)
  assert(events.pass.lastColor[1] == 1)
  assert(events.pass.lastColor[2] == 1)
  assert(events.pass.lastColor[3] == 1)
  assert(events.pass.lastColor[4] == 1)
  assert(events.pass.laserColors[3][1] == events.service.STYLE.hoverColor[1])
  assert(events.pass.laserColors[3][2] == events.service.STYLE.hoverColor[2])
  assert(events.pass.laserColors[3][3] == events.service.STYLE.hoverColor[3])
  assert(events.pass.laserColors[3][4] == events.service.STYLE.hoverColor[4])

  events.inputs.left = nil
  events.service:update {}
  assert(events.inputCalls.left == 3)
  assert(events.inputCalls.right == 3)
  assert(events.haptic['hand/left'] == 1)

  local stale = events.service:forHand 'right'
  assert(stale ~= nil)
  local inputCallsBeforeStale = events.inputCalls.right
  local lineCallsBeforeStale = events.pass.lineCalls
  caller:disable()
  assert(#events.firstService:all() == 0)
  assert(#events.interaction:pointers() == 0)
  assert(not events.borrowedSeat.dead)
  assert(events.ownedSeat.dead)
  assert(stale:destroy() == false)
  assert(stale:vibrate() == false)
  stale:update {}
  stale:draw(modules.pass)
  assert(events.inputCalls.right == inputCallsBeforeStale)
  assert(events.pass.lineCalls == lineCallsBeforeStale)
  assert(events.haptic['hand/right'] == nil)

  laser:disable()
  assert(not pcall(function()
    events.firstService:all()
  end))
  assert(not events.borrowedSeat.dead)

  local replacement = runtime:use(modules.laser, {})
  replacement:enable()
  local secondCaller = runtime:use(callerDefinition, {})
  secondCaller:enable()
  assert(#events.replacementService:all() == 2)
  assert(#events.interaction:pointers() == 2)
  assert(events.replacementService:forHand('left').seat == events.borrowedSeat)
  assert(events.replacementService:forHand('right').seat ~= events.borrowedSeat)

  secondCaller:disable()
  assert(#events.replacementService:all() == 0)
  assert(#events.interaction:pointers() == 0)
  assert(not events.borrowedSeat.dead)
  assert(events.replacementOwnedSeat.dead)
  replacement:disable()
  assert(not events.borrowedSeat.dead)
  runtime:close()
end
