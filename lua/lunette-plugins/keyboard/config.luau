local lunette = require '@lunette'
local schema = require '@lunette-plugin/schema'
local keys = require '@lunette-contracts/keys'
local board = require '@lunette-plugins/keyboard/board'
local rows = require '@lunette-plugins/keyboard/rows'

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
  width = schema.optional(schema.number { minimum = 0 }),
  height = schema.optional(schema.number { minimum = 0 }),
  x = schema.optional(schema.number { minimum = 0 }),
}
local ROWS = schema.array(schema.array(KEY))
local COLOR = schema.array(schema.number())
local STYLE = schema.object {
  keyUnit = schema.default(schema.number())(0.028),
  gap = schema.default(schema.number())(0.004),
  plateDepth = schema.default(schema.number())(0.002),
  legendDepth = schema.default(schema.number())(0.001),
  margin = schema.default(schema.number())(0.008),
  plateColor = schema.default(COLOR) { 0.1, 0.1, 0.13, 0.92 },
  keyColor = schema.default(COLOR) { 0.2, 0.2, 0.24, 1 },
  heldColor = schema.default(COLOR) { 0.35, 0.55, 0.95, 1 },
  hoverColor = schema.default(COLOR) { 0.4, 0.42, 0.5, 1 },
  legendColor = schema.default(COLOR) { 1, 1, 1, 1 },
  legendHeight = schema.default(schema.number())(0.012),
}
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
    style = schema.default(STYLE)(STYLE.parse {}),
    modifierKeys = schema.default(MODIFIER_KEYS)(keys.MODIFIER_KEYS),
    locks = schema.default(schema.array(schema.string()))(lunette.lockingModifierNames()),
    onKey = defaultCallback(keyHook),
    drawKey = defaultCallback(drawHook),
  }
end
local SCHEMA = configuration<<board.OnKey, board.DrawKey>>(onKey, drawKey)

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return SCHEMA
