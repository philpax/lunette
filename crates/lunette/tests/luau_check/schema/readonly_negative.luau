local probe = require './readonly'
local schema = require '@lunette-plugin/schema'
probe.settings.number = 2
probe.settings.nested.flag = false
probe.settings.list[1] = 2
probe.settings.map.key = 'edited'
local fields = probe.metadata.fields
assert(fields)
fields.number = schema.string().inspect()
local alternatives = probe.unionMetadata.alternatives
assert(alternatives)
alternatives[1] = schema.string().inspect()
local function mutate(problem: schema.Error): ()
  problem.path[1] = 'changed'
end
return mutate
