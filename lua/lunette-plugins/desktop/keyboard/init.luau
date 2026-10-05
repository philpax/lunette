-- The wrist button controls this consumer's keyboard and directs its haptic pulse to the pressing pointer.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local keyboard = require '@lunette-contracts/keyboard'
local quad = require '@lunette-contracts/quad'
local surface = require '@lunette-contracts/surface'
local surfaces = require '@lunette-contracts/surfaces'

local config = require '@lunette-plugins/desktop/keyboard/config'

export type Hand = config.Hand
export type Config = config.Config
export type Settings = config.Settings

local DEVICES: { [Hand]: Device } = { left = 'hand/left', right = 'hand/right' }

local required: plugin.Declaration = {
  frame = frame.capability,
  keyboard = keyboard.capability,
  surfaces = surfaces.capability,
}

return plugin.consumer<<Config, Settings>>({
  name = 'desktop/keyboard',
  requires = required,
  schema = config.schema,
  init = function(context: plugin.Context, settings: Settings): ()
    local device = DEVICES[settings.hand]
    local size, offset, placement = settings.size, settings.offset, settings.placement
    local frameService: frame.Service = context:require(frame.capability)
    local surfaceService: surfaces.Service = context:require(surfaces.capability)
    local service: keyboard.Service = context:require(keyboard.capability)
    local virtualKeyboard: keyboard.Keyboard? = nil
    local tracked = false
    local pose = lovr.math.newMat4()

    local function showing(): keyboard.Keyboard?
      local target = virtualKeyboard
      if target and target.visible and not target.dead then
        return target
      end
      return nil
    end
    local function placeKeyboard(target: keyboard.Keyboard): ()
      local head = vector.pack(lovr.headset.getPosition 'head')
      local forwardX, _, forwardZ = lovr.headset.getDirection 'head'
      local flat = vector.pack(forwardX, 0, forwardZ)
      if flat:length() < 0.001 then
        flat = vector.pack(0, 0, -1)
      end
      flat = flat:normalize()
      local position = head + flat * placement.distance - vector.pack(0, placement.drop, 0)
      target:setPose(
        lovr.math
          .newMat4()
          :translate(position)
          :rotate(math.atan2(-flat.x, -flat.z), 0, 1, 0)
          :rotate(-placement.tilt, 1, 0, 0)
      )
    end
    local function getKeyboard(): keyboard.Keyboard
      local target = virtualKeyboard
      if target and not target.dead then
        return target
      end
      local created = service:new(context, {})
      created:setVisible(false)
      virtualKeyboard = created
      return created
    end
    local function toggle(pointer: surface.Pointer): ()
      local target = getKeyboard()
      local show = not target.visible
      target:setVisible(show)
      if show then
        placeKeyboard(target)
      end
      pointer:vibrate(settings.haptic)
    end
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
        if not tracked then
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
        if not tracked then
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
        if event.kind == 'press' and event.button == 'left' and event.inside and tracked then
          toggle(event.pointer)
        end
      end,
    }
    surfaceService:offer(context, {
      name = 'desktop/keyboard',
      list = function(): { surface.Surface }
        local result: { surface.Surface } = {}
        tracked = lovr.headset.isTracked(device)
        if tracked then
          local x, y, z, angle, ax, ay, az = lovr.headset.getPose(device)
          pose:set(lovr.math.newMat4(x, y, z, angle, ax, ay, az))
          pose:translate(offset):rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
          result[#result + 1] = wrist
        end
        local target = showing()
        if target then
          result[#result + 1] = target
        end
        return result
      end,
    })
    -- The scene phase follows panel drawing, and this consumer draws its own keyboard.
    frameService:onDraw(context, {
      phase = 'scene',
      order = 1,
      run = function(pass: Pass)
        if tracked then
          if showing() then
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
        local target = showing()
        if target then
          target:draw(pass)
        end
      end,
    })
  end,
}).definition
