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

test(
  'scalar descriptors reject wrong types, nonfinite values, and violated constraints at the declared field',
  function()
    expect.equal(schema.number().parse(2), 2)
    expect.equal(schema.string().parse 'sample', 'sample')
    expect.equal(schema.boolean().parse(false), false)
    rejects(schema.number(), 'two', 'type', '')
    rejects(schema.string(), 2, 'type', '')
    rejects(schema.boolean(), 1, 'type', '')
    for _, value in { math.huge, -math.huge, 0 / 0 } do
      rejects(schema.number(), value, 'type', '')
    end
    for number = -20, 20 do
      expect.equal(schema.number().parse(number), number, 'finite numbers retain their value')
    end
    local descriptor = schema.object {
      count = schema.number { minimum = 1, maximum = 3, integer = true },
      label = schema.string { minLength = 2, maxLength = 4, pattern = '^%a+$' },
    }
    descriptor.parse { count = 2, label = 'ok' }
    for _, count in { 0, 4, 1.5 } do
      rejects(descriptor, { count = count, label = 'ok' }, 'constraint', 'count')
    end
    for _, label in { 'a', 'abcde', '12' } do
      rejects(descriptor, { count = 2, label = label }, 'constraint', 'label')
    end
    local positive = schema.number { positive = true }
    expect.equal(positive.parse(0.5), 0.5)
    for _, value in { 0, -1 } do
      rejects(positive, value, 'constraint', '')
    end
    rejects(schema.array(schema.number(), { minLength = 1 }), {}, 'constraint', '')
    rejects(schema.map(schema.string(), { maxLength = 0 }), { one = 'value' }, 'constraint', '')
  end
)

test('native vectors remain vectors and require finite components', function()
  local descriptor = schema.vector()
  local value = vector.pack(1, -2, 3)
  expect.equal(descriptor.parse(value), value)
  rejects(descriptor, { 1, 2, 3 }, 'type', '')
  for _, invalid in { math.huge, -math.huge, 0 / 0 } do
    for _, axis in { 'x', 'y', 'z' } do
      rejects(
        descriptor,
        vector.pack(
          if axis == 'x' then invalid else 0,
          if axis == 'y' then invalid else 0,
          if axis == 'z' then invalid else 0
        ),
        'type',
        axis
      )
    end
  end
end)

test('literal unions preserve values and report failed alternatives', function()
  local descriptor = schema.union(schema.literal 'left', schema.union(schema.literal 'right', schema.literal(false)))
  for _, value in { 'left', 'right', false } do
    expect.equal(descriptor.parse(value), value)
  end
  local problem = rejects(descriptor, 'other', 'union', '')
  expect.truthy(string.find(tostring(problem), 'matches no alternative', 1, true))
  rejects(schema.literal(true), false, 'literal', '')
end)

test('closed objects reject unknown nested keys and missing required fields', function()
  local descriptor = schema.object { style = schema.object { width = schema.number() } }
  rejects(descriptor, { style = { width = 1, typo = true } }, 'unknown', 'style.typo')
  rejects(descriptor, { style = {} }, 'type', 'style.width')
  rejects(descriptor, { style = { width = 1 }, typo = true }, 'unknown', 'typo')
  local problem = rejects(descriptor, { style = { width = 'wrong' } }, 'type', 'style.width')
  expect.truthy(string.find(tostring(problem), 'plugin probe: option style.width', 1, true))
end)

test('arrays reject holes and foreign keys while maps require string keys', function()
  local array = schema.array(schema.string())
  expect.equal(#array.parse {}, 0)
  rejects(array, { [2] = 'hole' }, 'sparse', '1')
  rejects(array, { [1] = 'one', [3] = 'three' }, 'sparse', '2')
  rejects(array, { [0] = 'zero' }, 'key', '0')
  rejects(array, { [1.5] = 'fraction' }, 'key', '1.5')
  rejects(array, { named = 'value' }, 'key', 'named')
  rejects(schema.map(schema.number()), { [1] = 2 }, 'key', '1')
  rejects(schema.array(schema.optional(schema.number())), { false }, 'type', '1')
end)

test('recursive declared containers fail while custom values remain atomic', function()
  local recursive = {}
  recursive.self = recursive
  rejects(schema.object { self = schema.object {} }, recursive, 'cycle', 'self')
  local list = {}
  list[1] = list
  rejects(schema.array(schema.array(schema.number())), list, 'cycle', '1')
  local calls = 0
  local custom = schema.custom {
    runtimeType = 'table',
    validate = function(value)
      calls += 1
      return value
    end,
  }
  expect.equal(custom.parse(recursive), recursive, 'custom code owns its value contract')
  expect.equal(calls, 1, 'custom values are not traversed')
  local atomic = setmetatable({}, {
    __index = function()
      error 'must not run'
    end,
  })
  expect.equal(
    schema.object({ value = custom }).parse({ value = atomic }).value,
    atomic,
    'custom metatables retain identity'
  )
  rejects(
    schema.object {},
    setmetatable({}, {
      __index = function()
        error 'must not run'
      end,
    }),
    'metatable',
    ''
  )
  rejects(
    schema.array(schema.number()),
    setmetatable({}, {
      __iter = function()
        error 'must not run'
      end,
    }),
    'metatable',
    ''
  )
  rejects(schema.object {}, { [{}] = 1 }, 'key', '')
end)

test('callbacks check only their runtime kind and custom fields preserve references', function()
  local witness = function(value: number): string
    return tostring(value)
  end
  local descriptor = schema.callback(witness)
  expect.equal(descriptor.parse(witness), witness)
  local other = function()
    return false
  end
  expect.equal(descriptor.parse(other), other, 'runtime checks only the function kind')
  rejects(descriptor, {}, 'type', '')
  expect.equal(descriptor.inspect().value, witness)
  expect.truthy(descriptor.inspect().readOnly)
  local reference = { marker = true }
  local custom = schema.custom {
    runtimeType = 'table',
    validate = function(value)
      assert(value.marker == true, 'marker is required')
      return value
    end,
  }
  expect.equal(custom.parse(reference), reference)
  rejects(custom, false, 'type', '')
  rejects(custom, {}, 'custom', '')
  expect.truthy(custom.inspect().readOnly)
end)

test('refinements run after nested defaults and preserve the parsed result', function()
  local descriptor = schema.refine(schema.object {
    lower = schema.default(schema.number())(1),
    upper = schema.default(schema.number())(2),
  })(function(value)
    assert(value.lower < value.upper, 'lower must precede upper')
  end, 'An ordered interval.')
  expect.equal(descriptor.parse({}).lower, 1)
  rejects(descriptor, { lower = 3 }, 'refinement', '')
end)

local function choice()
  return schema.union(
    schema.object { kind = schema.literal 'number', payload = schema.default(schema.number())(1) },
    schema.object { kind = schema.literal 'text', payload = schema.default(schema.string()) 'x' }
  )
end

test('explicit union input replaces an incompatible base in either direction', function()
  local descriptor = choice()
  local numeric = descriptor.parse { kind = 'number', payload = 9 }
  local text = descriptor.parse { kind = 'text', payload = 'base' }
  local switched = descriptor.resolve({ kind = 'text' }, numeric, 'choice')
  expect.equal(switched.kind, 'text')
  expect.equal(switched.payload, 'x', 'the selected arm supplies its own default')
  expect.equal(descriptor.resolve({ kind = 'number' }, text).payload, 1)
  expect.equal(
    descriptor.resolve({ kind = 'text' }, text).payload,
    'x',
    'an explicit union is replacement even within an arm'
  )
  expect.equal(descriptor.resolve(nil, numeric).payload, 9, 'omission keeps a valid base')
  expect.equal(descriptor.resolve(nil, text).payload, 'base')
  local defaulted = schema.default(descriptor)(numeric)
  expect.equal(defaulted.parse({ kind = 'text' }).payload, 'x')
  expect.equal(schema.default(descriptor)(text).parse({ kind = 'number' }).payload, 1)
  expect.equal(defaulted.parse(nil).payload, 9)
  local nested = schema.object { selection = defaulted }
  expect.equal(nested.parse({ selection = { kind = 'text' } }).selection.payload, 'x')
  local problem = failure(function()
    return descriptor.resolve(nil, { kind = 'number', payload = 'wrong' }, 'choice')
  end, 'plugin choice', 'union', '')
  expect.truthy(string.find(problem.message, 'matches no alternative', 1, true), 'the diagnostic states the contract')
end)

test('deep acyclic descriptor traversal raises before exhausting the parser stack', function()
  local wrapped = schema.number()
  for _ = 1, 65 do
    wrapped = schema.optional(wrapped)
  end
  local problem = failure(function()
    return wrapped.parse(1, 'depth')
  end, 'plugin depth', 'depth', '')
  expect.truthy(
    string.find(problem.message, 'exceeds the maximum schema depth of 64', 1, true),
    'the diagnostic states the limit'
  )
  local nested = schema.number()
  local input = 1
  local path = {}
  for index = 1, 65 do
    nested = schema.array(nested)
    input = { input }
    path[index] = '1'
  end
  local deep = failure(function()
    return nested.parse(input, 'nested-depth')
  end, 'plugin nested-depth', 'depth', table.concat(path, '.'))
  expect.equal(#deep.path, 65, 'the complete traversed field path is retained')
  local shallow = schema.number()
  for _ = 1, 64 do
    shallow = schema.optional(shallow)
  end
  expect.equal(shallow.parse(1), 1, 'the documented boundary remains valid')
end)

return test
