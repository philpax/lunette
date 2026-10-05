local testing = require '@testing'
local expect = testing.expect
local schema = require '@lunette-plugin/schema'
local test = testing.suite()

local function failure(run, name, code, path, message)
  local ok, problem = pcall(run)
  expect.falsy(ok, 'invalid input raises')
  expect.equal(type(problem), 'table', 'the error is structured')
  expect.equal(problem.name, name)
  expect.equal(problem.code, code)
  expect.equal(table.concat(problem.path, '.'), path)
  expect.truthy(string.find(problem.message, message, 1, true), 'the diagnostic states the contract')
  expect.truthy(table.isfrozen(problem) and table.isfrozen(problem.path), 'the diagnostic is immutable')
end

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
  failure(function()
    descriptor.resolve(nil, { kind = 'number', payload = 'wrong' }, 'choice')
  end, 'plugin choice', 'union', '', 'matches no alternative')
end)

test('custom validation rejects replacement values during parsing and default construction', function()
  local input = { marker = true }
  local transformed = schema.custom {
    runtimeType = 'table',
    validate = function(value)
      return { marker = value.marker }
    end,
  }
  failure(function()
    transformed.parse(input, 'custom')
  end, 'plugin custom', 'custom', '', 'must return the original value')
  failure(function()
    schema.default(transformed)(input)
  end, 'schema default', 'custom', '', 'must return the original value')
  local nested = schema.object { value = transformed }
  failure(function()
    nested.parse({ value = input }, 'nested')
  end, 'plugin nested', 'custom', 'value', 'must return the original value')
  local scalar = schema.custom {
    runtimeType = 'number',
    validate = function(value)
      return value + 1
    end,
  }
  failure(function()
    scalar.parse(1, 'scalar')
  end, 'plugin scalar', 'custom', '', 'must return the original value')
end)

test('custom defaults and bases remain identical through repeated validation', function()
  local reference = setmetatable({ marker = true }, {
    __eq = function()
      return true
    end,
  })
  local calls = 0
  local descriptor = schema.custom {
    runtimeType = 'table',
    validate = function(value)
      calls += 1
      assert(value.marker == true, 'marker is required')
      return value
    end,
  }
  local defaulted = schema.default(descriptor)(reference)
  for _ = 1, 4 do
    expect.truthy(rawequal(defaulted.parse(nil), reference))
    expect.truthy(rawequal(descriptor.resolve(nil, reference), reference))
    expect.truthy(rawequal(descriptor.resolve(reference, reference), reference))
  end
  expect.truthy(calls >= 13, 'defaults and bases are validated every time')
  expect.falsy(table.isfrozen(reference), 'custom ownership remains external')
  reference.marker = false
  failure(function()
    defaulted.parse(nil, 'mutation')
  end, 'plugin mutation', 'custom', '', 'marker is required')
  local equalReplacement = schema.custom {
    runtimeType = 'table',
    validate = function()
      return setmetatable({ marker = true }, getmetatable(reference))
    end,
  }
  failure(function()
    equalReplacement.parse(reference, 'identity')
  end, 'plugin identity', 'custom', '', 'must return the original value')
  local callback = function() end
  local callbacks = schema.default(schema.callback(callback))(callback)
  expect.truthy(rawequal(callbacks.parse(nil), callback))
  local position = vector.pack(1, 2, 3)
  local vectors = schema.default(schema.vector())(position)
  expect.equal(vectors.parse(nil), position)
end)

test('lazy malformed patterns raise a structured error at the nested input path', function()
  local descriptor = schema.object { nested = schema.array(schema.string { pattern = 'x[' }) }
  expect.equal(#descriptor.parse({ nested = {} }).nested, 0)
  failure(function()
    descriptor.parse({ nested = { 'x' } }, 'pattern')
  end, 'plugin pattern', 'pattern', 'nested.1', 'pattern is invalid')
  failure(function()
    schema.default(schema.string { pattern = 'x[' }) 'x'
  end, 'schema default', 'pattern', '', 'pattern is invalid')
end)

test('number diagnostics do not invoke an input tostring metamethod', function()
  local calls = 0
  local input = setmetatable({}, {
    __tostring = function()
      calls += 1
      error 'tostring must not run'
    end,
  })
  local descriptor = schema.object { nested = schema.array(schema.number()) }
  failure(function()
    descriptor.parse({ nested = { input } }, 'numeric')
  end, 'plugin numeric', 'type', 'nested.1', 'not a table')
  expect.equal(calls, 0, 'invalid input is described by typeof')
end)

test('deep acyclic descriptor traversal raises before exhausting the parser stack', function()
  local wrapped = schema.number()
  for _ = 1, 65 do
    wrapped = schema.optional(wrapped)
  end
  failure(function()
    wrapped.parse(1, 'depth')
  end, 'plugin depth', 'depth', '', 'exceeds the maximum schema depth of 64')
  local nested = schema.number()
  local input = 1
  for _ = 1, 65 do
    nested = schema.array(nested)
    input = { input }
  end
  local ok, problem = pcall(nested.parse, input, 'nested-depth')
  expect.falsy(ok)
  expect.equal(problem.name, 'plugin nested-depth')
  expect.equal(problem.code, 'depth')
  expect.equal(#problem.path, 65, 'the complete traversed field path is retained')
  expect.truthy(table.isfrozen(problem.path))
  local shallow = schema.number()
  for _ = 1, 64 do
    shallow = schema.optional(shallow)
  end
  expect.equal(shallow.parse(1), 1, 'the documented boundary remains valid')
end)

return test
