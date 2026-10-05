-- The provider implements the keyboard contract with three keys.
local plugin = require '@lunette-plugin'
local keyboard = require '@lunette-contracts/keyboard'
local focusContract = require '@lunette-contracts/focus'
local quad = require '@lunette-contracts/quad'
local keys = require '@lunette-contracts/keys'
local schema = require '@lunette-plugin/schema'
local inspection = require '@lunette-contracts/inspection'
local protected = require '@lunette-plugins/protected'

local descriptor = schema.object {}
export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

local CODES = { keys.CODES.y, keys.CODES.n, keys.CODES.enter }
local KEY = 0.05

local function make(
  source: focusContract.Source,
  options: keyboard.Options?,
  notify: (keyboard.VisibilityChange) -> (),
  dispose: () -> ()
): (keyboard.Keyboard, () -> ())
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
    return not state.dead and source:key({ code = code, modifiers = {}, isRepeat = false }).kind == 'consumed'
  end
  local function destroyState(): ()
    state.dead, state.visible = true, false
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
      if not state.dead then
        state.pose:set(pose)
      end
    end,
    setSize = function(_self: keyboard.Surface, _width: number?, _height: number?) end,
    onHover = function(_self: keyboard.Surface, _x: number?, _y: number?, _pointer: keyboard.Pointer) end,
    onLeave = function(_self: keyboard.Surface, _pointer: keyboard.Pointer) end,
    onPress = function(_self: keyboard.Surface, x: number?, _y: number?, pointer: keyboard.Pointer)
      if state.dead then
        return
      end
      local code = if x then CODES[math.floor(x / KEY) + 1] else nil
      if code then
        pointer:vibrate { strength = 0.2, duration = 0.01 }
        pressKey(board, code)
      end
    end,
    setVisible = function(_self: keyboard.Keyboard, visible: boolean)
      if state.dead or state.visible == visible then
        return
      end
      state.visible = visible
      if not visible then
        source:reset()
      end
      notify { visible = visible, reason = if visible then 'show' else 'hide' }
    end,
    pressKey = pressKey,
    typeText = function(_self: keyboard.Keyboard, text: string): boolean
      return not state.dead and source:text(text).kind == 'consumed'
    end,
    modifiers = function(_self: keyboard.Keyboard): { string }
      return {}
    end,
    draw = function(_self: keyboard.Keyboard, pass: Pass)
      if state.dead or not state.visible then
        return
      end
      local seat = source:keymapSeat()
      for index, code in ipairs(CODES) do
        local centre = lovr.math.mat4(state.pose):translate((index - 0.5) * KEY - state.width / 2, 0, 0)
        local legend = if seat then seat:characterFor(code, {}) else nil
        pass:plane(lovr.math.mat4(centre):scale(KEY * 0.9, KEY * 0.9, 1), 'fill')
        pass:text(legend or tostring(code), lovr.math.mat4(centre):translate(0, 0, 0.001):scale(KEY * 0.4))
      end
    end,
    destroy = function(_self: keyboard.Keyboard): boolean
      if state.dead then
        return false
      end
      dispose()
      return true
    end,
  }
  board = setmetatable(state, { __index = methods })
  return board, destroyState
end

return plugin.provider<<Config, Settings, keyboard.Service>>({
  name = 'tiny-keyboard',
  requires = { focus = focusContract.capability },
  capability = keyboard.capability,
  schema = descriptor,
  build = function(context: plugin.Context, _settings: Settings): keyboard.Service
    local focus: focusContract.Service = context:require(focusContract.capability)
    local boards: { [keyboard.Keyboard]: keyboard.Owner } = {}
    return {
      inspect = function(_self: keyboard.Service): inspection.Snapshot
        local registrations: { inspection.Registration } = {}
        for board, owner in boards do
          registrations[#registrations + 1] =
            inspection.registration('keyboard', 'tiny-keyboard', owner, nil, not board.dead)
        end
        return inspection.snapshot(registrations)
      end,
      new = function(_self: keyboard.Service, owner: keyboard.Owner, options: keyboard.Options?): keyboard.Keyboard
        local callback = options and options.onVisibilityChanged
        if callback ~= nil and type(callback) ~= 'function' then
          error('tiny-keyboard: onVisibilityChanged is a function', 2)
        end
        local label = 'tiny-keyboard visibility (' .. plugin.ownerLabel(owner) .. ')'
        local function notify(change: keyboard.VisibilityChange): ()
          local run = callback
          if change.reason == 'destroy' then
            callback = nil
          end
          if run then
            protected.call(label, function(): ()
              run(change)
            end)
          end
        end
        local cleanupEffect: plugin.Effect? = nil
        local board, acquired = context:resource(owner, function(): (keyboard.Keyboard, () -> ())
          local source = focus:newSource(context, { mode = 'virtual', nativeTarget = options and options.target })
          local made: keyboard.Keyboard? = nil
          local destroyBoard: (() -> ())? = nil
          local ok, failure = pcall(function(): ()
            made, destroyBoard = make(source, options, notify, function(): ()
              local effect = cleanupEffect
              cleanupEffect = nil
              if effect then
                effect:dispose()
              end
            end)
          end)
          if not ok then
            callback = nil
            if destroyBoard then
              destroyBoard()
            end
            protected.call(label .. ': partial source cleanup', function(): ()
              source:destroy()
            end)
            error(failure, 0)
          end
          local created, destroyState = made :: keyboard.Keyboard, destroyBoard :: () -> ()
          boards[created] = owner
          return created,
            function(): ()
              if created.dead then
                return
              end
              destroyState()
              boards[created] = nil
              cleanupEffect = nil
              local cleaned, failure = pcall(function(): ()
                source:destroy()
              end)
              notify { visible = false, reason = 'destroy' }
              if not cleaned then
                error(failure, 0)
              end
            end
        end)
        if not board.dead then
          cleanupEffect = acquired
        end
        return board
      end,
    }
  end,
}).definition
