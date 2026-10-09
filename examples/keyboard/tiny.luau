-- The provider implements the keyboard contract with three keys.
local plugin = require '@lunette-plugin'
local keyboard = require '@lunette-contracts/keyboard'
local focusContract = require '@lunette-contracts/focus'
local quad = require '@lunette-contracts/quad'
local vocabulary = require '@lunette-contracts/vocabulary'
local keys = require '@lunette-contracts/keys'
local inspection = require '@lunette-contracts/inspection'
local protected = require '@lunette-plugins/protected'

export type Config = {}
export type Settings = {}

local CODES = { keys.CODES.y, keys.CODES.n, keys.CODES.enter }
local KEY = 0.05

return plugin.provider<<Config, Settings, keyboard.Service>>({
  name = 'tiny-keyboard',
  requires = { focus = focusContract.capability },
  capability = keyboard.capability,
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
        local label = 'tiny-keyboard visibility (' .. plugin.ownerLabel(owner) .. ')'
        local function notify(visible: boolean, reason: 'show' | 'hide' | 'destroy'): ()
          local run = callback
          if run then
            protected.call(label, function(): ()
              run { visible = visible, reason = reason }
            end)
          end
        end
        local state = {
          kind = nil,
          dead = false,
          grabbable = true,
          pose = lovr.math.newMat4(options and options.pose or lovr.math.mat4()),
          width = KEY * #CODES,
          height = KEY,
          visible = true,
        }
        local function geometry(backFace: boolean?): quad.Quad
          return {
            pose = state.pose,
            width = state.width,
            height = state.height,
            pixelWidth = state.width,
            pixelHeight = state.height,
            backFace = backFace,
          }
        end
        local source: focusContract.Source
        local effect: plugin.Effect? = nil
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
            return quad.hit(geometry(backFace), origin, direction)
          end,
          project = function(_self: keyboard.Surface, origin: vector, direction: vector): (number?, number?, number?)
            if state.dead or not state.visible then
              return nil, nil, nil
            end
            return quad.project(geometry(), origin, direction)
          end,
          onPointer = function(self: keyboard.Surface, event: vocabulary.PointerEvent): ()
            if event.kind ~= 'press' or event.button ~= 'left' or not event.inside or not event.x then
              return
            end
            local code = CODES[math.floor(event.x / KEY) + 1]
            if code and not state.dead and state.visible then
              event.pointer:vibrate { strength = 0.2, duration = 0.01 }
              source:key { code = code, modifiers = {}, isRepeat = false }
            end
          end,
          setPose = function(_self: keyboard.Surface, pose: Mat4)
            state.pose:set(pose)
          end,
          setSize = function(_self: keyboard.Surface, _width: number?, _height: number?) end,
          setVisible = function(_self: keyboard.Keyboard, visible: boolean)
            if state.dead or state.visible == visible then
              return
            end
            state.visible = visible
            if not visible then
              source:reset()
            end
            notify(visible, if visible then 'show' else 'hide')
          end,
          pressKey = function(_self: keyboard.Keyboard, code: number): boolean
            return not state.dead and source:key({ code = code, modifiers = {}, isRepeat = false }).kind == 'consumed'
          end,
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
            local acquired = effect
            if state.dead or not acquired then
              return false
            end
            acquired:dispose()
            return true
          end,
        }
        local board: keyboard.Keyboard = setmetatable(state, { __index = methods })
        -- The source is the only acquisition, so nothing is left to release if it raises.
        local _, acquired = context:resource(owner, function(): (focusContract.Source, () -> ())
          source = focus:newSource(context, { mode = 'virtual' })
          boards[board] = owner
          return source,
            function(): ()
              boards[board] = nil
              state.dead, state.visible = true, false
              source:destroy()
              notify(false, 'destroy')
            end
        end)
        effect = acquired
        return board
      end,
    }
  end,
}).definition
