local schema = require '@lunette-plugin/schema'
local contract = require '@lunette-contracts/pacing'

export type ChooseBase = (contract.Pacer, contract.Observation) -> number?
export type Choose = (contract.Pacer, contract.Observation, ChooseBase) -> number?

local function choose(paced: contract.Pacer, observation: contract.Observation, base: ChooseBase): number?
  return base(paced, observation)
end

local EXEMPT_TYPES = schema.object {
  none = schema.default(schema.boolean())(false),
  photo = schema.default(schema.boolean())(false),
  video = schema.default(schema.boolean())(true),
  game = schema.default(schema.boolean())(true),
}
local TUNING = schema.object {
  -- The native floor keeps clients answering input.
  background = schema.default(schema.number { positive = true })(1),
  -- Videos remain smooth while exempt clients redraw less often.
  exempt = schema.default(schema.number { positive = true })(30),
  -- About a second avoids treating two same-coloured video frames as idle.
  history = schema.default(schema.number { minimum = 1, integer = true })(90),
  busy = schema.default(schema.number { positive = true, maximum = 1 })(0.5),
  exemptTypes = schema.default(EXEMPT_TYPES)(EXEMPT_TYPES.parse {}),
}
local SCHEMA = schema.object {
  tuning = schema.default(TUNING)(TUNING.parse {}),
  choose = schema.default(schema.callback(choose))(choose),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return SCHEMA
