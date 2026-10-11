local testing = require '@testing'
local expect = testing.expect
local schema = require '@lunette-plugin/schema'
local test = testing.suite()

type Settings = {
  count: number,
  style: { width: number, inner: { depth: number }, colors: { number }, names: { [string]: string } },
  note: string?,
}
type Config = {
  count: number?,
  style: { width: number?, inner: { depth: number? }?, colors: { number }?, names: { [string]: string }? }?,
  note: string?,
}

local function fixture(): schema.Schema<Config, Settings>
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

test('an invalid default fails at construction', function()
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
end)

test('a malformed descriptor fails at construction, and a schema keeps the shape it was given', function()
  for _, run in
    {
      function()
        schema.number { minimum = 2, maximum = 1 }
      end,
      function()
        schema.string { pattern = '[' }
      end,
      function()
        schema.object { invalid = {} }
      end,
    }
  do
    expect.raises(run, 'schema')
  end
  local shape: { count: schema.Schema<number, number> | schema.Schema<string, string> } = { count = schema.number() }
  local descriptor = schema.object(shape)
  shape.count = schema.string()
  expect.equal(descriptor.parse({ count = 2 }).count, 2, 'the schema retains its shape')
end)

return test
