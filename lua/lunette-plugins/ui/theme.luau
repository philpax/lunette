-- Theme descriptors validate and freeze provider defaults and each panel or control override layer.
local schema = require '@lunette-plugin/schema'
local ui = require '@lunette-contracts/ui'
local theme = {}

local color = schema.array(schema.number { minimum = 0, maximum = 1 }, { minLength = 4, maxLength = 4 })
local positive = schema.refine(schema.number())(function(value: number): ()
  assert(value > 0, 'must be positive')
end)
local nonnegative = schema.number { minimum = 0 }
local descriptor = schema.object {
  background = schema.default(color) { 0.035, 0.045, 0.065, 1 },
  foreground = schema.default(color) { 0.94, 0.96, 1, 1 },
  control = schema.default(color) { 0.13, 0.17, 0.23, 1 },
  hovered = schema.default(color) { 0.21, 0.29, 0.39, 1 },
  pressed = schema.default(color) { 0.10, 0.35, 0.49, 1 },
  disabled = schema.default(color) { 0.25, 0.28, 0.32, 1 },
  focus = schema.default(color) { 0.40, 0.82, 1, 1 },
  selection = schema.default(color) { 0.20, 0.42, 0.66, 1 },
  error = schema.default(color) { 1, 0.38, 0.34, 1 },
  border = schema.default(color) { 0.44, 0.52, 0.63, 1 },
  fontSize = schema.default(positive)(20),
  padding = schema.default(nonnegative)(8),
  spacing = schema.default(nonnegative)(6),
  borderWidth = schema.default(nonnegative)(2),
  rowHeight = schema.default(positive)(40),
  hapticStrength = schema.default(schema.number { minimum = 0, maximum = 1 })(0.25),
  hapticDuration = schema.default(nonnegative)(0.03),
}
local overridesDescriptor = schema.object {
  background = schema.optional(color),
  foreground = schema.optional(color),
  control = schema.optional(color),
  hovered = schema.optional(color),
  pressed = schema.optional(color),
  disabled = schema.optional(color),
  focus = schema.optional(color),
  selection = schema.optional(color),
  error = schema.optional(color),
  border = schema.optional(color),
  fontSize = schema.optional(positive),
  padding = schema.optional(nonnegative),
  spacing = schema.optional(nonnegative),
  borderWidth = schema.optional(nonnegative),
  rowHeight = schema.optional(positive),
  hapticStrength = schema.optional(schema.number { minimum = 0, maximum = 1 }),
  hapticDuration = schema.optional(nonnegative),
}

theme.schema = descriptor
theme.DEFAULT = descriptor.parse {}

function theme.copyOverrides(overrides: ui.ThemeOverrides?): ui.ThemeOverrides?
  if overrides == nil then
    return nil
  end
  return overridesDescriptor.parse(overrides, 'ui theme overrides')
end

-- Resolve repeatedly for provider → panel → control precedence; each result owns frozen color arrays.
function theme.resolve(base: ui.Theme, overrides: ui.ThemeOverrides?): ui.Theme
  local validated = theme.validate(base)
  return descriptor.resolve(overrides or {}, validated, 'ui theme overrides')
end

function theme.validate(value: ui.Theme): ui.Theme
  local validated = descriptor.parse(value, 'ui theme')
  assert(value.background ~= nil, 'ui theme: missing background')
  assert(value.foreground ~= nil, 'ui theme: missing foreground')
  assert(value.control ~= nil, 'ui theme: missing control')
  assert(value.hovered ~= nil, 'ui theme: missing hovered')
  assert(value.pressed ~= nil, 'ui theme: missing pressed')
  assert(value.disabled ~= nil, 'ui theme: missing disabled')
  assert(value.focus ~= nil, 'ui theme: missing focus')
  assert(value.selection ~= nil, 'ui theme: missing selection')
  assert(value.error ~= nil, 'ui theme: missing error')
  assert(value.border ~= nil, 'ui theme: missing border')
  assert(value.fontSize ~= nil, 'ui theme: missing fontSize')
  assert(value.padding ~= nil, 'ui theme: missing padding')
  assert(value.spacing ~= nil, 'ui theme: missing spacing')
  assert(value.borderWidth ~= nil, 'ui theme: missing borderWidth')
  assert(value.rowHeight ~= nil, 'ui theme: missing rowHeight')
  assert(value.hapticStrength ~= nil, 'ui theme: missing hapticStrength')
  assert(value.hapticDuration ~= nil, 'ui theme: missing hapticDuration')
  return validated
end

return theme
