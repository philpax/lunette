-- Validates editable theme settings and projects them into stable contract values.

local schema = require '@lunette-plugin/schema'
local theme = require '@lunette-contracts/theme'
local descriptors = require '@lunette-contracts/schemas/theme'

local configuration = {}

local positive = schema.number { positive = true }
local editableFontFields = schema.object {
  kind = schema.default(schema.enum<<'default' | 'file'>> { 'default', 'file' }) 'default',
  file = schema.optional(schema.string { minLength = 1 }),
  size = schema.optional(positive),
  spread = schema.optional(positive),
}
export type EditableFontConfig = schema.Input<typeof(editableFontFields)>
export type EditableFont = schema.Output<typeof(editableFontFields)>
local editableFont = schema.refine(editableFontFields)(function(value: EditableFont): ()
  if value.kind == 'default' then
    assert(
      value.file == nil and value.size == nil and value.spread == nil,
      'default fonts have no file, size, or spread'
    )
  else
    assert(value.file ~= nil, 'file fonts require a nonempty file')
  end
end)
local editableTypography = schema.object {
  font = schema.optional(editableFont),
  bodySize = schema.optional(positive),
  smallSize = schema.optional(positive),
  titleHeight = schema.optional(positive),
  keyboardLegendHeight = schema.optional(positive),
  errorTextHeight = schema.optional(positive),
  hintTextHeight = schema.optional(positive),
}
local editableOverrides = schema.object {
  colors = schema.optional(schema.partial(descriptors.colors)),
  typography = schema.optional(editableTypography),
  metrics = schema.optional(schema.partial(descriptors.metrics)),
  radii = schema.optional(schema.partial(descriptors.radii)),
}
export type EditableOverridesConfig = schema.Input<typeof(editableOverrides)>
export type EditableOverrides = schema.Output<typeof(editableOverrides)>

configuration.editableFont = editableFont
configuration.editableOverrides = editableOverrides

function configuration.projectFont(value: unknown, label: string?): theme.FontSpec
  local parsed = editableFont.parse(value, label or 'theme font')
  if parsed.kind == 'default' then
    return descriptors.font.parse({ kind = 'default' }, label or 'theme font')
  end
  return descriptors.font.parse({
    kind = 'file',
    file = parsed.file,
    size = parsed.size or 32,
    spread = parsed.spread or 4,
  }, label or 'theme font')
end

function configuration.projectOverrides(value: unknown, label: string?): theme.ThemeOverrides
  local parsed = editableOverrides.parse(value, label or 'theme overrides')
  local text = parsed.typography
  return descriptors.overrides.parse({
    colors = parsed.colors,
    typography = if text
      then {
        font = if text.font then configuration.projectFont(text.font, label) else nil,
        bodySize = text.bodySize,
        smallSize = text.smallSize,
        titleHeight = text.titleHeight,
        keyboardLegendHeight = text.keyboardLegendHeight,
        errorTextHeight = text.errorTextHeight,
        hintTextHeight = text.hintTextHeight,
      }
      else nil,
    metrics = parsed.metrics,
    radii = parsed.radii,
  }, label or 'theme overrides')
end

return table.freeze(configuration)
