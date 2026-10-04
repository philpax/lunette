-- Delivers keys and text after binding handlers. Keyboard input continues when the bindings provider is unavailable.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local focus = require '@lunette-contracts/focus'
local frame = require '@lunette-contracts/frame'
local keys = require '@lunette-contracts/keys'

local required: plugin.Declaration = {
  focus = focus.capability,
  frame = frame.capability,
}

local function heldModifiers(): { string }
  return keys.heldModifiers { isDown = lovr.system.isKeyDown, shift = false }
end

return plugin.define {
  name = 'desktop/input',
  requires = required,
  init = function(context: plugin.Context, config: {}, _publish: plugin.Publisher): ()
    plugin.options { name = 'desktop/input', defaults = {}, config = config }
    local frameService: frame.Service = context:require(frame.capability)
    local service: focus.Service = context:require(focus.capability)
    local function focused(): (lunette.Seat?, lunette.Sink?)
      local seat, sink = service:focused()
      if not seat or seat.dead or not sink or sink.dead then
        return nil, nil
      end
      return seat, sink
    end
    local function stroke(keycode: number, modifiers: { string }): ()
      local seat, sink = focused()
      if not seat or not sink then
        return
      end
      if #modifiers > 0 then
        sink:modifiers(modifiers, seat)
      end
      sink:key(keycode, true, seat)
      sink:key(keycode, false, seat)
      if #modifiers > 0 then
        sink:modifiers({}, seat)
      end
    end
    frameService:onKey(context, {
      phase = 'delivery',
      run = function(event: frame.KeyEvent): boolean?
        local key = event.key
        local held = heldModifiers()
        local named = keys.FROM_LOVR[key]
        if named then
          stroke(named, held)
        elseif #held > 0 and #key == 1 then
          local seat = focused()
          local found = seat and seat:strokeFor(key)
          if found then
            stroke(found.keycode, held)
          end
        end
        return nil
      end,
    })
    frameService:onText(context, {
      phase = 'delivery',
      run = function(event: frame.TextEvent): boolean?
        local seat, sink = focused()
        if not seat or not sink or #heldModifiers() > 0 then
          return nil
        end
        for character in event.text:gmatch '.' do
          local found = seat:strokeFor(character)
          if found then
            stroke(found.keycode, found.modifiers or {})
          end
        end
        return nil
      end,
    })
  end,
}
