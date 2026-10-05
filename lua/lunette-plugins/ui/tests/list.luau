local testing = require '@testing'
local list = require '../list'
local expect = testing.expect
local test = testing.suite()

local function fixture(items, selected, onChange)
  local state = { live = true, revision = 0, cancels = {}, reports = {}, focuses = 0 }
  state.bounds = { x = 10, y = 20, width = 100, height = 54 }
  state.theme = { rowHeight = 20, padding = 2, spacing = 3 }
  local widget
  local host = {
    live = function()
      return state.live
    end,
    changed = function()
      state.revision += 1
    end,
    cancel = function(reason)
      table.insert(state.cancels, reason)
      if state.onCancel then
        state.onCancel()
      end
    end,
    focus = function()
      state.focuses += 1
      return true
    end,
    blur = function()
      state.focuses += 1
      return true
    end,
    bounds = function()
      return state.bounds
    end,
    theme = function()
      return state.theme
    end,
    callback = function(label, run)
      local ok, message = pcall(run)
      if not ok then
        table.insert(state.reports, { label = label, message = tostring(message) })
      end
      return ok
    end,
  }
  widget =
    list.new({ id = 'list', bounds = state.bounds, items = items, selected = selected, onChange = onChange }, host)
  state.widget = widget
  state.methods = widget.methods
  function state:items()
    return widget.items(self.clip or self.bounds, self.theme)
  end
  function state:event(kind, x, y, pointer, extra, item)
    local event = { kind = kind, x = x, y = y, pointer = pointer or self.pointer, inside = true, captured = true }
    if kind == 'press' or kind == 'release' or kind == 'cancel' then
      event.button = 'left'
    end
    if kind == 'cancel' then
      event.reason = 'disabled'
    end
    if extra then
      for key, value in extra do
        event[key] = value
      end
    end
    if item == nil and x and y then
      for _, row in self:items() do
        local bounds = row.bounds
        if x >= bounds.x and x < bounds.x + bounds.width and y >= bounds.y and y < bounds.y + bounds.height then
          item = row.id
          break
        end
      end
    end
    widget.pointer(event, item)
  end
  state.pointer = {}
  return state
end

local function rows(count)
  local result = {}
  for index = 1, count do
    result[index] = { id = tostring(index), label = 'Row ' .. index }
  end
  return result
end

local function visual(state)
  return state.widget.visual {
    id = 'list',
    kind = 'list',
    label = 'Rows',
    bounds = state.bounds,
    clip = state.bounds,
    theme = state.theme,
    enabled = true,
    hovered = false,
    pressed = false,
    focused = false,
    items = {},
  }
end

test('empty and single lists preserve their exact content', function()
  local empty = fixture {}
  expect.equal(#empty:items(), 0)
  expect.equal(empty.methods.selected {}, nil)
  expect.equal(visual(empty).overflow, false)
  local single = fixture(rows(1), '1')
  expect.equal(#single:items(), 1)
  expect.equal(single:items()[1].selected, true)
  expect.equal(single:items()[1].bounds.x, 12)
  expect.equal(single:items()[1].bounds.y, 22)
  expect.equal(single:items()[1].bounds.width, 96)
  expect.equal(single:items()[1].bounds.height, 20)
end)

test('item snapshots do not alias caller tables or returned descriptions', function()
  local source = rows(2)
  local state = fixture(source, '1')
  source[1].id = 'changed'
  source[1].label = 'Changed'
  table.clear(source)
  local item = state:items()[1]
  expect.equal(item.id, '1')
  expect.equal(item.label, 'Row 1')
  expect.truthy(table.isfrozen(item))
  expect.truthy(table.isfrozen(item.bounds))
  expect.truthy(table.isfrozen(state:items()))
end)

test('plain dense arrays and unique nonempty stable ids are required', function()
  local malformed = {
    setmetatable({}, {}),
    { [2] = { id = 'b', label = 'B' } },
    { extra = true },
    { { id = '', label = 'Empty' } },
    { { id = 'a', label = 'A' }, { id = 'a', label = 'Again' } },
    { setmetatable({ id = 'a', label = 'A' }, {}) },
    { { id = 'a', label = 1 } },
    { { id = 'a', label = 'A', enabled = 'yes' } },
    { { id = 'a', label = 'A', extra = true } },
  }
  for _, items in malformed do
    expect.raises(function()
      fixture(items)
    end, 'ui list')
  end
  expect.raises(function()
    fixture(rows(1), 'missing')
  end, 'selected')
  local state = fixture(rows(2), '2')
  local revision = state.revision
  expect.raises(function()
    state.methods.setItems({}, malformed[5])
  end, 'duplicate')
  expect.raises(function()
    state.methods.setSelected({}, 'missing')
  end, 'selected')
  expect.equal(state.methods.selected {}, '2')
  expect.equal(state.revision, revision)
end)

test('scroll is a relative logical pixel delta and clips partial rows', function()
  local state = fixture(rows(6))
  state.methods.scroll({}, 5.5)
  local items = state:items()
  expect.equal(items[1].id, '1')
  expect.equal(items[1].bounds.y, 22)
  expect.equal(items[1].bounds.height, 14.5)
  expect.equal(items[2].bounds.y, 39.5)
  expect.equal(items[3].bounds.y, 62.5)
  expect.equal(items[3].bounds.height, 9.5)
  expect.equal(visual(state).overflow, true)
  state:event('scroll', 15, 25, nil, { dx = 999, dy = 17.5 })
  expect.equal(state:items()[1].id, '2')
  expect.equal(state:items()[1].bounds.y, 22)
  state.methods.scroll({}, 10000)
  expect.equal(state:items()[#state:items()].id, '6')
  state.methods.scroll({}, -10000)
  expect.equal(state:items()[1].id, '1')
  expect.raises(function()
    state.methods.scroll({}, 0 / 0)
  end, 'finite')
  expect.raises(function()
    state.methods.scroll({}, math.huge)
  end, 'finite')
end)

test('shrinking and emptying clamp scroll and clear only removed selections', function()
  local changes = 0
  local state = fixture(rows(8), '8', function()
    changes += 1
  end)
  state.methods.scroll({}, 10000)
  state.methods.setItems({}, rows(2))
  expect.equal(state:items()[1].id, '1')
  expect.equal(state.methods.selected {}, nil)
  state.methods.setSelected({}, '2')
  state.methods.setItems({}, { { id = '2', label = 'Retained' } })
  expect.equal(state.methods.selected {}, '2')
  state.methods.setItems({}, {})
  expect.equal(#state:items(), 0)
  expect.equal(state.methods.selected {}, nil)
  expect.equal(changes, 0)
end)

test('surface eligibility is required even when projected list coordinates match', function()
  local state = fixture(rows(4))
  state:event('press', 15, 23)
  state:event('release', 15, 23, nil, { inside = false })
  expect.equal(state.methods.selected {}, nil, 'an outside release consumes without selecting')
  state:event('release', 15, 23)
  expect.equal(state.methods.selected {}, nil, 'the consumed gesture cannot activate later')
  state:event('press', 15, 23, nil, { inside = false })
  state:event('release', 15, 23)
  expect.equal(state.methods.selected {}, nil, 'an outside press does not arm a gesture')
  state:event('press', 15, 23)
  state:event('release', 15, 23)
  expect.equal(state.methods.selected {}, '1', 'a fresh eligible gesture selects')
end)

test('only matching primary releases inside the original half-open row activate', function()
  local changes = {}
  local state = fixture(rows(4), nil, function(id)
    table.insert(changes, id)
  end)
  state:event('press', 15, 23)
  state:event('release', 15, 46)
  expect.equal(#changes, 0)
  state:event('release', 15, 23)
  expect.equal(#changes, 0)
  state:event('press', 15, 23)
  state:event('release', 15, 23, {})
  expect.equal(#changes, 0)
  state:event('release', 15, 23)
  expect.equal(changes[1], '1')
  state:event('press', 15, 45)
  state:event('release', 15, 45)
  expect.equal(changes[2], '2')
  state:event('press', 15, 23, nil, { button = 'right' })
  state:event('release', 15, 23, nil, { button = 'right' })
  expect.equal(#changes, 2)
  state:event('press', 15, 23)
  state:event('release', 108, 23)
  expect.equal(#changes, 2)
  expect.equal(state.focuses, 0)
  expect.equal(state.widget.wantsKeyboard, false)
  expect.equal(state.widget.receiver, nil)
end)

test('gaps disabled rows offscreen ids and cancelled presses never select', function()
  local items = rows(4)
  items[1].enabled = false
  local state = fixture(items)
  state:event('press', 15, 23, nil, nil, '1')
  state:event('release', 15, 23, nil, nil, '1')
  state:event('press', 15, 43)
  state:event('release', 15, 43)
  state:event('press', 15, 46, nil, nil, '4')
  state:event('release', 15, 46, nil, nil, '4')
  expect.equal(state.methods.selected {}, nil)
  state:event('press', 15, 46)
  state:event('cancel', nil, nil)
  state:event('release', 15, 46)
  expect.equal(state.methods.selected {}, nil)
end)

test('item and geometry changes cannot retarget an existing capture', function()
  local state = fixture(rows(4))
  state:event('press', 15, 23)
  state.methods.setItems({}, rows(4))
  expect.equal(state.cancels[1], 'control-removed')
  state:event('release', 15, 23)
  expect.equal(state.methods.selected {}, nil)
  state:event('press', 15, 23)
  state.bounds = { x = 11, y = 20, width = 100, height = 54 }
  state:event('release', 15, 23)
  expect.equal(state.methods.selected {}, nil)
  state:event('press', 15, 23)
  state.methods.scroll({}, 1)
  state:event('release', 15, 23)
  expect.equal(state.methods.selected {}, nil)
end)

test('clip rectangles preserve layout and clip changes invalidate captured row bounds', function()
  local state = fixture(rows(3))
  state.clip = { x = 20, y = 30, width = 70, height = 24 }
  local items = state:items()
  expect.equal(items[1].bounds.y, 30)
  expect.equal(items[1].bounds.height, 12)
  expect.equal(items[2].bounds.y, 45)
  expect.equal(items[2].bounds.height, 9)
  state:event('press', 21, 31)
  state.clip = { x = 20, y = 32, width = 70, height = 22 }
  state:event('release', 21, 33)
  expect.equal(state.methods.selected {}, nil)
  state:event('press', 21, 33)
  state:event('release', 21, 33)
  expect.equal(state.methods.selected {}, '1')
end)

test('nonexclusive pointer captures remain independent', function()
  local state = fixture(rows(3))
  local other = {}
  state:event('press', 15, 23)
  state:event('press', 15, 46, other)
  state:event('release', 15, 46, other)
  expect.equal(state.methods.selected {}, '2')
  state:event('release', 15, 23)
  expect.equal(state.methods.selected {}, '1')
end)

test('selection commits before protected callbacks and supports replacement or teardown', function()
  local state
  state = fixture(rows(3), nil, function(id)
    expect.equal(state.methods.selected {}, id)
    state.methods.setItems({}, rows(1))
    error 'expected callback failure'
  end)
  state:event('press', 15, 46)
  state:event('release', 15, 46)
  expect.equal(state.methods.selected {}, nil)
  expect.equal(#state.reports, 1)
  expect.truthy(state.reports[1].message:find('expected callback failure', 1, true))
  state:event('release', 15, 46)
  expect.equal(#state.reports, 1)
  local dead
  dead = fixture(rows(1), nil, function()
    dead.live = false
  end)
  dead:event('press', 15, 23)
  dead:event('release', 15, 23)
  local revision = dead.revision
  dead.methods.setItems({}, rows(4))
  dead.methods.setSelected({}, 'missing')
  dead.methods.scroll({}, 100)
  dead:event('press', 15, 23)
  expect.equal(dead.revision, revision)
end)

test('all visible rows stay disjoint and within the viewport across fractional scrolling', function()
  for count = 0, 12 do
    local state = fixture(rows(count))
    for _, delta in { 0, 0.25, 7.75, 16, 90, -30, -1000 } do
      state.methods.scroll({}, delta)
      local bottom = 22
      for _, item in state:items() do
        expect.truthy(item.bounds.y >= bottom)
        expect.truthy(item.bounds.height > 0)
        expect.truthy(item.bounds.y + item.bounds.height <= 72)
        expect.equal(item.bounds.x, 12)
        expect.equal(item.bounds.width, 96)
        bottom = item.bounds.y + item.bounds.height
      end
    end
  end
end)

return test
