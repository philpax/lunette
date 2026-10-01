-- The wrist keyboard button and its lazily created keyboard.
--
-- The button sits on one hand's wrist. Pressing it shows or hides a keyboard
-- in front of the head and pulses the hand that pressed it. The consumer
-- offers and draws only the keyboard it made, so another plugin's keyboard is
-- that plugin's to offer and draw.
--
-- `hand` is the wrist the button is on, `left` or `right`. `size` is the
-- button's edge in metres, and `offset` is where it sits in the hand's space.
-- `placement` puts the keyboard `distance` metres ahead of the head, `drop`
-- metres below it, tilted back by `tilt` radians. `haptic` is the pulse a
-- press gives.
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local keyboard = require '@lunette-contracts/keyboard'
local quad = require '@lunette-contracts/quad'
local surface = require '@lunette-contracts/surface'
local surfaces = require '@lunette-contracts/surfaces'

export type Hand = 'left' | 'right'

-- The resolved options.
export type Settings = {
  read hand: Hand,
  read size: number,
  read offset: { number },
  read placement: {
    read distance: number,
    read drop: number,
    read tilt: number,
  },
  read haptic: {
    read strength: number,
    read duration: number,
  },
}

-- What a configuration gives: every option optional.
export type Config = {
  read hand: Hand?,
  read size: number?,
  read offset: { number }?,
  read placement: {
    read distance: number?,
    read drop: number?,
    read tilt: number?,
  }?,
  read haptic: {
    read strength: number?,
    read duration: number?,
  }?,
}

local DEFAULTS: Settings = {
  hand = 'left',
  size = 0.115,
  offset = { -0.03, -0.01, 0.125 },
  placement = { distance = 0.55, drop = 0.35, tilt = math.pi / 6 },
  haptic = { strength = 0.3, duration = 0.05 },
}

local DEVICES: { [Hand]: Device } = { left = 'hand/left', right = 'hand/right' }

local required: plugin.Declaration = {
  frame = frame.capability,
  keyboard = keyboard.capability,
  surfaces = surfaces.capability,
}

-- The options merged over the defaults, with what the defaults cannot say
-- checked: the hand is one of two, and the offset is three numbers.
local function resolve(config: unknown): Settings
  local settings: Settings = plugin.options { name = 'desktop/keyboard', defaults = DEFAULTS, config = config }
  if DEVICES[settings.hand] == nil then
    error('plugin desktop/keyboard: option hand is left or right, not ' .. tostring(settings.hand), 0)
  end
  if #settings.offset ~= 3 then
    error('plugin desktop/keyboard: option offset is three numbers, not ' .. #settings.offset, 0)
  end
  for index = 1, 3 do
    if type(settings.offset[index]) ~= 'number' then
      error('plugin desktop/keyboard: option offset[' .. index .. '] is a number', 0)
    end
  end
  if settings.size <= 0 then
    error('plugin desktop/keyboard: option size is a positive number, not ' .. settings.size, 0)
  end
  return settings
end

return plugin.define {
  name = 'desktop/keyboard',
  requires = required,
  init = function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local settings = resolve(config)
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
      local hx, hy, hz = lovr.headset.getPosition 'head'
      local forwardX, _, forwardZ = lovr.headset.getDirection 'head'
      local flat = vector.pack(forwardX, 0, forwardZ)
      if flat:length() < 0.001 then
        flat = vector.pack(0, 0, -1)
      end
      flat:normalize()
      target:setPose(
        lovr.math
          .newMat4()
          :translate(hx + flat.x * placement.distance, hy - placement.drop, hz + flat.z * placement.distance)
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
      onPress = function(_self: surface.Surface, _x: number?, _y: number?, pointer: surface.Pointer): ()
        toggle(pointer)
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
          pose:translate(offset[1], offset[2], offset[3]):rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
          result[#result + 1] = wrist
        end
        local target = showing()
        if target then
          result[#result + 1] = target
        end
        return result
      end,
    })
    -- Drawn after the panels in the scene phase, as one of the scene's
    -- surfaces. Only this consumer's own keyboard is drawn here.
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
}
