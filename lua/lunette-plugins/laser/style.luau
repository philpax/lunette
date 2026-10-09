-- Pointer appearance inherits semantic colours without changing aiming or interaction policy.
local schema = require '@lunette-plugin/schema'
local contracts = require '@lunette-contracts/laser'
local theme = require '@lunette-contracts/theme'
local descriptors = require '@lunette-plugins/theme/descriptors'

local style = {}

local nonnegative = schema.number { minimum = 0 }
local strength = schema.number { minimum = 0, maximum = 1 }
style.overrides = schema.object {
  length = schema.optional(nonnegative),
  color = schema.optional(descriptors.color),
  hoverColor = schema.optional(descriptors.color),
  cursorRadius = schema.optional(nonnegative),
  hapticStrength = schema.optional(strength),
  hapticDuration = schema.optional(nonnegative),
}
style.configuration = schema.object {
  length = schema.default(nonnegative)(1.5),
  color = schema.optional(descriptors.color),
  hoverColor = schema.optional(descriptors.color),
  cursorRadius = schema.default(nonnegative)(0.006),
  hapticStrength = schema.default(strength)(0.2),
  hapticDuration = schema.default(nonnegative)(0.01),
}

export type Configured = schema.Output<typeof(style.configuration)>

function style.resolve(base: theme.Theme, provider: Configured, object: contracts.StyleOverride?): contracts.Style
  local given: contracts.StyleOverride = object or {}
  return table.freeze {
    length = given.length or provider.length,
    color = given.color or provider.color or base.colors.pointer,
    hoverColor = given.hoverColor or provider.hoverColor or base.colors.pointerHovered,
    cursorRadius = given.cursorRadius or provider.cursorRadius,
    hapticStrength = given.hapticStrength or provider.hapticStrength,
    hapticDuration = given.hapticDuration or provider.hapticDuration,
  }
end

return style
