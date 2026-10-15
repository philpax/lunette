local testing = require '@testing'
local expect = testing.expect
local schema = require '@lunette-plugin/schema'
local editor = require '../private/composition/editor'
local test = testing.suite()

type Draft = {
  enabled: boolean,
  title: string,
  style: { width: number },
  list: { { name: string } },
  map: { [string]: number },
  position: vector,
  mode: 'quiet' | 'paused',
  detail: { label: string, count: number }?,
}
type OpaqueDraft = { count: number, callback: () -> (), custom: {}, extra: { retained: boolean } }

local function row(model: editor.Model, path: editor.Path): editor.Row
  for _, item in editor.rows(model) do
    if table.concat(item.path, '.') == table.concat(path, '.') then
      return item
    end
  end
  error('missing row ' .. table.concat(path, '.'))
end

local function change<A...>(operation: (A...) -> (editor.Model?, editor.Problem?), ...: A...): editor.Model
  local model, problem = operation(...)
  assert(model, if problem then problem.message else 'missing draft')
  return model
end

local function reject<A...>(
  model: editor.Model,
  operation: (editor.Model, A...) -> (editor.Model?, editor.Problem?),
  code: editor.Code,
  ...: A...
)
  local draft = editor.draft(model)
  local result, problem = operation(model, ...)
  expect.equal(result, nil)
  expect.equal(problem.code, code)
  expect.equal(editor.draft(model), draft)
end

local function fixture(): schema.Metadata
  local shape = schema.object {
    enabled = schema.default(schema.boolean())(true),
    title = schema.describe(schema.default(schema.string()) 'Initial') { label = 'Title' },
    style = schema.default(schema.object {
      width = schema.default(schema.number())(1),
    }) { width = 10 },
    list = schema.default(schema.array(schema.object { name = schema.default(schema.string()) 'new' })) {
      { name = 'one' },
      { name = 'two' },
    },
    map = schema.default(schema.map(schema.number())) { retained = 4 },
    position = schema.default(schema.vector())(vector.pack(1, 2, 3)),
    mode = schema.default(schema.enum { 'quiet', 'paused' }) 'quiet',
    detail = schema.optional(schema.object { label = schema.string(), count = schema.default(schema.number())(7) }),
  }
  return schema.default(shape)(shape.parse {}).inspect()
end

test('defaults resolve like the schema and rows describe each field', function()
  local model = editor.new(fixture(), { list = {} })
  local value: Draft = editor.draft(model)
  expect.equal(value.style.width, 10)
  expect.equal(#value.list, 0, 'an explicit empty collection replaces the default')
  expect.equal(value.title, 'Initial')
  expect.equal(row(model, { 'title' }).label, 'Title')
  expect.equal(row(model, { 'position', 'z' }).value, 3)
  expect.equal(row(model, { 'detail' }).control, 'optional')
end)

test('primitive fields parse text without evaluating it', function()
  local model = editor.new(fixture(), {})
  for _, input in { '1e999', '0/0', 'return 3' } do
    reject(model, editor.set, 'input', { 'style', 'width' }, input)
  end
  expect.equal(editor.draft(change(editor.set, model, { 'style', 'width' }, '-1.25e2')).style.width, -125)
  expect.equal(editor.draft(change(editor.set, model, { 'title' }, 'return 1')).title, 'return 1')
  expect.equal(editor.draft(change(editor.toggle, model, { 'enabled' })).enabled, false)
  local modes = row(model, { 'mode' })
  expect.equal(editor.draft(change(editor.set, model, { 'mode' }, modes.choices[2])).mode, 'paused')
  reject(model, editor.set, 'input', { 'mode' }, 'unknown')
  local edited = change(editor.reset, change(editor.set, model, { 'style', 'width' }, '3'), { 'style', 'width' })
  expect.equal(editor.draft(edited).style.width, 10, 'reset restores the bound default')
end)

test('vector components edit and reset as native vectors', function()
  local model = editor.new(fixture(), {})
  local updated = change(editor.set, model, { 'position', 'y' }, '9.5')
  expect.equal(editor.draft(updated).position, vector.pack(1, 9.5, 3))
  expect.equal(editor.draft(model).position, vector.pack(1, 2, 3), 'the previous draft is unchanged')
  reject(updated, editor.set, 'input', { 'position', 'z' }, '1e100')
  expect.equal(editor.draft(change(editor.reset, updated, { 'position', 'y' })).position, vector.pack(1, 2, 3))
end)

test('arrays, maps, and optionals add, edit, and remove members', function()
  local model = editor.new(fixture(), {})
  local added = change(editor.add, model, { 'list' })
  expect.equal(editor.draft(added).list[3].name, 'new')
  local removed = change(editor.remove, change(editor.set, added, { 'list', 2, 'name' }, 'changed'), { 'list', 1 })
  expect.equal(#editor.draft(removed).list, 2)
  expect.equal(editor.draft(removed).list[1].name, 'changed')
  local keyed = change(editor.set, change(editor.add, model, { 'map' }, 'a.b'), { 'map', 'a.b' }, '12')
  expect.equal(editor.draft(keyed).map['a.b'], 12)
  reject(keyed, editor.add, 'key', { 'map' }, 'a.b')
  expect.equal(editor.draft(change(editor.remove, keyed, { 'map', 'retained' })).map.retained, nil)
  reject(model, editor.set, 'path', { 'detail', 'count' }, '3')
  local detail = change(editor.toggle, model, { 'detail' })
  expect.equal(editor.draft(detail).detail.count, 7, 'a seeded optional takes its defaults')
  expect.equal(editor.draft(change(editor.toggle, detail, { 'detail' })).detail, nil)
end)

test('strings the field cannot show are escaped and round-trip losslessly', function()
  local metadata = schema.object({ text = schema.string() }).inspect()
  local original = 'first\n\t' .. utf8.char(0x2028) .. string.char(255)
  local model = editor.new(metadata, { text = original })
  local item = row(model, { 'text' })
  expect.truthy(item.escaped)
  expect.equal(item.text, 'first\\n\\t\\xE2\\x80\\xA8\\xFF')
  expect.equal(change(editor.setText, model, { 'text' }, item.text), model, 'unchanged text keeps the draft')
  local edited = change(editor.setText, model, { 'text' }, item.text .. '\\x00')
  expect.equal(editor.draft(edited).text, original .. '\0')
  for _, input in { '\\q', '\\xGG', '\n' } do
    reject(model, editor.setText, 'input', { 'text' }, input)
  end
  local literal = editor.new(metadata, { text = '\\n é' })
  expect.falsy(row(literal, { 'text' }).escaped)
  expect.equal(
    editor.draft(change(editor.setText, literal, { 'text' }, '\\n')).text,
    '\\n',
    'literal mode does not decode'
  )
end)

test('opaque and undeclared values survive edits and stay read-only', function()
  local callback = function() end
  local custom = setmetatable({}, {})
  local metadata = schema
    .default(schema.object {
      count = schema.number(),
      callback = schema.callback(callback),
      custom = schema.custom {
        runtimeType = 'table',
        validate = function(value: unknown): unknown
          return value
        end,
      },
    })({ count = 1, callback = callback, custom = custom })
    .inspect()
  local extra = { retained = true }
  local model = editor.new(metadata, { extra = extra })
  local draft: OpaqueDraft = editor.draft(change(editor.set, model, { 'count' }, '3'))
  expect.equal(draft.callback, callback)
  expect.equal(draft.custom, custom)
  expect.equal(draft.extra, extra)
  expect.falsy(table.isfrozen(custom))
  for _, path in { { 'callback' }, { 'custom' }, { 'extra' } } do
    expect.truthy(row(model, path).readOnly)
    reject(model, editor.set, 'readonly', path, 'replacement')
  end
  reject(model, editor.reset, 'readonly', {})
end)

return test
