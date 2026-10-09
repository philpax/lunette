-- The per-attachment laser options a configuration supplies. Omitted fields inherit the provider's settings.
local schema = require '@lunette-plugin/schema'
local contracts = require '@lunette-contracts/laser'
local aim = require './aim'
local triggerLock = require './trigger-lock'
local style = require './style'

local function readInput(_hand: contracts.Hand): contracts.Input?
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

return schema.object {
  aim = schema.optional(aim.overrides),
  triggerLock = schema.optional(triggerLock.overrides),
  name = schema.optional(schema.string()),
  readInput = schema.optional(schema.callback(readInput)),
  tuning = schema.optional(tuning),
  style = schema.optional(style.overrides),
}
