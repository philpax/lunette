local testing = require '@testing'
local rows = require '../rows'
local expect = testing.expect
local test = testing.suite()

local function descriptor()
  return {
    id = 'draft',
    label = 'Draft',
    group = 'Session',
    order = 10,
    enabled = true,
    selected = false,
    registration = { kind = 'menu-registration' },
  }
end

test('snapshot equality compares every display field and token reference', function()
  expect.truthy(rows.same({}, {}))
  local before = descriptor()
  expect.truthy(rows.same({ before }, { table.clone(before) }))
  for field, changed in
    {
      id = 'other',
      label = 'Other',
      group = 'Workspaces',
      order = 11,
      enabled = false,
      selected = true,
      registration = { kind = 'menu-registration' },
    }
  do
    local after = table.clone(before)
    after[field] = changed
    expect.equal(rows.same({ before }, { after }), false, field)
  end
  expect.equal(rows.same({ before }, {}), false)
  expect.equal(rows.same({}, { before }), false)
end)

test('rows expose group enabled and independent selected states without retaining callbacks', function()
  local first = descriptor()
  first.selected = true
  local second = descriptor()
  second.id, second.group, second.enabled = 'other', '', false
  local items = rows.items { first, second }
  expect.equal(items[1].label, 'Session: Draft [selected]')
  expect.equal(items[2].label, 'Draft [disabled]')
  expect.equal(items[2].enabled, false)
  expect.equal(items[1].registration, nil)
  expect.equal(rows.find({ first, second }, 'other'), second)
  expect.equal(rows.find({ first, second }, 'missing'), nil)
end)

return test
