local testing = require '@testing'
local plugin = require '@lunette-plugin'
local expect = testing.expect
local test = testing.suite()

test('facade inspection reports ownership across runtimes and after an activation ends', function()
  local owner
  local definition = plugin.define {
    name = 'inspection-facade',
    init = function(context, _config, _publish)
      owner = context
    end,
  }
  local runtime = plugin.runtime()
  local other = plugin.runtime()
  local instance = runtime:use(definition, {})
  local foreign = other:use(definition, {})
  expect.truthy(runtime:owns(instance), 'same runtime instance')
  expect.equal(runtime:owns(foreign), false, 'foreign runtime instance')
  expect.equal(runtime:ownerId {}, nil, 'forged context')
  instance:enable()
  runtime:drain()
  expect.equal(runtime:ownerId(owner), instance:id(), 'wrapped context identity')
  expect.equal(other:ownerId(owner), nil, 'context does not cross runtimes')
  instance:disable()
  runtime:drain()
  expect.equal(runtime:ownerId(owner), instance:id(), 'stale activation identity remains inspectable')
  expect.equal(owner:active(), false, 'inspection identity grants no activation authority')
  instance:dispose()
  runtime:drain()
  expect.truthy(runtime:owns(instance), 'retired exact handle still belongs to runtime')
  expect.equal(#runtime:snapshot().instances, 0, 'retired handle absent from graph')
  runtime:close()
  other:close()
end)

return test
