-- Pointer appearance takes the session theme's colours without changing aiming or interaction policy: the muted ink
-- for the beam, and the accent while it hovers a surface.
local schema = require '@lunette-plugin/schema'
local contracts = require '@lunette-contracts/laser'
local theme = require '@lunette-contracts/theme'
local color = require '@lunette-contracts/schemas/color'

local style = {}

local nonnegative = schema.number { minimum = 0 }
local strength = schema.number { minimum = 0, maximum = 1 }
style.configuration = schema.object {
  length = schema.default(nonnegative)(1.5),
  color = schema.optional(color),
  hoverColor = schema.optional(color),
  cursorRadius = schema.default(nonnegative)(0.006),
  hapticStrength = schema.default(strength)(0.2),
  hapticDuration = schema.default(nonnegative)(0.01),
}
style.overrides = schema.partial(style.configuration)

export type Configured = schema.Output<typeof(style.configuration)>

export type Style = {
  read length: number,
  read color: contracts.Color,
  read hoverColor: contracts.Color,
  read cursorRadius: number,
  read hapticStrength: number,
  read hapticDuration: number,
}

function style.resolve(base: theme.Theme, provider: Configured, object: contracts.StyleOverride?): Style
  local given: contracts.StyleOverride = object or {}
  return table.freeze {
    length = given.length or provider.length,
    color = given.color or provider.color or base.colors.muted,
    hoverColor = given.hoverColor or provider.hoverColor or base.colors.accent,
    cursorRadius = given.cursorRadius or provider.cursorRadius,
    hapticStrength = given.hapticStrength or provider.hapticStrength,
    hapticDuration = given.hapticDuration or provider.hapticDuration,
  }
end

return style
