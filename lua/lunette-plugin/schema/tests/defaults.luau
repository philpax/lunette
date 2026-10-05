local testing = require '@testing'
local expect = testing.expect
local schema = require '@lunette-plugin/schema'
local test = testing.suite()

local function fixture()
  return schema.object {
    count = schema.default(schema.number())(3),
    style = schema.default(schema.object {
      width = schema.default(schema.number())(1),
      inner = schema.default(schema.object { depth = schema.default(schema.number())(2) }) { depth = 2 },
      colors = schema.default(schema.array(schema.number())) { 0, 0, 1 },
      names = schema.default(schema.map(schema.string())) { base = 'default' },
    }) { width = 10, inner = { depth = 20 }, colors = { 1, 2 }, names = { inherited = 'value' } },
    note = schema.optional(schema.string()),
  }
end

test('empty objects fill all declared defaults and retain optional absence', function()
  local descriptor = fixture()
  local result = descriptor.parse {}
  expect.equal(result.count, 3)
  expect.equal(result.style.width, 10)
  expect.equal(result.style.inner.depth, 20)
  expect.equal(result.note, nil)
  expect.raises(function()
    descriptor.parse(nil)
  end, 'is a table')
  expect.equal(schema.default(descriptor)(result).parse(nil).count, 3)
end)

test('nested objects merge while explicit arrays and maps replace completely', function()
  local descriptor = fixture()
  local result = descriptor.parse { style = { inner = {}, colors = { 9 }, names = {} } }
  expect.equal(result.style.width, 10)
  expect.equal(result.style.inner.depth, 20)
  expect.equal(#result.style.colors, 1)
  expect.equal(result.style.colors[1], 9)
  expect.equal(next(result.style.names), nil, 'an empty map replaces its default')
  local partial = descriptor.parse { style = { names = { fresh = 'value' } } }
  expect.equal(partial.style.names.inherited, nil)
  expect.equal(partial.style.names.fresh, 'value')
  expect.equal(partial.style.colors[2], 2)
end)

test('defaults and input tables are snapshotted without freezing the caller', function()
  local defaults = { nested = { value = 4 } }
  local descriptor = schema.default(schema.object { nested = schema.object { value = schema.number() } })(defaults)
  defaults.nested.value = 100
  local first, second = descriptor.parse(nil), descriptor.parse(nil)
  expect.equal(first.nested.value, 4)
  expect.truthy(first ~= second and first.nested ~= second.nested)
  expect.truthy(table.isfrozen(first) and table.isfrozen(first.nested))
  expect.falsy(table.isfrozen(defaults) or table.isfrozen(defaults.nested))
  local input = { nested = { value = 5 } }
  local parsed = descriptor.parse(input)
  input.nested.value = 200
  expect.equal(parsed.nested.value, 5)
  expect.falsy(table.isfrozen(input))
  expect.raises(function()
    parsed.nested.value = 6
  end, 'readonly')
end)

test('bound resolution uses definition settings and validates both inputs', function()
  local descriptor = fixture()
  local base = descriptor.parse { count = 7, style = { width = 8, colors = { 4, 5 } } }
  local resolved = descriptor.resolve({ style = { inner = {}, colors = {}, names = {} } }, base, 'bound')
  expect.equal(resolved.count, 7)
  expect.equal(resolved.style.width, 8)
  expect.equal(resolved.style.inner.depth, 20)
  expect.equal(#resolved.style.colors, 0)
  expect.equal(next(resolved.style.names), nil)
  expect.truthy(resolved ~= base and resolved.style ~= base.style)
  expect.equal(descriptor.resolve(nil, base).count, 7)
  expect.raises(function()
    descriptor.resolve(false, base)
  end, 'is a table')
  expect.raises(function()
    descriptor.resolve({}, { count = 'wrong' })
  end, 'count')
  expect.raises(function()
    descriptor.resolve({ typo = true }, base)
  end, 'not a declared field')
end)

test('schema shaped values are idempotent and copied at every resolution', function()
  local descriptor = fixture()
  for width = -10, 10 do
    local first = descriptor.parse { style = { width = width, colors = {} } }
    local second = descriptor.parse(first)
    expect.equal(second.style.width, width)
    expect.equal(second.style.inner.depth, first.style.inner.depth)
    expect.equal(#second.style.colors, 0)
    expect.truthy(second ~= first and second.style ~= first.style)
  end
end)

test('invalid defaults fail at construction including nested and nonfinite values', function()
  expect.raises(function()
    schema.default(schema.number()) 'wrong'
  end, 'schema default:')
  expect.raises(function()
    schema.default(schema.number())(math.huge)
  end, 'finite number')
  expect.raises(function()
    schema.default(schema.number())(nil)
  end, 'use optional')
  expect.raises(function()
    schema.default(schema.object { width = schema.number() }) {}
  end, 'width')
  expect.raises(function()
    schema.default(schema.array(schema.number())) { [2] = 2 }
  end, 'dense array')
  expect.raises(function()
    schema.default(schema.callback(function() end)) {}
  end, 'function')
  expect.raises(function()
    schema.default(schema.vector())(vector.pack(math.huge, 0, 0))
  end, 'finite number')
  local recursive = {}
  recursive.self = recursive
  expect.raises(function()
    schema.default(schema.object { self = schema.object {} })(recursive)
  end, 'recursive table')
end)

test('metadata is the frozen parser tree and preserves code and native values', function()
  local callback = function() end
  local vectorValue = vector.pack(1, 2, 3)
  local customValue = { marker = true }
  local custom = schema.custom {
    runtimeType = 'table',
    validate = function(value)
      return value
    end,
  }
  local descriptor = schema.describe(schema.object {
    position = schema.default(schema.vector())(vectorValue),
    callback = schema.default(schema.callback(callback))(callback),
    custom = schema.default(custom)(customValue),
    array = schema.array(schema.number()),
    map = schema.map(schema.number()),
  }) { label = 'Probe', description = 'A descriptor.' }
  local metadata = descriptor.inspect()
  expect.equal(descriptor.inspect(), metadata, 'inspection shares the actual descriptor tree')
  expect.equal(metadata.label, 'Probe')
  expect.equal(metadata.fields.position.value, vectorValue)
  expect.equal(metadata.fields.callback.value, callback)
  expect.equal(metadata.fields.custom.value, customValue)
  expect.truthy(metadata.fields.custom.readOnly and metadata.fields.callback.readOnly)
  expect.equal(metadata.merge, 'object')
  expect.equal(metadata.fields.array.kind, 'array')
  expect.equal(metadata.fields.map.kind, 'map')
  expect.equal(metadata.fields.map.merge, 'replace')
  expect.truthy(
    table.isfrozen(metadata) and table.isfrozen(metadata.fields) and table.isfrozen(metadata.fields.position)
  )
  expect.raises(function()
    metadata.fields.position.kind = 'number'
  end, 'readonly')
end)

test('constructors reject malformed descriptors and metadata without mutating options', function()
  for _, run in
    {
      function()
        schema.number { minimum = 2, maximum = 1 }
      end,
      function()
        schema.number { integer = 'yes' }
      end,
      function()
        schema.number { minimum = math.huge }
      end,
      function()
        schema.string { minLength = -1 }
      end,
      function()
        schema.string { pattern = '[' }
      end,
      function()
        schema.array(schema.number(), { maxLength = 1.5 })
      end,
      function()
        schema.map(schema.number(), { unknown = true })
      end,
      function()
        schema.object { invalid = {} }
      end,
      function()
        schema.object { [1] = schema.number() }
      end,
      function()
        schema.optional {}
      end,
      function()
        schema.literal(2)
      end,
      function()
        schema.callback(false)
      end,
      function()
        schema.custom {
          runtimeType = '',
          validate = function(value)
            return value
          end,
        }
      end,
      function()
        schema.custom { runtimeType = 'table', validate = false }
      end,
      function()
        schema.describe(schema.number()) { label = false }
      end,
    }
  do
    expect.raises(run, 'schema')
  end
  local options = { minLength = 0 }
  schema.array(schema.number(), options)
  expect.equal(options.child, nil, 'the options remain caller owned')
  expect.falsy(table.isfrozen(options))
  local shape = { count = schema.number() }
  local descriptor = schema.object(shape)
  shape.count = schema.string()
  expect.equal(descriptor.parse({ count = 2 }).count, 2, 'the schema retains its shape')
  expect.falsy(table.isfrozen(shape))
end)

return test
