local schema = require '@lunette-plugin/schema'

local namedKeys: { [string]: boolean } = {}
for _, name in ipairs {
  'space',
  'return',
  'tab',
  'escape',
  'backspace',
  'up',
  'down',
  'left',
  'right',
  'home',
  'end',
  'pageup',
  'pagedown',
  'insert',
  'delete',
  'kp.',
  'kp/',
  'kp*',
  'kp-',
  'kp+',
  'kpenter',
  'kp=',
  'lctrl',
  'lshift',
  'lalt',
  'lgui',
  'rctrl',
  'rshift',
  'ralt',
  'rgui',
  'capslock',
  'scrolllock',
  'numlock',
} do
  namedKeys[name] = true
end
local key = schema.custom<<KeyCode>> {
  runtimeType = 'string',
  validate = function(value: unknown): KeyCode
    assert(type(value) == 'string', 'a key is a supported key name')
    local name = value :: string
    local single = #name == 1 and (name:match '^[a-z0-9]$' ~= nil or string.find("`-=[]\\;',./", name, 1, true) ~= nil)
    local number = name:match '^f(%d+)$'
    local functionKey = number ~= nil
      and tonumber(number) ~= nil
      and (tonumber(number) :: number) >= 1
      and (tonumber(number) :: number) <= 12
      and name == 'f' .. tostring(tonumber(number))
    local keypad = name:match '^kp[0-9]$' ~= nil
    assert(single or functionKey or keypad or namedKeys[name], 'a key is a supported key name, not ' .. name)
    return name :: KeyCode
  end,
}
-- Typed constructor aliases keep the checker from expanding KeyCode at every wrapper.
local defaultKey = (
  schema.default :: unknown
) :: (schema.Schema<KeyCode, KeyCode>) -> (KeyCode) -> schema.Schema<KeyCode?, KeyCode>
local reloadShape: {
  read key: schema.Schema<KeyCode?, KeyCode>,
  read modifiers: schema.Schema<{ string }?, { read [number]: string }>,
} =
  {
    key = defaultKey(key) 'f5',
    modifiers = schema.default(schema.array(schema.string())) {},
  }
local reload = schema.object<<typeof(reloadShape)>>(reloadShape)
type ReloadConfig = schema.Input<typeof(reload)>
type ReloadSettings = schema.Output<typeof(reload)>
local defaultReload = (
  schema.default :: unknown
) :: (schema.Schema<ReloadConfig, ReloadSettings>) -> (ReloadSettings) -> schema.Schema<ReloadConfig?, ReloadSettings>
local shape: { read reload: schema.Schema<ReloadConfig?, ReloadSettings> } = {
  reload = defaultReload((reload :: unknown) :: schema.Schema<ReloadConfig, ReloadSettings>)(reload.parse {}),
}
local descriptor = schema.object<<typeof(shape)>>(shape)

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = (descriptor :: unknown) :: schema.Schema<Config, Settings>, key = key }
