-- The laser's draw and readInput hooks, and its controller button mapping.
return function(plugin, modules)
  local laserModule = modules.laserModule
  local events = modules.events
  local pass = modules.pass

  -- The headset reports the trigger and the a button down on the left hand.
  local newMat4 = lovr.math.newMat4
  lovr.math.newMat4 = function(value, ...)
    if type(value) == 'number' then
      return newMat4 { x = value, y = select(1, ...), z = select(2, ...) }
    end
    return newMat4(value)
  end
  local down = { trigger = true, a = true }
  lovr.headset.isTracked = function()
    return true
  end
  lovr.headset.isDown = function(_device, button)
    return down[button] == true
  end
  lovr.headset.getAxis = function()
    return 0, 0
  end
  lovr.headset.getPose = function()
    return 0, 1, 0, 0, 0, 1, 0
  end
  lovr.headset.getPosition = function()
    return 0, 1, 0
  end
  lovr.headset.getDirection = function()
    return 0, 0, -1
  end
  lovr.headset.getDeltaTime = function()
    return 1 / 60
  end

  local drawn, read = {}, {}
  local hooked = laserModule.define {
    name = 'hooked-laser',
    buttons = { { control = 'a', button = 'right' }, { control = 'b', button = 'middle' } },
    readInput = function(hand, base)
      local frame = base(hand)
      read[#read + 1] = { hand = hand, frame = frame }
      return frame
    end,
    draw = function(laser, target, base)
      drawn[#drawn + 1] = laser.hand
      if laser.hand == 'left' then
        base(laser, target)
      end
    end,
  }

  local runtime = plugin.runtime()
  runtime:use(modules.drops, {}):enable()
  runtime:use(modules.focus, {}):enable()
  runtime:use(modules.interaction, {}):enable()
  runtime:use(hooked, {}):enable()
  local service
  runtime
    :use(
      plugin.define {
        name = 'hooks-1',
        requires = { laser = modules.laserCapability },
        init = function(context)
          service = context:require(modules.laserCapability)
          service:attach(context)
        end,
      },
      {}
    )
    :enable()

  -- The provider's reader reads the headset through the mapping, and the hook
  -- sees each hand's frame.
  service:update {}
  assert(#read == 2 and read[1].hand == 'left' and read[2].hand == 'right')
  local frame = read[1].frame
  assert(frame.buttons.right == true, 'a presses right')
  assert(frame.buttons.left == nil, 'the trigger is not mapped')
  assert(frame.buttons.middle == nil, 'b is up')
  assert(frame.grip == false)

  -- The service's draw draws each laser through the hook.
  local lines = pass.lineCalls
  service:draw(pass)
  assert(#drawn == 2 and drawn[1] == 'left' and drawn[2] == 'right', 'the bulk draw honours the hook')
  assert(pass.lineCalls == lines + 1, 'only the hand whose hook called the default drew a beam')
  service:forHand('right'):draw(pass)
  assert(#drawn == 3 and pass.lineCalls == lines + 1, "a laser's own draw is the hook too")

  -- A laser's own reader replaces the provider's for that laser.
  runtime:close()
  runtime = plugin.runtime()
  runtime:use(modules.drops, {}):enable()
  runtime:use(modules.focus, {}):enable()
  runtime:use(modules.interaction, {}):enable()
  runtime:use(laserModule.definition, {}):enable()
  local own = 0
  runtime
    :use(
      plugin.define {
        name = 'hooks-2',
        requires = { laser = modules.laserCapability },
        init = function(context)
          service = context:require(modules.laserCapability)
          service:new(context, 'left', {
            readInput = function()
              own += 1
              return nil
            end,
            style = { length = 9 },
          })
        end,
      },
      {}
    )
    :enable()
  service:update {}
  assert(own == 1)
  local laser = service:forHand 'left'
  assert(laser.style.length == 9 and laser.style.cursorRadius == service.STYLE.cursorRadius, 'a style merges')
  assert(#read == 2, 'the provider hook of another definition is not called')
  runtime:close()

  -- The default reader maps the trigger to the left button.
  runtime = plugin.runtime()
  runtime:use(modules.drops, {}):enable()
  runtime:use(modules.focus, {}):enable()
  runtime:use(modules.interaction, {}):enable()
  runtime:use(laserModule.definition, {}):enable()
  runtime
    :use(
      plugin.define {
        name = 'hooks-3',
        requires = { laser = modules.laserCapability },
        init = function(context)
          service = context:require(modules.laserCapability)
          service:attach(context)
        end,
      },
      {}
    )
    :enable()
  service:update {}
  local input = service:forHand('left').input
  assert(input and input.buttons.left == true and input.buttons.right == nil)
  runtime:close()

  -- A mapping is checked where it is written.
  for _, buttons in ipairs {
    { { control = 'pinch', button = 'left' } },
    { { control = 'a', button = 'thumb' } },
    { { control = 'a', button = 'left', extra = true } },
  } do
    assert(not pcall(function()
      laserModule.define { buttons = buttons }
    end))
  end
  events.hooks = true
  lovr.math.newMat4 = newMat4
end
