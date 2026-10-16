local testing = require '@testing'
local expect = testing.expect
local restore = require '../private/restore'
local layout = require '../private/layout'
local test = testing.suite()

local function entry(id: string, config: unknown, enabled: boolean, protected: boolean?): restore.Entry
  return { id = id, config = config, enabled = enabled, protected = protected == true }
end

local function describe(operations: { restore.Operation }): string
  local parts: { string } = {}
  for _, operation in operations do
    parts[#parts + 1] = operation.kind .. ' ' .. operation.id
  end
  return table.concat(parts, ', ')
end

test('equal compares configurations structurally', function()
  expect.truthy(restore.equal({ a = 1, b = { 2, 3 } }, { a = 1, b = { 2, 3 } }), 'equal nested tables')
  expect.falsy(restore.equal({ a = 1 }, { a = 1, b = 2 }), 'an extra key')
  expect.falsy(restore.equal({ a = { 1 } }, { a = { 2 } }), 'a nested difference')
  expect.truthy(restore.equal(vector.pack(1, 2, 3), vector.pack(1, 2, 3)), 'vectors by value')
  expect.falsy(restore.equal(1, '1'), 'different types')
end)

test('a composition that matches the record needs no calls', function()
  local current = { entry('a', { v = 1 }, true), entry('b', {}, false) }
  local good = restore.capture(current)
  expect.equal(#restore.plan(current, good), 0, 'nothing to do')
  expect.truthy(restore.same(good, restore.capture(current)), 'the same composition')
end)

test('the plan disables first, then configures and restores, then enables', function()
  local good = restore.capture {
    entry('a', { v = 1 }, true),
    entry('b', {}, false),
    entry('c', {}, true),
    entry('gone', { v = 3 }, true),
  }
  local current = {
    entry('a', { v = 2 }, true),
    entry('b', {}, true),
    entry('c', {}, false),
    entry('extra', {}, true),
  }
  expect.equal(
    describe(restore.plan(current, good)),
    'disable b, disable extra, configure a, restore gone, enable c',
    'the operations in order'
  )
  expect.falsy(restore.same(good, restore.capture(current)), 'the compositions differ')
end)

test('protected entries are never changed', function()
  local good = restore.capture { entry('manager', { v = 1 }, true) }
  local current = { entry('manager', { v = 2 }, false, true), entry('menu', {}, true, true) }
  expect.equal(#restore.plan(current, good), 0, 'protected entries are left alone')
end)

test('a restored entry the record names as disabled is disabled after its restore', function()
  local good = restore.capture { entry('gone', {}, false) }
  expect.equal(describe(restore.plan({}, good)), 'restore gone, disable gone', 'restore, then disable')
end)

test('clip keeps the first line and cuts long text with an ellipsis', function()
  expect.equal(layout.clip('first\nsecond', 20), 'first', 'the first line')
  expect.equal(layout.clip('abcdef', 4), 'abc…', 'cut to the column count')
  expect.equal(layout.clip('ééééé', 3), 'éé…', 'cut by characters, not bytes')
  expect.equal(layout.clip('abc', 3), 'abc', 'exactly the column count')
end)

return test
