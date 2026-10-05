local schema = require '@lunette-plugin/schema'
local rules = require '@lunette-contracts/rules'
local policy = require '@lunette-plugins/rules/policy'

local match = schema.custom<<rules.Match>> {
  runtimeType = 'table',
  validate = policy.checkMatch,
}
local properties = schema.custom<<rules.Properties>> {
  runtimeType = 'table',
  validate = policy.checkProperties,
}
local rule: schema.Schema<rules.Rule, rules.Rule> = schema.custom<<rules.Rule>> {
  runtimeType = 'table',
  validate = function(value: unknown): rules.Rule
    assert(type(value) == 'table' and getmetatable(value) == nil, 'a rule is a plain table')
    local fields = value :: { [unknown]: unknown }
    for key in fields do
      assert(key == 'match' or key == 'properties', 'a rule contains only match and properties')
    end
    if fields.match ~= nil then
      match.parse(fields.match)
    end
    if fields.properties ~= nil then
      properties.parse(fields.properties)
    end
    return value :: rules.Rule
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
