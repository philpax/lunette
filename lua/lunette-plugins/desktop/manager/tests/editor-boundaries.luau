local testing = require '@testing'
local expect = testing.expect
local schema = require '@lunette-plugin/schema'
local editor = require '../editor'
local editorFixture = require './support/editor-fixture'
local row, change, reject = editorFixture.row, editorFixture.change, editorFixture.reject
local test = testing.suite()

local child = schema.object {
  list = schema.array(schema.number()),
  map = schema.map(schema.number()),
  count = schema.default(schema.number())(7),
}
local collectionMetadata = schema
  .object({
    detail = schema.optional(child),
    list = schema.array(child),
    map = schema.map(child),
    enabled = schema.default(schema.boolean())(true),
  })
  .inspect()

test('malformed collection descendants block ancestor discards but not safe sibling edits', function()
  local invalid = {
    { list = { [2] = 3 }, map = {} },
    { list = { 3, extra = 4 }, map = {} },
    { list = { [0] = 3 }, map = {} },
    { list = { [1.5] = 3 }, map = {} },
    { list = {}, map = { [1] = 3 } },
    { list = {}, map = { [false] = 3 } },
    { list = { [false] = 3 }, map = {} },
    { list = {}, map = { [math.huge] = 3 } },
  }
  for _, malformed in invalid do
    local model = editor.new(collectionMetadata, {
      detail = malformed,
      list = { malformed, { list = {}, map = {}, count = 9 } },
      map = { retained = malformed, editable = { list = {}, map = {}, count = 9 } },
    })
    local before = editor.draft(model)
    local field = if next(malformed.list) ~= nil then 'list' else 'map'
    expect.truthy(row(model, { 'detail', field }).readOnly)
    for _, path in { {}, { 'detail' }, { 'list' }, { 'list', 1 }, { 'map' }, { 'map', 'retained' } } do
      expect.falsy(row(model, path).canReset)
      reject(model, editor.reset, 'readonly', path)
    end
    expect.falsy(row(model, { 'list', 1 }).canRemove)
    expect.falsy(row(model, { 'map', 'retained' }).canRemove)
    reject(model, editor.set, 'readonly', { 'detail' }, nil)
    reject(model, editor.toggle, 'readonly', { 'detail' })
    reject(model, editor.remove, 'readonly', { 'list', 1 })
    reject(model, editor.remove, 'readonly', { 'map', 'retained' })
    local edited = change(editor.set, model, { 'detail', 'count' }, '11')
    expect.equal(editor.draft(edited).detail.count, 11)
    expect.equal(editor.draft(edited).detail[field], before.detail[field])
    expect.equal(editor.draft(edited).list, before.list)
    local enabled = change(editor.toggle, model, { 'enabled' })
    expect.equal(editor.draft(enabled).detail, before.detail)
    expect.truthy(row(model, { 'list', 2 }).canRemove)
    expect.truthy(row(model, { 'map', 'editable' }).canRemove)
    expect.equal(editor.draft(change(editor.remove, model, { 'list', 2 })).list[1], before.list[1])
    expect.equal(editor.draft(change(editor.remove, model, { 'map', 'editable' })).map.retained, before.map.retained)
  end
end)

test('optional array elements reject nil edits and resets without disabling explicit removal', function()
  local metadata = schema
    .object({
      list = schema.array(schema.optional(schema.number())),
      map = schema.map(schema.optional(schema.number())),
    })
    .inspect()
  for _, values in { { 1 }, { 1, 2, 3 } } do
    local model = editor.new(metadata, { list = values, map = { retained = 4 } })
    for index in values do
      local path = { 'list', index }
      expect.truthy(row(model, path).optional)
      expect.truthy(row(model, path).canRemove)
      expect.falsy(row(model, path).readOnly or row(model, path).canReset)
      reject(model, editor.set, 'input', path, nil)
      reject(model, editor.toggle, 'input', path)
      reject(model, editor.reset, 'readonly', path)
      expect.equal(row(model, { 'list' }).control, 'array')
      expect.equal(editor.draft(change(editor.set, model, path, '9')).list[index], 9)
      local removed = change(editor.remove, model, path)
      expect.equal(#editor.draft(removed).list, #values - 1)
      expect.equal(row(removed, { 'list' }).control, 'array')
      expect.truthy(row(removed, { 'list' }).canAdd)
      for retained = 1, #values - 1 do
        expect.equal(editor.draft(removed).list[retained], values[if retained < index then retained else retained + 1])
      end
    end
    expect.equal(editor.draft(change(editor.set, model, { 'map', 'retained' }, nil)).map.retained, nil)
    expect.equal(editor.draft(change(editor.reset, model, { 'map', 'retained' })).map.retained, nil)
  end
  local defaulted = editor.new(schema.array(schema.default(schema.optional(schema.number()))(6)).inspect(), { 1, 2, 3 })
  for index = 1, 3 do
    expect.truthy(row(defaulted, { index }).canReset)
    expect.equal(editor.draft(change(editor.reset, defaulted, { index }))[index], 6)
  end
end)

local leaf = schema.object {
  count = schema.number(),
  name = schema.string(),
  enabled = schema.boolean(),
  position = schema.vector(),
  list = schema.array(schema.number()),
  map = schema.map(schema.number()),
  retained = schema.default(schema.number())(12),
  absent = schema.optional(schema.string()),
}
local seeded = schema.object {
  nested = schema.object { leaf = leaf },
  retained = schema.default(schema.object { count = schema.number() }) { count = 23 },
  lists = schema.default(schema.array(schema.object { count = schema.default(schema.number())(5) })) {
    { count = 19 },
  },
  maps = schema.default(schema.map(schema.object { count = schema.default(schema.number())(5) })) {
    kept = { count = 29 },
  },
  absent = schema.optional(leaf),
}

local function expectSeed(value)
  expect.equal(value.nested.leaf.count, 0)
  expect.equal(value.nested.leaf.name, '')
  expect.equal(value.nested.leaf.enabled, false)
  expect.equal(value.nested.leaf.position, vector.pack(0, 0, 0))
  expect.equal(#value.nested.leaf.list, 0)
  expect.equal(next(value.nested.leaf.map), nil)
  expect.equal(value.nested.leaf.retained, 12)
  expect.equal(value.nested.leaf.absent, nil)
  expect.equal(value.retained.count, 23)
  expect.equal(value.lists[1].count, 19)
  expect.equal(value.maps.kept.count, 29)
  expect.equal(value.absent, nil)
  expect.truthy(table.isfrozen(value.nested.leaf) and table.isfrozen(value.nested.leaf.list))
  expect.truthy(table.isfrozen(value.nested.leaf.map))
  expect.equal(seeded.parse(value).nested.leaf.count, 0)
end

test('optional and collection seeds complete nested required leaves without overwriting defaults', function()
  local metadata =
    schema.object({ detail = schema.optional(seeded), list = schema.array(seeded), map = schema.map(seeded) }).inspect()
  local model = editor.new(metadata, { list = {}, map = {} })
  expectSeed(editor.draft(change(editor.toggle, model, { 'detail' })).detail)
  expectSeed(editor.draft(change(editor.set, model, { 'detail' }, true)).detail)
  expect.truthy(row(model, { 'list' }).canAdd and row(model, { 'map' }).canAdd)
  expectSeed(editor.draft(change(editor.add, model, { 'list' })).list[1])
  expectSeed(editor.draft(change(editor.add, model, { 'map' }, 'new')).map.new)
  expect.equal(editor.draft(model).detail, nil)
  expect.equal(#editor.draft(model).list, 0)
  expect.equal(next(editor.draft(model).map), nil)
end)

test('vector component edits reject finite doubles that pack to nonfinite floats', function()
  local metadata = schema
    .object({
      position = schema.default(schema.vector())(vector.pack(1, 2, 3)),
      count = schema.default(schema.number())(4),
      retained = schema.default(schema.object { name = schema.string() }) { name = 'kept' },
    })
    .inspect()
  local model = editor.new(metadata, {})
  local before = editor.draft(model)
  for _, key in { 'x', 'y', 'z' } do
    for _, input in { '1e100', '-1e100', 1e100, -1e100, '3.403e38', '-3.403e38' } do
      reject(model, editor.set, 'input', { 'position', key }, input)
    end
    for _, input in { 3.4028234663852886e38, -3.4028234663852886e38, 1e-40, 0 } do
      local edited = change(editor.set, model, { 'position', key }, input)
      local packed = editor.draft(edited).position
      local expected = vector.pack(input, input, input)
      expect.equal(packed[key], expected[key])
      expect.truthy(math.abs(packed[key]) < math.huge and packed[key] == packed[key])
      for _, sibling in { 'x', 'y', 'z' } do
        if sibling ~= key then
          expect.equal(packed[sibling], before.position[sibling])
        end
      end
      expect.equal(editor.draft(edited).retained, before.retained)
      expect.equal(editor.draft(model), before)
    end
  end
  expect.equal(editor.draft(change(editor.set, model, { 'count' }, '1e100')).count, 1e100)
end)

test('single-line string representations preserve supported text and every unsupported byte', function()
  local metadata = schema.object({ text = schema.string() }).inspect()
  local cases = {
    { '\n', '\\n' },
    { 'first\r\nsecond\t', 'first\\r\\nsecond\\t' },
    { string.char(0, 1, 31, 127), '\\x00\\x01\\x1F\\x7F' },
    { utf8.char(0x80, 0x85, 0x9f), '\\xC2\\x80\\xC2\\x85\\xC2\\x9F' },
    { utf8.char(0x2028, 0x2029), '\\xE2\\x80\\xA8\\xE2\\x80\\xA9' },
    { string.char(255, 0xc0, 0xaf), '\\xFF\\xC0\\xAF' },
    { string.char(0xed, 0xa0, 0x80, 0xf4, 0x90, 0x80, 0x80), '\\xED\\xA0\\x80\\xF4\\x90\\x80\\x80' },
    { 'é\\\n', '\\xC3\\xA9\\\\\\n' },
  }
  for _, sample in cases do
    expect.equal(schema.string().parse(sample[1]), sample[1], 'the original string is schema-valid')
    local model = editor.new(metadata, { text = sample[1] })
    local item = row(model, { 'text' })
    expect.equal(item.control, 'string')
    expect.falsy(item.readOnly)
    expect.truthy(item.escaped, 'unsupported strings use explicit escaped mode')
    expect.equal(item.text, sample[2], 'the representation is exact and single-line')
    expect.equal(editor.draft(model).text, sample[1], 'representation does not change the draft')
    expect.equal(
      change(editor.setText, model, { 'text' }, item.text),
      model,
      'unchanged confirmation preserves identity'
    )
    local edited = change(editor.setText, model, { 'text' }, item.text .. '\\n')
    expect.equal(editor.draft(edited).text, sample[1] .. '\n', 'confirmation decodes before committing')
  end
  local bytes = {}
  for byte = 0, 255 do
    bytes[#bytes + 1] = string.char(byte)
  end
  for codepoint = 0, 0x9f do
    if codepoint < 0x20 or codepoint >= 0x7f then
      bytes[#bytes + 1] = utf8.char(codepoint)
    end
  end
  local original = table.concat(bytes)
  local model = editor.new(metadata, { text = original })
  local item = row(model, { 'text' })
  for index = 1, #item.text do
    local byte = string.byte(item.text, index)
    expect.truthy(byte >= 0x20 and byte <= 0x7e, 'escaped strings contain only printable ASCII')
  end
  expect.equal(change(editor.setText, model, { 'text' }, item.text), model, 'every byte survives the field boundary')
  for _, literal in { '', 'ordinary text', 'é界', 'e' .. utf8.char(0x301), '\\n \\xFF \\', '👩‍💻' } do
    local raw = editor.new(metadata, { text = literal })
    local rawRow = row(raw, { 'text' })
    expect.falsy(rawRow.escaped, 'supported text stays literal')
    expect.equal(rawRow.text, literal, 'literal backslashes and Unicode remain unchanged')
    expect.equal(change(editor.setText, raw, { 'text' }, literal), raw)
    expect.equal(editor.draft(change(editor.setText, raw, { 'text' }, '\\n')).text, '\\n', 'raw mode does not decode')
  end
end)

test('malformed string escapes and unsupported raw field input reject without changing values', function()
  local metadata = schema.object({ text = schema.string() }).inspect()
  local model = editor.new(metadata, { text = 'retained\n' })
  for _, input in { '\\', '\\q', '\\x', '\\x0', '\\xGG', '\\x1Z', '\\u{2028}', '\n', string.char(255) } do
    reject(model, editor.setText, 'input', { 'text' }, input)
  end
  for _, sample in
    {
      { '\\x00', '\0' },
      { '\\x7f', string.char(127) },
      { '\\xFF', string.char(255) },
      { '\\\\', '\\' },
      { '\\n\\r\\t', '\n\r\t' },
      { 'é\\n', 'é\n' },
      { '', '' },
    }
  do
    local decoded = change(editor.setText, model, { 'text' }, sample[1])
    expect.equal(editor.draft(decoded).text, sample[2], 'escape decoding preserves the exact value')
  end
  local literal = editor.new(metadata, { text = 'literal' })
  for _, input in { '\n', '\t', utf8.char(0x85), utf8.char(0x2028), string.char(255) } do
    reject(literal, editor.setText, 'input', { 'text' }, input)
  end
  expect.equal(
    editor.draft(change(editor.set, literal, { 'text' }, '\n')).text,
    '\n',
    'raw value setters remain literal'
  )
end)

return test
