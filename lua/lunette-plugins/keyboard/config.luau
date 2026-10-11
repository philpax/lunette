local lunette = require '@lunette'
local schema = require '@lunette-plugin/schema'
local keys = require '@lunette-contracts/keys'
local board = require '@lunette-plugins/keyboard/board'
local rows = require '@lunette-plugins/keyboard/rows'
local appearance = require '@lunette-plugins/keyboard/appearance'
local validation = require '@lunette-plugins/keyboard/validation'

local function onKey(target: board.Board, key: board.RenderedKey, pointer: board.Pointer, base: board.Press): ()
  base(target, key, pointer)
end
local function drawKey(pass: Pass, key: board.RenderedKey, state: board.KeyState, base: board.Paint): ()
  base(pass, key, state)
end

local MODIFIER = schema.enum<<lunette.ModifierName>>(lunette.modifierNames())
local MODIFIER_NAMES: { [string]: boolean } = {}
for _, name in lunette.modifierNames() do
  MODIFIER_NAMES[name] = true
end

local ACTION = schema.union {
  schema.object { kind = schema.literal<<'hide'>> 'hide' },
  schema.object { kind = schema.literal<<'layer'>> 'layer', layer = schema.string() },
  schema.object { kind = schema.literal<<'text'>> 'text', text = schema.string() },
  schema.object {
    kind = schema.literal<<'chord'>> 'chord',
    code = schema.number { minimum = 0, integer = true },
    modifiers = schema.array(MODIFIER),
  },
  schema.object { kind = schema.literal<<'custom'>> 'custom', name = schema.string() },
}
local KEY = schema.object {
  code = schema.optional(schema.number { minimum = 0, integer = true }),
  action = schema.optional(ACTION),
  label = schema.optional(schema.string()),
  width = schema.optional(schema.number { positive = true }),
  height = schema.optional(schema.number { positive = true }),
  x = schema.optional(schema.number { minimum = 0 }),
}
local ROWS = schema.array(schema.array(KEY))
local STYLE = appearance.editableStyle
local MODIFIER_KEYS = schema.custom<<{ read [number]: lunette.ModifierName }>> {
  runtimeType = 'table',
  validate = function(value: unknown): { read [number]: lunette.ModifierName }
    assert(type(value) == 'table' and getmetatable(value) == nil, 'modifierKeys is a plain table keyed by evdev codes')
    for code, modifier in value :: { read [unknown]: unknown } do
      assert(
        type(code) == 'number' and code >= 0 and code % 1 == 0 and code < math.huge,
        'modifierKeys is keyed by evdev codes'
      )
      assert(type(modifier) == 'string' and MODIFIER_NAMES[modifier], 'modifierKeys contains modifier names')
    end
    return value :: { read [number]: lunette.ModifierName }
  end,
}
local function defaultCallback<F>(callback: F): schema.Schema<F?, F>
  return schema.default(schema.callback(callback))(callback)
end
type ConfigurationShape<K, D> = {
  rows: schema.Schema<schema.Input<typeof(ROWS)>?, schema.Output<typeof(ROWS)>>,
  layers: schema.Schema<{ [string]: schema.Input<typeof(ROWS)> }?, { read [string]: schema.Output<typeof(ROWS)> }>,
  style: schema.Schema<schema.Input<typeof(STYLE)>?, schema.Output<typeof(STYLE)>>,
  modifierKeys: schema.Schema<schema.Input<typeof(MODIFIER_KEYS)>?, schema.Output<typeof(MODIFIER_KEYS)>>,
  locks: schema.Schema<{ lunette.ModifierName }?, { read [number]: lunette.ModifierName }>,
  onKey: schema.Schema<K?, K>,
  drawKey: schema.Schema<D?, D>,
}
type Configuration<K, D> = schema.Schema<
  schema.ObjectInput<ConfigurationShape<K, D>>,
  schema.ObjectOutput<ConfigurationShape<K, D>>
>
local function configuration<K, D>(keyHook: K, drawHook: D): Configuration<K, D>
  return schema.object {
    rows = schema.default(ROWS)(rows),
    layers = schema.default(schema.map(ROWS)) {},
    style = schema.default(STYLE)(
      STYLE.parse { keyUnit = 0.028, plateDepth = 0.002, legendDepth = 0.001, margin = 0.008 }
    ),
    modifierKeys = schema.default(MODIFIER_KEYS)(keys.MODIFIER_KEYS),
    locks = schema.default(schema.array(MODIFIER))(lunette.lockingModifierNames()),
    onKey = defaultCallback(keyHook),
    drawKey = defaultCallback(drawHook),
  }
end
local function described<K, D>(keyHook: K, drawHook: D): Configuration<K, D>
  -- Rows and layers refer to one another, so they are checked together.
  local descriptor = schema.refine(configuration(keyHook, drawHook))(
    function(settings: schema.ObjectOutput<ConfigurationShape<K, D>>): ()
      validation.settings(settings :: any)
    end
  )
  type Input = schema.Input<typeof(descriptor)>
  type Output = schema.Output<typeof(descriptor)>
  local named: schema.Schema<Input, Output> = descriptor
  return named
end
local SCHEMA = described<<board.OnKey, board.DrawKey>>(onKey, drawKey)

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return { schema = SCHEMA }
