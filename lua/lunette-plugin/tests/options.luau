-- Covers plugin.options, which merges a configuration over defaults and names what it rejects, and
-- plugin.merge, which applies the same rule without validating.
local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'

local test = testing.suite()

local DEFAULTS = {
  style = { length = 1, color = { 0, 0, 1, 1 }, inner = { depth = 2 } },
  count = 3,
}

local function resolve(config)
  return plugin.options { name = 'probe', defaults = DEFAULTS, config = config }
end

test('no configuration answers a fresh frozen copy of the defaults', function()
  local first, second = resolve(nil), resolve(nil)
  expect.truthy(first ~= second and first.style ~= DEFAULTS.style, 'each resolution is a copy')
  expect.equal(first.style.length, 1, 'a default')
  expect.truthy(table.isfrozen(first) and table.isfrozen(first.style.color), 'the copy is frozen to its depth')
  expect.falsy(table.isfrozen(DEFAULTS), 'the defaults are not changed')
end)

test('a record merges key by key at every depth, and a list replaces', function()
  local nested = resolve { style = { inner = { depth = 5 } } }
  expect.equal(nested.style.inner.depth, 5, 'the configured option')
  expect.equal(nested.style.length, 1, 'a sibling default')
  expect.equal(nested.style.color[3], 1, 'a default list')
  expect.equal(#resolve({ style = { color = { 1 } } }).style.color, 1, 'a configured list')
  expect.equal(resolve(nested).style.inner.depth, 5, 'a resolved configuration resolves to itself')
end)

test('an unknown option or a wrong type is named with its path', function()
  expect.raises(function()
    resolve { style = { inner = { width = 1 } } }
  end, 'plugin probe: unknown option style.inner.width; the options are depth', 'an unknown option')
  expect.raises(function()
    resolve { count = 'three' }
  end, 'plugin probe: option count is a number, not a string', 'a wrong type')
end)

test('merge follows the same rule without validating, and changes neither side', function()
  local base = { style = { length = 1, color = { 0, 0, 1 } }, extra = true }
  local over = { style = { color = { 1 } }, added = 2 }
  local merged = plugin.merge { base = base, over = over }
  expect.truthy(merged.style.length == 1 and #merged.style.color == 1, 'the merged style')
  expect.truthy(merged.extra and merged.added == 2, 'the keys of both sides')
  expect.truthy(#base.style.color == 3 and over.style.length == nil, 'neither side changes')
end)

return test
