local schema = require '@lunette-plugin/schema'
local state = require '@lunette-plugins/arrangement/state'
local slots = require '@lunette-plugins/arrangement/slots'

local FORMAT = schema.object {
  read = schema.default(schema.callback(state.FORMAT.read))(state.FORMAT.read),
  render = schema.default(schema.callback(state.FORMAT.render))(state.FORMAT.render),
}
local SCHEMA = schema.object {
  file = schema.default(schema.string { minLength = 1 })(state.FILE),
  format = schema.default(FORMAT)(FORMAT.parse {}),
  keyFor = schema.default(schema.callback(slots.defaultKey))(slots.defaultKey),
}

export type Config = schema.Input<typeof(SCHEMA)>
export type Settings = schema.Output<typeof(SCHEMA)>

return SCHEMA
