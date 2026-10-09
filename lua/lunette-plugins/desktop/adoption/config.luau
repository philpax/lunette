local lunette = require '@lunette'
local schema = require '@lunette-plugin/schema'
local vocabulary = require '@lunette-contracts/vocabulary'

local function adoptEvery(_window: lunette.Window): boolean
  return true
end

local descriptor = schema.object {
  tags = schema.default(schema.array(schema.string { minLength = 1 })) { 'main' },
  filter = schema.default(schema.callback(adoptEvery))(adoptEvery),
  -- The precedence of the rule source that restores a remembered pose.
  precedence = schema.default(schema.number())(vocabulary.PRECEDENCE.native),
}

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = descriptor }
