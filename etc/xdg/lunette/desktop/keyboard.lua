-- The left-wrist keyboard button and its lazily created keyboard.
local plugin = require '@lunette-plugin'
local keyboard = require '@lunette-contracts/keyboard'
local panels = require '@lunette-contracts/panels'
local surface = require '@lunette-contracts/surface'
local callbackModule = require '../desktop/callbacks'
export type Config = { read callbacks: typeof(callbackModule) }

local required: plugin.Declaration = { keyboard = keyboard.capability, panels = panels.capability }
local HAND: Device = 'hand/left'
local SIZE = 0.115

return plugin.define(
  function(config: Config): Config
    return config
  end,
  required,
  {},
  function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local callbacks = config.callbacks
    local service: keyboard.Service = context:require(keyboard.capability)
    local panelService: panels.Service = context:require(panels.capability)
    local virtualKeyboard: keyboard.Keyboard? = nil
    local tracked = false
    local pose = lovr.math.newMat4()

    local function placeKeyboard(target: surface.Surface): ()
      local hx, hy, hz = lovr.headset.getPosition 'head'
      local forwardX, _, forwardZ = lovr.headset.getDirection 'head'
      local flat = vector.pack(forwardX, 0, forwardZ)
      if flat:length() < 0.001 then
        flat = vector.pack(0, 0, -1)
      end
      flat:normalize()
      local setPose = target.setPose
      if setPose then
        setPose(
          target,
          lovr.math
            .newMat4()
            :translate(hx + flat.x * 0.55, hy - 0.35, hz + flat.z * 0.55)
            :rotate(math.atan2(-flat.x, -flat.z), 0, 1, 0)
            :rotate(-math.pi / 6, 1, 0, 0)
        )
      end
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
    local function toggle(): ()
      local target = getKeyboard()
      local showing = not target.visible
      target:setVisible(showing)
      if showing then
        placeKeyboard(target)
      end
      lovr.headset.vibrate(HAND, 0.3, 0.05, 0)
    end
    local wrist: surface.Surface = {
      dead = false,
      grabbable = false,
      width = SIZE,
      height = SIZE,
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
        return panelService:rayQuadHit({
          pose = pose,
          width = SIZE,
          height = SIZE,
          pixelWidth = 1,
          pixelHeight = 1,
          backFace = true,
        }, origin, direction)
      end,
      onPress = function(_self: surface.Surface, _x: number?, _y: number?, _pointer: surface.Pointer): ()
        toggle()
      end,
    }
    callbacks.onSurfaces(context, function(): { surface.Surface }
      local result: { surface.Surface } = {}
      local function add(value: surface.Surface): ()
        result[#result + 1] = value
      end
      tracked = lovr.headset.isTracked(HAND)
      if tracked then
        local x, y, z, angle, ax, ay, az = lovr.headset.getPose(HAND)
        pose:set(lovr.math.newMat4(x, y, z, angle, ax, ay, az))
        pose:translate(-0.03, -0.01, 0.125):rotate(math.pi, -0.7071066, 0.0007963618, 0.7071066)
        add(wrist)
      end
      if virtualKeyboard and virtualKeyboard.visible and not virtualKeyboard.dead then
        add(virtualKeyboard)
      end
      return result
    end)
    callbacks.onDraw(context, function(pass: Pass)
      if tracked then
        local showing = virtualKeyboard and virtualKeyboard.visible and not virtualKeyboard.dead
        if showing then
          pass:setColor(0.35, 0.75, 0.45, 1)
        else
          pass:setColor(0.2, 0.2, 0.24, 1)
        end
        pass:plane(lovr.math.mat4(pose):scale(SIZE, SIZE, 1), 'fill', 1, 1)
        pass:setColor(1, 1, 1, 1)
        pass:text(
          'kbd',
          lovr.math.mat4(pose):translate(0, 0, 0.002):scale(vector.pack(SIZE * 0.35)),
          0,
          'center',
          'middle'
        )
      end
      service:draw(pass)
    end, 200)
  end
)
