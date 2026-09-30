-- Desktop keyboard input follows the interaction provider's focused seat.
local lunette = require '@lunette'
local plugin = require '@lunette-plugin'
local interaction = require '@lunette-contracts/interaction'
local callbackModule = require '../desktop/callbacks'
local logging = require '../desktop/logging'
export type Config = { read callbacks: typeof(callbackModule) }

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
local required: plugin.Declaration = { interaction = interaction.capability }

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

return plugin.define(
  function(config: Config): Config
    return config
  end,
  required,
  {},
  function(context: plugin.Context, config: Config, _publish: plugin.Publisher): ()
    local callbacks = config.callbacks
    local service: interaction.Service = context:require(interaction.capability)
    local function stroke(keycode: number, modifiers: { string }): ()
      local seat, sink = service:focused()
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
    callbacks.onKeypressed(context, function(key: KeyCode, _scancode: number, _isrepeat: boolean)
      if key == 'f5' then
        local reloaded, message = lunette.reload()
        if not reloaded then
          logging.report('configuration was not reloaded: ' .. tostring(message), 'error')
        end
        return
      end
      local held = heldModifiers()
      local named = NAMED_KEYS[key]
      if named then
        stroke(named, held)
      elseif #held > 0 and #key == 1 then
        local seat = service:focused()
        local found = seat and seat:strokeFor(key)
        if found then
          stroke(found.keycode, held)
        end
      end
    end)
    callbacks.onTextinput(context, function(text: string, _code: number)
      local seat, sink = service:focused()
      if not seat or not sink or #heldModifiers() > 0 then
        return
      end
      for character in text:gmatch '.' do
        local found = seat:strokeFor(character)
        if found then
          stroke(found.keycode, found.modifiers or {})
        end
      end
    end)
  end
)
