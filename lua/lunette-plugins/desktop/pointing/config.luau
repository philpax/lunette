local schema = require '@lunette-plugin/schema'
local laser = require '@lunette-contracts/laser'
local aim = require '@lunette-plugins/laser/aim'

local function readInput(_hand: laser.Hand): laser.Input?
  return nil
end

local tuning = schema.object {
  reach = schema.optional(schema.number()),
  grabDeadZone = schema.optional(schema.number()),
  scrollScale = schema.optional(schema.number()),
  scrollDeadZone = schema.optional(schema.number()),
  reachScale = schema.optional(schema.number()),
  reachMinimum = schema.optional(schema.number()),
  reachMaximum = schema.optional(schema.number()),
  resizeMinimum = schema.optional(schema.number()),
  resizeMaximum = schema.optional(schema.number()),
}
local color = schema.array(schema.number(), { minLength = 4, maxLength = 4 })
local style = schema.object {
  length = schema.optional(schema.number()),
  color = schema.optional(color),
  hoverColor = schema.optional(color),
  cursorRadius = schema.optional(schema.number()),
  hapticStrength = schema.optional(schema.number()),
  hapticDuration = schema.optional(schema.number()),
}
local options = schema.object {
  aim = schema.optional(aim.overrides),
  name = schema.optional(schema.string()),
  readInput = schema.optional(schema.callback(readInput)),
  tuning = schema.optional(tuning),
  style = schema.optional(style),
}
local descriptor = schema.object {
  laser = schema.default(options)(options.parse {}),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
