-- Drives the simulated head from the desktop window while the headset has no session, in place of LÖVR's simulator.
-- Dragging with the look button turns the head, and the movement keys move it while the button is held, so the
-- primary button stays free for the mouse pointer and typing does not move the head. See README.md.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local config = require '@self/config'
local head = require '@self/private/head'

export type Config = config.Config
export type Settings = config.Settings

local BUTTONS: { [string]: number } = { secondary = 2, middle = 3 }

local function simulating(): boolean
  local headset = lovr.headset
  return headset ~= nil and not headset.isActive()
end

local function keys(): head.Keys
  local down = lovr.system.isKeyDown
  return {
    forward = down('w', 'up'),
    backward = down('s', 'down'),
    left = down('a', 'left'),
    right = down('d', 'right'),
    up = down 'q',
    down = down 'e',
    sprint = down('lshift', 'rshift'),
    walk = down('lctrl', 'rctrl'),
  }
end

local function init(context: plugin.Context, settings: Settings): ()
  local frameService: frame.Service = context:require(frame.capability)
  local button = BUTTONS[settings.lookButton]
  -- The target the drags set, and the view shown on its way there.
  local target: head.State? = nil
  local shownYaw, shownPitch = 0, 0
  local looking = false

  local function setLooking(on: boolean): ()
    if looking == on then
      return
    end
    looking = on
    -- Relative mode hides the cursor and lets a drag turn past the window's edge.
    lovr.system.setMouseMode(if on then 'relative' else 'normal')
  end
  context:effect(function(): () -> ()
    return function(): ()
      setLooking(false)
    end
  end)

  frameService:onMouse(context, {
    run = function(event: frame.HostMouseEvent): ()
      if event.kind == 'press' and event.button == button and simulating() then
        setLooking(true)
      elseif event.kind == 'release' and event.button == button then
        setLooking(false)
      elseif event.kind == 'move' and looking and target then
        target = head.look(target, event.dx, event.dy, settings.lookSensitivity)
      end
    end,
  })

  frameService:onSimulate(context, {
    run = function(dt: number): ()
      local headset = assert(lovr.headset, 'the simulator runs with the headset module')
      local current: head.State
      if target then
        current = target
      else
        current = head.fromPose(vector.pack(headset.getPosition 'head'), vector.pack(headset.getDirection 'head'))
        shownYaw, shownPitch = current.yaw, current.pitch
      end
      if looking then
        current = head.move(current, keys(), settings, dt)
      end
      target = current
      shownYaw = head.follow(shownYaw, current.yaw, settings.smoothing, dt)
      shownPitch = head.follow(shownPitch, current.pitch, settings.smoothing, dt)
      local x, y, z = vector.unpack(current.position)
      local angle, ax, ay, az = head.angleAxis { position = current.position, yaw = shownYaw, pitch = shownPitch }
      headset.setPose('head', x, y, z, angle, ax, ay, az)
    end,
  })
end

return plugin.consumer<<Config, Settings>> {
  name = 'desktop/simulator',
  requires = { frame.capability },
  schema = config.schema,
  init = init,
}
