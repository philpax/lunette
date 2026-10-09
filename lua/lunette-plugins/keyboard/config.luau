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

local ACTION = schema.union(
  schema.object { kind = schema.literal<<'hide'>> 'hide' },
  schema.union(
    schema.object { kind = schema.literal<<'layer'>> 'layer', layer = schema.string() },
    schema.union(
      schema.object { kind = schema.literal<<'text'>> 'text', text = schema.string() },
      schema.union(
        schema.object {
          kind = schema.literal<<'chord'>> 'chord',
          code = schema.number { minimum = 0, integer = true },
          modifiers = schema.array(schema.string()),
        },
        schema.object { kind = schema.literal<<'custom'>> 'custom', name = schema.string() }
      )
    )
  )
)
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
local MODIFIER_KEYS = schema.custom<<{ read [number]: string }>> {
  runtimeType = 'table',
  validate = function(value: unknown): { read [number]: string }
    assert(type(value) == 'table' and getmetatable(value) == nil, 'modifierKeys is a plain table keyed by evdev codes')
    for code, modifier in value :: { read [unknown]: unknown } do
      assert(
        type(code) == 'number' and code >= 0 and code % 1 == 0 and code < math.huge,
        'modifierKeys is keyed by evdev codes'
      )
      assert(type(modifier) == 'string', 'modifierKeys contains modifier names')
    end
    return value :: { read [number]: string }
  end,
}
local function defaultCallback<F>(callback: F): schema.Schema<F?, F>
  return schema.default(schema.callback(callback))(callback)
end
local function configuration<K, D>(keyHook: K, drawHook: D)
  return schema.object {
    rows = schema.default(ROWS)(rows),
    layers = schema.default(schema.map(ROWS)) {},
    style = schema.default(STYLE)(
      STYLE.parse { keyUnit = 0.028, plateDepth = 0.002, legendDepth = 0.001, margin = 0.008 }
    ),
    modifierKeys = schema.default(MODIFIER_KEYS)(keys.MODIFIER_KEYS),
    locks = schema.default(schema.array(schema.string()))(lunette.lockingModifierNames()),
    onKey = defaultCallback(keyHook),
    drawKey = defaultCallback(drawHook),
  }
end
local function described<K, D>(keyHook: K, drawHook: D)
  -- Rows, layers, and modifiers refer to one another, so they are checked together.
  local descriptor = schema.refine(configuration(keyHook, drawHook))(function(settings): ()
    validation.settings(settings :: any)
  end)
  type Input = schema.Input<typeof(descriptor)>
  type Output = schema.Output<typeof(descriptor)>
  local named: schema.Schema<Input, Output> = descriptor
  return named
end
local SCHEMA = described<<board.OnKey, board.DrawKey>>(onKey, drawKey)

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return SCHEMA
