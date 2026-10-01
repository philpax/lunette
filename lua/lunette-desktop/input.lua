-- Desktop keyboard input follows the interaction provider's focused seat.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local frame = require '@lunette-contracts/frame'
local interaction = require '@lunette-contracts/interaction'
local logging = require '@lunette-desktop/logging'

local NAMED_KEYS = {
  backspace = 14,
  ['return'] = 28,
  kpenter = 28,
  escape = 1,
  tab = 15,
  up = 103,
  down = 108,
  left = 105,
  right = 106,
  home = 102,
  ['end'] = 107,
  pageup = 104,
  pagedown = 109,
  delete = 111,
  insert = 110,
}
local MODIFIERS: { { names: { KeyCode }, modifier: string } } = {
  { names = { 'lctrl', 'rctrl' }, modifier = 'control' },
  { names = { 'lalt', 'ralt' }, modifier = 'alt' },
  { names = { 'lgui', 'rgui' }, modifier = 'logo' },
}
local required: plugin.Declaration = { frame = frame.capability, interaction = interaction.capability }

local function heldModifiers(): { string }
  local held: { string } = {}
  for _, entry in ipairs(MODIFIERS) do
    for _, name in ipairs(entry.names) do
      if lovr.system.isKeyDown(name) then
        held[#held + 1] = entry.modifier
        break
      end
    end
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
    local service: interaction.Service = context:require(interaction.capability)
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
    -- The reload key is a binding, so it is consumed before delivery and a
    -- binding another plugin registers can take a key before the client does.
    frameService:onKey(context, {
      phase = 'binding',
      run = function(event: frame.KeyEvent): boolean?
        if event.key ~= 'f5' then
          return nil
        end
        local reloaded, message = lunette.reload()
        if not reloaded then
          logging.report('configuration was not reloaded: ' .. tostring(message), 'error')
        end
        return true
      end,
    })
    frameService:onKey(context, {
      phase = 'delivery',
      run = function(event: frame.KeyEvent): boolean?
        local key = event.key
        local held = heldModifiers()
        local named = NAMED_KEYS[key]
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
