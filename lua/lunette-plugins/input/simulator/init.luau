-- Drives the simulated head from the desktop window while the headset has no session, in place of LÖVR's simulator.
-- Dragging with the look button pulls the scene around the head, and the movement keys move it while nothing has
-- keyboard focus or while the button is held, so the primary button stays free for the mouse pointer and typing into
-- a focused window does not move the head. See README.md.
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'
local frame = require '@lunette-contracts/frame'
local config = require '@self/config'
local head = require '@self/private/head'

export type Config = config.Config
export type Settings = config.Settings

local BUTTONS: { [string]: number } = { secondary = 2, middle = 3 }

-- The view the simulator window shows, or nil while a headset session runs.
local function simulatorView(): head.View?
  local headset = lovr.headset
  if not headset or headset.isActive() then
    return nil
  end
  local left, right, up, down = headset.getViewAngles(1)
  if not left or not right or not up or not down then
    return nil
  end
  return { left = left, right = right, up = up, down = down }
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
  local focusService: focus.Service = context:require(focus.capability)
  local button = BUTTONS[settings.lookButton]
  -- The target the drags set, and the view shown on its way there.
  local target: head.State? = nil
  local shownYaw, shownPitch = 0, 0
  local looking = false

  frameService:onMouse(context, {
    run = function(event: frame.HostMouseEvent): ()
      if event.kind == 'press' and event.button == button then
        looking = simulatorView() ~= nil
      elseif event.kind == 'release' and event.button == button then
        looking = false
      elseif event.kind == 'move' and looking and target then
        local view = simulatorView()
        local width, height = lovr.system.getWindowDimensions()
        if view and width > 0 and height > 0 then
          local yaw, pitch =
            head.drag(event.x - event.dx, event.y - event.dy, event.x, event.y, width, height, view, settings.lookScale)
          target = head.turn(target, yaw, pitch)
        end
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
      if looking or focusService:focused() == nil then
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
  requires = { frame.capability, focus.capability },
  schema = config.schema,
  init = init,
}
