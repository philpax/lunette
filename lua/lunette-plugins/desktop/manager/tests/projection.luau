-- Native snapshot records retain exact provider generations and distinguish declarations from allocations.

local testing = require '@testing'
local projection = require '@lunette-plugins/desktop/manager/projection'
local expect = testing.expect
local test = testing.suite()

local function node(id, name)
  return {
    id = id,
    name = name,
    enabled = true,
    state = 'active',
    required = {},
    provided = {},
    bindings = {},
  }
end

local function contract(name)
  return { name = name, schema = 1, display = name .. '@1' }
end

test('projection uses exact ids and allocation generations and never guesses a binding from declarations', function()
  local provider = node('1', 'same-name')
  provider.provided = { { field = 'service', contract = contract 'sample/service' } }
  local duplicate = node('2', 'same-name')
  duplicate.provided = provider.provided
  local consumer = node('3', 'consumer')
  consumer.required = { { field = 'wanted', contract = contract 'sample/service' } }
  consumer.bindings =
    { { contract = contract 'sample/service', providerId = '2', generationId = '19', current = true } }
  local pending = node('4', 'pending')
  pending.state = 'inactive'
  pending.required = consumer.required
  pending.diagnostic = 'missing sample/service'
  local result = projection.snapshot { instances = { provider, duplicate, consumer, pending } }
  expect.equal(#result.graph.nodes, 4, 'every instance remains distinct')
  expect.equal(#result.graph.edges, 1, 'declarations produce no speculative binding')
  local edge = result.graph.edges[1]
  expect.equal(edge.from, '3', 'the consumer id')
  expect.equal(edge.to, '2', 'the recorded provider id')
  expect.equal(edge.generation, '19', 'the allocation generation')
  expect.equal(result.bindings[edge.id], consumer.bindings[1], 'the binding detail is inspectable')
  expect.truthy(result.instances['4'].diagnostic:find('missing', 1, true), 'waiting details remain inspectable')
end)

test('children and stale unloading allocations remain inspectable without becoming current bindings', function()
  local parent = node('1', 'parent')
  local child = node('2', 'child')
  child.parentId = '1'
  child.state = 'unloading'
  child.bindings = { { contract = contract 'sample/service', providerId = '1', generationId = '5', current = false } }
  local result = projection.snapshot { instances = { parent, child } }
  expect.equal(#result.graph.edges, 2, 'ownership and recorded allocation are separate edges')
  expect.equal(result.graph.edges[1].kind, 'ownership', 'ownership is explicitly labeled')
  local edge = result.graph.edges[2]
  expect.falsy(result.bindings[edge.id].current, 'the inspector retains stale allocation status')
  expect.equal(result.instances['2'].state, 'unloading', 'the lifecycle phase distinguishes unloading')
end)

test('empty snapshots and absent provider allocations produce no invalid graph endpoint', function()
  expect.equal(#projection.snapshot({ instances = {} }).graph.nodes, 0, 'empty runtime')
  local consumer = node('1', 'consumer')
  consumer.parentId = 'absent'
  consumer.bindings = { { contract = contract 'sample/service', providerId = 'absent', generationId = '1' } }
  local result = projection.snapshot { instances = { consumer } }
  expect.equal(#result.graph.edges, 0, 'absent endpoints do not create selectable edges')
  expect.equal(#result.instances['1'].bindings, 1, 'native detail remains available instead of being discarded')
end)

return test
