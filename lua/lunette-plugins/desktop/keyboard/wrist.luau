-- The compatibility wrist button controls the display and directs its haptic pulse to the pressing pointer.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local display = require '@lunette-contracts/keyboard-display'
local quad = require '@lunette-contracts/quad'
local surface = require '@lunette-contracts/surface'
local surfaces = require '@lunette-contracts/surfaces'
local config = require '@lunette-plugins/desktop/keyboard/config'

local DEVICES: { [config.Hand]: Device } = { left = 'hand/left', right = 'hand/right' }

return function(context: plugin.Context, settings: config.Settings, service: display.Service): ()
  local device = DEVICES[settings.hand]
  local size, offset = settings.size, settings.offset
  local frameService: frame.Service = context:require(frame.capability)
  local surfaceService: surfaces.Service = context:require(surfaces.capability)
  local tracked, dead = false, false
  local pose = lovr.math.newMat4()
  local wrist: surface.Surface = {
    dead = false,
    grabbable = false,
    width = size,
    height = size,
    pose = pose,
    raycast = function(
      _self: surface.Surface,
      origin: vector,
      direction: vector,
      _backFace: boolean?
    ): (number?, number?, number?)
      if dead or not tracked then
        return nil, nil, nil
      end
      return quad.hit({
        pose = pose,
        width = size,
        height = size,
        pixelWidth = 1,
        pixelHeight = 1,
        backFace = true,
      }, origin, direction)
    end,
    project = function(_self: surface.Surface, origin: vector, direction: vector): (number?, number?, number?)
      if dead or not tracked then
        return nil, nil, nil
      end
      return quad.project({
        pose = pose,
        width = size,
        height = size,
        pixelWidth = 1,
        pixelHeight = 1,
        backFace = true,
      }, origin, direction)
    end,
    onPointer = function(_self: surface.Surface, event: surface.PointerEvent): ()
      if not dead and event.kind == 'press' and event.button == 'left' and event.inside and tracked then
        service:toggle()
        event.pointer:vibrate(settings.haptic)
      end
    end,
  }
  context:effect(function(): () -> ()
    return function(): ()
      dead, tracked = true, false
    end
  end)
  surfaceService:offer(context, {
    name = 'desktop/keyboard',
    list = function(): { surface.Surface }
      tracked = not dead and lovr.headset.isTracked(device)
      if tracked then
        local x, y, z, angle, ax, ay, az = lovr.headset.getPose(device)
        pose:set(lovr.math.newMat4(x, y, z, angle, ax, ay, az))
        pose:translate(offset):rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
        return { wrist }
      end
      return {}
    end,
  })
  frameService:onDraw(context, {
    phase = 'scene',
    order = 1,
    run = function(pass: Pass): ()
      if tracked and not dead then
        if service:isVisible() then
          pass:setColor(0.35, 0.75, 0.45, 1)
        else
          pass:setColor(0.2, 0.2, 0.24, 1)
        end
        pass:plane(lovr.math.mat4(pose):scale(size, size, 1), 'fill', 1, 1)
        pass:setColor(1, 1, 1, 1)
        pass:text(
          'kbd',
          lovr.math.mat4(pose):translate(0, 0, 0.002):scale(vector.pack(size * 0.35)),
          0,
          'center',
          'middle'
        )
      end
    end,
  })
end
