-- Desktop keyboard input: bindings first, then the focused seat.
--
-- Every key press is offered to the bindings broker in the frame provider's
-- binding phase, with the modifiers the desktop keyboard holds, and a press a
-- binding matches goes no further. Other keys and text go to the sink
-- lunette/focus answers, in the delivery phase. The consumer takes no
-- options.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local bindings = require '@lunette-contracts/bindings'
local focus = require '@lunette-contracts/focus'
local frame = require '@lunette-contracts/frame'
local keys = require '@lunette-contracts/keys'

local required: plugin.Declaration = {
  bindings = bindings.capability,
  focus = focus.capability,
  frame = frame.capability,
}

local function heldModifiers(): { string }
  local held: { string } = {}
  for _, entry in ipairs(keys.LOVR_MODIFIERS) do
    for _, name in ipairs(entry.keys) do
      if lovr.system.isKeyDown(name) then
        held[#held + 1] = entry.modifier
        break
      end
    end
  end
  return held
end

-- The modifiers a chord is matched against: those forwarded with a key, and
-- shift, which forwarding leaves to the seat's stroke for each character.
local function chordModifiers(): { string }
  local held = heldModifiers()
  if lovr.system.isKeyDown 'lshift' or lovr.system.isKeyDown 'rshift' then
    held[#held + 1] = 'shift'
  end
  return held
end

return plugin.define {
  name = 'desktop/input',
  requires = required,
  init = function(context: plugin.Context, config: {}, _publish: plugin.Publisher): ()
    -- The consumer takes no options, so any option is a mistake worth naming.
    plugin.options { name = 'desktop/input', defaults = {}, config = config }
    local frameService: frame.Service = context:require(frame.capability)
    local bindingService: bindings.Service = context:require(bindings.capability)
    local service: focus.Service = context:require(focus.capability)
    -- The focused seat and sink, or nothing when either has died since focus
    -- was given: a handle does not survive its native object.
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
      phase = 'binding',
      run = function(event: frame.KeyEvent): boolean?
        return bindingService:dispatch {
          key = event.key,
          modifiers = chordModifiers(),
          isRepeat = event.isRepeat,
        }
      end,
    })
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
