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

test('native vectors replace atomically and retain their value through frozen copies', function()
  local position = vector.pack(1, 2, 3)
  local defaults = { position = position }
  local copied = plugin.options { name = 'vector-options', defaults = defaults, config = nil }
  expect.equal(copied.position, position, 'the native vector default')
  local replacement = vector.pack(-2, 4, 0)
  local configured =
    plugin.options { name = 'vector-options', defaults = defaults, config = { position = replacement } }
  expect.equal(configured.position, replacement, 'the complete vector replaces its default')
  expect.equal(defaults.position, position, 'the default remains unchanged')
  expect.raises(function()
    plugin.options { name = 'vector-options', defaults = defaults, config = { position = { 1, 2, 3 } } }
  end, 'option position is a vector, not a table')
end)

test('vector validation rejects nonfinite components and nonvector values', function()
  plugin.checkVector('vector-options', 'position', vector.pack(0, -1, 2))
  for _, value in { {}, 'position', 42 } do
    expect.raises(function()
      plugin.checkVector('vector-options', 'position', value)
    end, 'option position is a vector')
  end
  for _, invalid in { math.huge, -math.huge, 0 / 0 } do
    for _, axis in { 'x', 'y', 'z' } do
      local value = vector.pack(
        if axis == 'x' then invalid else 0,
        if axis == 'y' then invalid else 0,
        if axis == 'z' then invalid else 0
      )
      expect.raises(function()
        plugin.checkVector('vector-options', 'position', value)
      end, 'position.' .. axis .. ' is a finite number')
    end
  end
end)

return test
