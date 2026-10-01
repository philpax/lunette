-- A keyboard provider written from nothing: one row of three keys. It
-- implements the lunette/keyboard contract itself, so main.lua can put it in
-- the keyboard entry's place as it does split.lua.
local plugin = require '@lunette-plugin'
local keyboard = require '@lunette-contracts/keyboard'
local focusContract = require '@lunette-contracts/focus'
local quad = require '@lunette-contracts/quad'
local keys = require '@lunette-contracts/keys'

local CODES = { keys.CODES.y, keys.CODES.n, keys.CODES.enter }
local KEY = 0.05

local function make(focus: focusContract.Service, options: keyboard.Options?): keyboard.Keyboard
  local state = {
    kind = nil,
    dead = false,
    grabbable = true,
    pose = lovr.math.newMat4(options and options.pose or lovr.math.mat4()),
    width = KEY * #CODES,
    height = KEY,
    visible = true,
  }
  local function pressKey(_self: keyboard.Keyboard, code: number): boolean
    local seat, sink = focus:focused()
    if state.dead or not sink or sink.dead then
      return false
    end
    sink:key(code, true, seat)
    sink:key(code, false, seat)
    return true
  end
  local board: keyboard.Keyboard
  local methods = {
    raycast = function(
      _self: keyboard.Surface,
      origin: vector,
      direction: vector,
      backFace: boolean?
    ): (number?, number?, number?)
      if state.dead or not state.visible then
        return nil, nil, nil
      end
      return quad.hit({
        pose = state.pose,
        width = state.width,
        height = state.height,
        pixelWidth = state.width,
        pixelHeight = state.height,
        backFace = backFace,
      }, origin, direction)
    end,
    setPose = function(_self: keyboard.Surface, pose: Mat4)
      state.pose:set(pose)
    end,
    setSize = function(_self: keyboard.Surface, _width: number?, _height: number?) end,
    onHover = function(_self: keyboard.Surface, _x: number?, _y: number?, _pointer: keyboard.Pointer) end,
    onLeave = function(_self: keyboard.Surface, _pointer: keyboard.Pointer) end,
    onPress = function(_self: keyboard.Surface, x: number?, _y: number?, pointer: keyboard.Pointer)
      local code = if x then CODES[math.floor(x / KEY) + 1] else nil
      if code then
        pointer:vibrate { strength = 0.2, duration = 0.01 }
        pressKey(board, code)
      end
    end,
    setVisible = function(_self: keyboard.Keyboard, visible: boolean)
      state.visible = visible
    end,
    pressKey = pressKey,
    typeText = function(_self: keyboard.Keyboard, text: string): boolean
      local seat, sink = focus:focused()
      return not state.dead and sink ~= nil and not sink.dead and sink:typeText(text, seat)
    end,
    modifiers = function(_self: keyboard.Keyboard): { string }
      return {}
    end,
    draw = function(_self: keyboard.Keyboard, pass: Pass)
      if state.dead or not state.visible then
        return
      end
      for index, code in ipairs(CODES) do
        local centre = lovr.math.mat4(state.pose):translate((index - 0.5) * KEY - state.width / 2, 0, 0)
        pass:plane(lovr.math.mat4(centre):scale(KEY * 0.9, KEY * 0.9, 1), 'fill')
        pass:text(tostring(code), lovr.math.mat4(centre):translate(0, 0, 0.001):scale(KEY * 0.4), 0, 'center', 'middle')
      end
    end,
    destroy = function(_self: keyboard.Keyboard): boolean
      if state.dead then
        return false
      end
      state.dead = true
      return true
    end,
  }
  board = setmetatable(state, { __index = methods })
  return board
end

return plugin.define {
  name = 'tiny-keyboard',
  requires = { focus = focusContract.capability },
  provides = { keyboard = keyboard.capability },
  init = function(context: plugin.Context, _config: {}, publish: plugin.Publisher)
    local focus: focusContract.Service = context:require(focusContract.capability)
    publish:provide(keyboard.capability, {
      new = function(_self: keyboard.Service, owner: keyboard.Owner, options: keyboard.Options?): keyboard.Keyboard
        local made: keyboard.Keyboard? = nil
        context:acquire(owner, function()
          local board = make(focus, options)
          made = board
          return function()
            board:destroy()
          end
        end)
        return assert(made, 'the keyboard was acquired')
      end,
    })
  end,
}
