local testing = require '@testing'
local expect = testing.expect
local schema = require '@lunette-plugin/schema'
local test = testing.suite()

local function failure(run, name, code, path)
  local ok, problem = pcall(run)
  expect.falsy(ok, 'the invalid input raises')
  expect.equal(problem.name, name, 'the diagnostic prefix')
  expect.equal(problem.code, code, 'the diagnostic code')
  expect.equal(table.concat(problem.path, '.'), path, 'the diagnostic path')
  expect.truthy(table.isfrozen(problem) and table.isfrozen(problem.path), 'the diagnostic is immutable')
  return problem
end

local function rejects(descriptor, value, code, path)
  return failure(function()
    return descriptor.parse(value, 'probe')
  end, 'plugin probe', code, path)
end

test('scalar descriptors reject wrong types, nonfinite numbers, and violated constraints at the field', function()
  expect.equal(schema.number().parse(2), 2)
  rejects(schema.string(), 2, 'type', '')
  rejects(schema.number(), 0 / 0, 'type', '')
  local descriptor = schema.object {
    count = schema.number { minimum = 1, maximum = 3, integer = true },
    label = schema.string { maxLength = 4, pattern = '^%a+$' },
  }
  descriptor.parse { count = 2, label = 'ok' }
  for _, count in { 0, 1.5 } do
    rejects(descriptor, { count = count, label = 'ok' }, 'constraint', 'count')
  end
  rejects(descriptor, { count = 2, label = '12' }, 'constraint', 'label')
end)

test('a vector descriptor takes only native vectors with finite components', function()
  local value = vector.pack(1, -2, 3)
  expect.equal(schema.vector().parse(value), value)
  rejects(schema.vector(), { 1, 2, 3 }, 'type', '')
  rejects(schema.vector(), vector.pack(0, math.huge, 0), 'type', 'y')
end)

test('a literal union preserves its values and reports a failed match', function()
  local descriptor = schema.union(schema.literal 'left', schema.union(schema.literal 'right', schema.literal(false)))
  for _, value in { 'left', 'right', false } do
    expect.equal(descriptor.parse(value), value)
  end
  local problem = rejects(descriptor, 'other', 'union', '')
  expect.truthy(string.find(tostring(problem), 'matches no alternative', 1, true))
end)

test('closed objects reject unknown nested keys and missing required fields', function()
  local descriptor = schema.object { style = schema.object { width = schema.number() } }
  rejects(descriptor, { style = { width = 1, typo = true } }, 'unknown', 'style.typo')
  rejects(descriptor, { style = {} }, 'type', 'style.width')
  local problem = rejects(descriptor, { style = { width = 'wrong' } }, 'type', 'style.width')
  expect.truthy(string.find(tostring(problem), 'plugin probe: option style.width', 1, true))
end)

test('arrays reject holes and foreign keys, and maps require string keys', function()
  local array = schema.array(schema.string())
  rejects(array, { [1] = 'one', [3] = 'three' }, 'sparse', '2')
  rejects(array, { named = 'value' }, 'key', 'named')
  rejects(schema.map(schema.number()), { [1] = 2 }, 'key', '1')
end)

test('recursive containers and metatables fail, while custom values stay atomic', function()
  local recursive = {}
  recursive.self = recursive
  rejects(schema.object { self = schema.object {} }, recursive, 'cycle', 'self')
  rejects(schema.object {}, setmetatable({}, {}), 'metatable', '')
  local custom = schema.custom {
    runtimeType = 'table',
    validate = function(value)
      assert(value.marker ~= false, 'marker is required')
      return value
    end,
  }
  expect.equal(custom.parse(recursive), recursive, 'custom code owns its value contract')
  rejects(custom, false, 'type', '')
  rejects(custom, { marker = false }, 'custom', '')
end)

test('a callback descriptor checks only the runtime kind', function()
  local descriptor = schema.callback(function(value: number): string
    return tostring(value)
  end)
  local other = function()
    return false
  end
  expect.equal(descriptor.parse(other), other)
  rejects(descriptor, {}, 'type', '')
end)

test('refinements run after nested defaults', function()
  local descriptor = schema.refine(schema.object {
    lower = schema.default(schema.number())(1),
    upper = schema.default(schema.number())(2),
  })(function(value)
    assert(value.lower < value.upper, 'lower must precede upper')
  end, 'An ordered interval.')
  expect.equal(descriptor.parse({}).lower, 1)
  rejects(descriptor, { lower = 3 }, 'refinement', '')
end)

test('explicit union input replaces its base, and omission keeps it', function()
  local descriptor = schema.union(
    schema.object { kind = schema.literal 'number', payload = schema.default(schema.number())(1) },
    schema.object { kind = schema.literal 'text', payload = schema.default(schema.string()) 'x' }
  )
  local numeric = descriptor.parse { kind = 'number', payload = 9 }
  local text = descriptor.parse { kind = 'text', payload = 'base' }
  expect.equal(descriptor.resolve({ kind = 'text' }, numeric).payload, 'x', 'the selected arm supplies its default')
  expect.equal(descriptor.resolve({ kind = 'text' }, text).payload, 'x', 'replacement within an arm')
  expect.equal(descriptor.resolve(nil, numeric).payload, 9, 'omission keeps a valid base')
end)

test('a descriptor deeper than the limit raises a diagnostic instead of exhausting the stack', function()
  local wrapped = schema.number()
  for _ = 1, 65 do
    wrapped = schema.optional(wrapped)
  end
  local problem = failure(function()
    return wrapped.parse(1, 'depth')
  end, 'plugin depth', 'depth', '')
  expect.truthy(string.find(problem.message, 'exceeds the maximum schema depth of 64', 1, true), problem.message)
end)

return test
