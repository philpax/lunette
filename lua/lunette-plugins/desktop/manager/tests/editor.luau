local testing = require '@testing'
local expect = testing.expect
local schema = require '@lunette-plugin/schema'
local editor = require '../editor'
local editorFixture = require './support/editor-fixture'
local row, change, reject = editorFixture.row, editorFixture.change, editorFixture.reject
local test = testing.suite()

local function fixture()
  local shape = schema.object {
    enabled = schema.default(schema.boolean())(true),
    title = schema.describe(schema.default(schema.string()) 'Initial') { label = 'Title', description = 'A title.' },
    style = schema.default(schema.object {
      width = schema.default(schema.number())(1),
      inner = schema.default(schema.object { depth = schema.default(schema.number())(2) }) { depth = 20 },
    }) { width = 10, inner = { depth = 30 } },
    list = schema.default(schema.array(schema.object { name = schema.default(schema.string()) 'new' })) {
      { name = 'one' },
      { name = 'two' },
    },
    map = schema.default(schema.map(schema.number())) { retained = 4 },
    position = schema.default(schema.vector())(vector.pack(1, 2, 3)),
    mode = schema.default(
      schema.union(
        schema.literal<<'quiet'>> 'quiet',
        schema.union(schema.literal<<'active'>> 'active', schema.literal<<'paused'>> 'paused')
      )
    ) 'quiet',
    note = schema.optional(schema.string()),
    detail = schema.optional(schema.object { label = schema.string(), count = schema.default(schema.number())(7) }),
  }
  return schema.default(shape)(shape.parse {}).inspect()
end

test('metadata defaults match schema resolution and empty collections replace', function()
  local metadata = fixture()
  local model = editor.new(metadata, { style = { inner = {} }, list = {}, map = {} })
  local value = editor.draft(model)
  expect.equal(value.style.width, 10)
  expect.equal(value.style.inner.depth, 30)
  expect.equal(#value.list, 0)
  expect.equal(next(value.map), nil)
  expect.equal(value.title, 'Initial')
  expect.equal(value.note, nil)
end)

test('flattened paths identify groups, vector components, collections, and labels', function()
  local model = editor.new(fixture(), {})
  expect.equal(row(model, {}).control, 'group')
  expect.equal(row(model, { 'style', 'inner', 'depth' }).control, 'number')
  expect.equal(row(model, { 'list', 2, 'name' }).value, 'two')
  expect.equal(row(model, { 'map', 'retained' }).value, 4)
  expect.equal(row(model, { 'position', 'z' }).value, 3)
  expect.equal(row(model, { 'title' }).label, 'Title')
  expect.equal(row(model, { 'title' }).description, 'A title.')
  expect.equal(row(model, { 'detail' }).control, 'optional')
end)

test('text parsing is primitive, finite, and does not evaluate Lua', function()
  local model = editor.new(fixture(), {})
  for _, input in { '1e999', '0/0', 'return 3', 'vector.pack(1, 2, 3)', math.huge, 0 / 0, {} } do
    reject(model, editor.set, 'input', { 'style', 'width' }, input)
  end
  expect.equal(editor.draft(change(editor.set, model, { 'style', 'width' }, '-1.25e2')).style.width, -125)
  local text = 'return { retained = false }'
  expect.equal(editor.draft(change(editor.set, model, { 'title' }, text)).title, text)
  expect.equal(editor.draft(change(editor.set, model, { 'title' }, '')).title, '')
  expect.equal(editor.draft(change(editor.toggle, model, { 'enabled' })).enabled, false)
  expect.equal(editor.draft(change(editor.set, model, { 'enabled' }, 'false')).enabled, false)
  reject(model, editor.set, 'input', { 'enabled' }, 'yes')
  reject(model, editor.set, 'input', { 'style' }, {})
  reject(model, editor.set, 'path', { 'missing' }, 'anything')
end)

test('literal union choices preserve their actual primitive values', function()
  local model = editor.new(fixture(), {})
  local modes = row(model, { 'mode' })
  expect.equal(modes.control, 'choice')
  expect.equal(#modes.choices, 3)
  local selected = change(editor.set, model, { 'mode' }, modes.choices[3])
  expect.equal(editor.draft(selected).mode, 'paused')
  reject(model, editor.set, 'input', { 'mode' }, 'unknown')
  local boolean = editor.new(schema.union(schema.literal<<true>>(true), schema.literal<<false>>(false)).inspect(), true)
  expect.equal(editor.draft(change(editor.set, boolean, {}, false)), false)
  reject(boolean, editor.set, 'input', {}, 'false')
  local opaqueUnion = editor.new(schema.union(schema.string(), schema.number()).inspect(), 'value')
  expect.truthy(row(opaqueUnion, {}).readOnly)
  reject(opaqueUnion, editor.set, 'readonly', {}, 'different')
end)

test('native vector components edit and reset without rewriting a table', function()
  local model = editor.new(fixture(), {})
  local updated = change(editor.set, model, { 'position', 'y' }, '9.5')
  local value = editor.draft(updated).position
  expect.equal(typeof(value), 'vector')
  expect.equal(value, vector.pack(1, 9.5, 3))
  expect.equal(editor.draft(model).position, vector.pack(1, 2, 3))
  reject(updated, editor.set, 'input', { 'position', 'z' }, math.huge)
  expect.equal(editor.draft(change(editor.reset, updated, { 'position', 'y' })).position, vector.pack(1, 2, 3))
end)

test('arrays and maps add, edit, and remove entries with stable sibling snapshots', function()
  local model = editor.new(fixture(), {})
  local original = editor.draft(model)
  local added = change(editor.add, model, { 'list' })
  expect.equal(editor.draft(added).list[3].name, 'new')
  local edited = change(editor.set, added, { 'list', 2, 'name' }, 'changed')
  local removed = change(editor.remove, edited, { 'list', 1 })
  expect.equal(#editor.draft(removed).list, 2)
  expect.equal(editor.draft(removed).list[1].name, 'changed')
  expect.equal(original.list[1].name, 'one')
  local keyed = change(editor.add, removed, { 'map' }, 'a.b')
  expect.equal(row(keyed, { 'map', 'a.b' }).value, 0)
  local mapEdit = change(editor.set, keyed, { 'map', 'a.b' }, '12')
  expect.equal(editor.draft(mapEdit).map['a.b'], 12)
  expect.equal(editor.draft(change(editor.remove, mapEdit, { 'map', 'retained' })).map.retained, nil)
  reject(keyed, editor.add, 'key', { 'map' }, 'a.b')
  reject(keyed, editor.add, 'key', { 'map' })
  reject(keyed, editor.remove, 'path', { 'map', 'missing' })
  local empty = editor.new(fixture(), { list = {}, map = {} })
  expect.equal(#editor.draft(change(editor.add, empty, { 'list' })).list, 1)
  expect.equal(editor.draft(change(editor.add, empty, { 'map' }, '')).map[''], 0)
end)

test('optional values and seeds transition between absent and present explicitly', function()
  local model = editor.new(fixture(), {})
  local missing = reject(model, editor.set, 'path', { 'detail', 'count' }, '3')
  expect.equal(missing.path[2], 'count')
  local detail = change(editor.toggle, model, { 'detail' })
  expect.equal(editor.draft(detail).detail.count, 7)
  expect.equal(editor.draft(detail).detail.label, '')
  local edited = change(editor.set, detail, { 'detail', 'label' }, 'present')
  expect.equal(editor.draft(change(editor.set, edited, { 'detail' }, nil)).detail, nil)
  expect.equal(editor.draft(change(editor.toggle, edited, { 'detail' })).detail, nil)
  expect.equal(editor.draft(change(editor.reset, edited, { 'detail' })).detail, nil)
  local note = change(editor.set, model, { 'note' }, 'text')
  expect.equal(editor.draft(change(editor.reset, note, { 'note' })).note, nil)
  expect.equal(editor.draft(change(editor.toggle, model, { 'note' })).note, '')
  local metadata = schema
    .object({
      number = schema.optional(schema.number()),
      boolean = schema.optional(schema.boolean()),
      object = schema.optional(schema.object { name = schema.string(), number = schema.default(schema.number())(8) }),
      list = schema.optional(schema.array(schema.number())),
    })
    .inspect()
  local model = editor.new(metadata, {})
  for _, path in { { 'number' }, { 'boolean' }, { 'object' }, { 'list' } } do
    expect.equal(row(model, path).control, 'optional')
    local enabled = change(editor.set, model, path, true)
    expect.truthy(editor.draft(enabled)[path[1]] ~= nil)
    expect.equal(editor.draft(change(editor.reset, enabled, path))[path[1]], nil)
    expect.equal(editor.draft(model)[path[1]], nil)
  end
  local number = change(editor.toggle, model, { 'number' })
  expect.equal(editor.draft(number).number, 0)
  expect.equal(row(number, { 'number' }).control, 'number')
  local edited = change(editor.set, number, { 'number' }, '12')
  expect.equal(editor.draft(change(editor.toggle, edited, { 'number' })).number, nil)
  local object = change(editor.toggle, model, { 'object' })
  expect.equal(editor.draft(object).object.name, '')
  expect.equal(editor.draft(object).object.number, 8)
  expect.equal(editor.draft(change(editor.toggle, object, { 'object' })).object, nil)
  local boolean = change(editor.toggle, model, { 'boolean' })
  expect.equal(editor.draft(boolean).boolean, false)
  expect.equal(editor.draft(change(editor.toggle, boolean, { 'boolean' })).boolean, true)
  expect.equal(editor.draft(change(editor.set, boolean, { 'boolean' }, nil)).boolean, nil)
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

test('bound defaults reset nested fields and reset is idempotent', function()
  local model = editor.new(fixture(), { style = { width = 18, inner = { depth = 90 } } })
  local reset = change(editor.reset, model, { 'style', 'inner', 'depth' })
  expect.equal(editor.draft(reset).style.inner.depth, 30)
  expect.equal(editor.draft(reset).style.width, 18)
  expect.equal(change(editor.reset, reset, { 'style', 'inner', 'depth' }), reset)
end)

test('callbacks and custom references survive unrelated edits and blocked operations', function()
  local callback = function()
    return 'value'
  end
  local custom = setmetatable({}, {
    __index = function()
      error 'custom traversal'
    end,
  })
  custom.self = custom
  local customSchema = schema.custom {
    runtimeType = 'table',
    validate = function(value)
      return value
    end,
  }
  local metadata = schema
    .default(schema.object {
      enabled = schema.boolean(),
      callback = schema.callback(callback),
      custom = customSchema,
      nested = schema.object { callback = schema.callback(callback), count = schema.number() },
      callbacks = schema.array(schema.callback(callback)),
      optional = schema.optional(schema.object { custom = customSchema }),
    })({
    enabled = true,
    callback = callback,
    custom = custom,
    nested = { callback = callback, count = 2 },
    callbacks = { callback },
  })
    .inspect()
  local model = editor.new(metadata, {})
  local updated = change(editor.set, model, { 'nested', 'count' }, '3')
  local draft = editor.draft(updated)
  expect.equal(draft.callback, callback)
  expect.equal(draft.custom, custom)
  expect.equal(draft.nested.callback, callback)
  expect.equal(draft.callbacks[1], callback)
  expect.falsy(table.isfrozen(custom))
  for _, path in { { 'callback' }, { 'custom' }, { 'callbacks', 1 } } do
    expect.truthy(row(updated, path).readOnly)
    expect.truthy(row(updated, path).reason ~= nil)
    reject(updated, editor.set, 'readonly', path, 'replacement')
    reject(updated, editor.reset, 'readonly', path)
  end
  expect.falsy(row(updated, { 'callbacks' }).canAdd)
  reject(updated, editor.add, 'readonly', { 'callbacks' })
  reject(updated, editor.remove, 'readonly', { 'callbacks', 1 })
  reject(updated, editor.reset, 'readonly', { 'nested' })
  reject(updated, editor.toggle, 'input', { 'optional' })
  local present = editor.new(metadata, { optional = { custom = custom } })
  reject(present, editor.set, 'readonly', { 'optional' }, nil)
  reject(present, editor.toggle, 'readonly', { 'optional' })
end)

test('unknown and malformed containers remain visible and are never silently discarded', function()
  local extra = { retained = true }
  local model = editor.new(fixture(), { extra = extra, list = { [2] = { name = 'sparse' } }, map = { [1] = 3 } })
  expect.equal(editor.draft(model).extra, extra)
  expect.truthy(row(model, { 'extra' }).readOnly)
  expect.truthy(row(model, { 'list' }).readOnly)
  expect.truthy(row(model, { 'map' }).readOnly)
  local edited = change(editor.toggle, model, { 'enabled' })
  expect.equal(editor.draft(edited).extra, extra)
  reject(edited, editor.reset, 'readonly', {})
  local nested = editor.new(fixture(), { style = { extra = extra } })
  reject(nested, editor.reset, 'readonly', { 'style' })
  expect.equal(editor.draft(change(editor.set, nested, { 'style', 'width' }, '5')).style.extra, extra)
  expect.equal(editor.draft(edited).list[2].name, 'sparse')
  reject(edited, editor.add, 'readonly', { 'list' })
  local hostile = setmetatable({}, {
    __index = function()
      error 'container indexing'
    end,
  })
  local invalid = editor.new(fixture(), { style = hostile })
  expect.truthy(row(invalid, { 'style' }).readOnly)
  expect.equal(editor.draft(change(editor.toggle, invalid, { 'enabled' })).style, hostile)
end)

test('collection removal and add permissions match entries and preserve opaque siblings', function()
  local opaque = setmetatable({}, {})
  local shape = schema.object { count = schema.number() }
  local metadata = schema
    .object({
      list = schema.array(shape),
      map = schema.map(shape),
      group = shape,
    })
    .inspect()
  local model = editor.new(metadata, {
    list = { { count = 1, extra = opaque }, { count = 2 } },
    map = { held = { count = 3, extra = opaque }, editable = { count = 4 } },
    group = { count = 5 },
  })
  local before = editor.draft(model)
  for _, path in { {}, { 'list' }, { 'map' }, { 'group' }, { 'group', 'count' }, { 'list', 2, 'count' } } do
    expect.falsy(row(model, path).canRemove)
  end
  for _, path in { { 'list', 1 }, { 'map', 'held' } } do
    expect.falsy(row(model, path).canRemove)
    reject(model, editor.remove, 'readonly', path)
  end
  for _, path in { { 'list', 2 }, { 'map', 'editable' } } do
    expect.truthy(row(model, path).canRemove)
    local changed = change(editor.remove, model, path)
    expect.equal(editor.draft(changed).list[1].extra, opaque)
    expect.equal(editor.draft(changed).map.held.extra, opaque)
    expect.equal(editor.draft(model), before)
  end
  expect.equal(#editor.draft(change(editor.remove, model, { 'list', 2 })).list, 1)
  expect.equal(editor.draft(change(editor.remove, model, { 'map', 'editable' })).map.editable, nil)
  for _, path in { { 'list' }, { 'map' } } do
    expect.truthy(row(model, path).canAdd)
    local added = change(editor.add, model, path, 'new')
    expect.equal(editor.draft(added).list[1].extra, opaque)
    expect.equal(editor.draft(added).map.held.extra, opaque)
  end
  local metadata = schema
    .object({
      list = schema.array(schema.number()),
      map = schema.map(schema.boolean()),
      choices = schema.array(schema.union(schema.string(), schema.number())),
    })
    .inspect()
  local model = editor.new(metadata, { list = {}, map = {}, choices = { 'retained' } })
  expect.truthy(row(model, { 'list' }).canAdd)
  expect.truthy(row(model, { 'map' }).canAdd)
  expect.falsy(row(model, { 'choices' }).canAdd)
  reject(model, editor.add, 'readonly', { 'choices' })
  expect.truthy(row(model, { 'choices', 1 }).canRemove)
  expect.equal(#editor.draft(change(editor.remove, model, { 'choices', 1 })).choices, 0)
  local single = change(editor.add, model, { 'list' })
  expect.truthy(row(single, { 'list', 1 }).canRemove)
  expect.equal(#editor.draft(change(editor.remove, single, { 'list', 1 })).list, 0)
  local keyed = change(editor.add, model, { 'map' }, '')
  expect.truthy(row(keyed, { 'map', '' }).canRemove)
  expect.equal(next(editor.draft(change(editor.remove, keyed, { 'map', '' })).map), nil)
  reject(single, editor.remove, 'path', { 'list', 0 })
  reject(single, editor.remove, 'path', { 'list', 2 })
  reject(single, editor.remove, 'path', { 'list', '1' })
  reject(single, editor.remove, 'path', {})
  for _, config in { { list = { [2] = 9 } }, { list = { 9, extra = 10 } }, { map = { [1] = true } } } do
    local malformed = editor.new(metadata, config)
    local path = if config.list then { 'list' } else { 'map' }
    expect.truthy(row(malformed, path).readOnly)
    expect.falsy(row(malformed, path).canAdd or row(malformed, path).canRemove)
    reject(malformed, editor.add, 'readonly', path)
    reject(malformed, editor.remove, 'readonly', { path[1], if config.list then 2 else 1 })
  end
  local reference = {}
  local custom = schema.custom {
    runtimeType = 'table',
    validate = function(value)
      return value
    end,
  }
  local entry = schema.default(schema.object { count = schema.number(), custom = custom }) {
    count = 0,
    custom = reference,
  }
  local metadata = schema
    .object({
      values = schema.array(custom),
      entries = schema.array(entry),
      optional = schema.optional(entry),
    })
    .inspect()
  local model = editor.new(metadata, { values = { reference }, entries = {}, optional = { custom = reference } })
  expect.equal(editor.draft(model).values[1], reference)
  expect.equal(editor.draft(model).optional.custom, reference)
  expect.falsy(row(model, { 'values' }).canAdd)
  expect.falsy(row(model, { 'values', 1 }).canRemove)
  reject(model, editor.remove, 'readonly', { 'values', 1 })
  expect.falsy(row(model, { 'entries' }).canAdd)
  reject(model, editor.add, 'readonly', { 'entries' })
  reject(model, editor.set, 'readonly', { 'optional' }, nil)
  expect.falsy(table.isfrozen(reference))
end)

test('malformed primitive values stay read-only without freezing or losing their identity', function()
  local callback = function() end
  local metadata = schema.object({ value = schema.optional(schema.number()), enabled = schema.boolean() }).inspect()
  for _, opaque in { {}, { retained = true }, setmetatable({}, {}), callback, lovr.math.newMat4() } do
    local model = editor.new(metadata, { value = opaque, enabled = true })
    expect.equal(editor.draft(model).value, opaque)
    expect.truthy(row(model, { 'value' }).readOnly)
    expect.falsy(row(model, { 'value' }).canReset)
    reject(model, editor.set, 'readonly', { 'value' }, '3')
    reject(model, editor.set, 'readonly', { 'value' }, nil)
    reject(model, editor.reset, 'readonly', { 'value' })
    expect.equal(editor.draft(change(editor.toggle, model, { 'enabled' })).value, opaque)
    if type(opaque) == 'table' then
      expect.falsy(table.isfrozen(opaque))
    end
  end
end)

test('recursive undeclared values stay opaque while declared siblings remain editable', function()
  local reference = {}
  reference.self = reference
  local model = editor.new(schema.object({ count = schema.number() }).inspect(), { count = 1, extra = reference })
  expect.truthy(row(model, { 'extra' }).readOnly)
  expect.falsy(row(model, {}).canReset)
  local edited = change(editor.set, model, { 'count' }, '2')
  expect.equal(editor.draft(edited).extra, reference)
  expect.equal(editor.draft(edited).extra.self, reference)
  expect.falsy(table.isfrozen(reference))
end)

return test
