local schema = require '@lunette-plugin/schema'
local rules = require '@lunette-contracts/rules'
local policy = require '@lunette-plugins/rules/policy'

local rule: schema.Schema<rules.Rule, rules.Rule> = schema.custom<<rules.Rule>> {
  runtimeType = 'table',
  validate = function(value: unknown): rules.Rule
    return policy.checkRule(value, 'a rule')
  end,
}
-- The rule contract is recursive; typed boundaries avoid repeated type-function expansion.
local list = (
  schema.array<<schema.Schema<rules.Rule, rules.Rule>>>(rule) :: unknown
) :: schema.Schema<{ rules.Rule }, { read [number]: rules.Rule }>
local defaultList = (schema.default :: unknown) :: (
  schema.Schema<{ rules.Rule }, { read [number]: rules.Rule }>
) -> ({ read [number]: rules.Rule }) -> schema.Schema<{ rules.Rule }?, { read [number]: rules.Rule }>
local shape: { read rules: schema.Schema<{ rules.Rule }?, { read [number]: rules.Rule }> } = {
  rules = defaultList(list) {
    {
      match = { appId = 'firefox' },
      properties = {
        width = 2,
        pose = function(): Mat4
          return lovr.math.newMat4():translate(-1.4, 1.5, -1.2):rotate(0.9, 0, 1, 0)
        end,
      },
    },
  },
}

local descriptor = schema.object<<typeof(shape)>>(shape)

export type Config = schema.Input<typeof(descriptor)>
export type Settings = schema.Output<typeof(descriptor)>

return { schema = (descriptor :: unknown) :: schema.Schema<Config, Settings> }
