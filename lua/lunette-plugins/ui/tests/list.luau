local testing = require '@testing'
local collection = require '../collection'
local selection = require './support/selection'
local expect = testing.expect
local test = testing.suite()

local function fixture(items, selected, onChange)
  local state = selection.state { x = 10, y = 20, width = 100, height = 54 }
  local widget = collection.widget(
    'list',
    { id = 'list', bounds = state.bounds, items = items, selected = selected, onChange = onChange },
    selection.host(state)
  )
  state.widget = widget
  state.methods = widget.methods
  function state:items()
    return widget.items(self.clip or self.bounds, self.theme)
  end
  function state:event(kind, x, y, pointer, extra, item)
    selection.event(self, kind, x, y, extra, pointer, item)
  end
  return state
end

local function rows(count)
  return selection.rows(count, 'Row ')
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

test('item and selection updates reject malformed data and keep the previous state', function()
  local state = fixture(rows(2), '2')
  local revision = state.revision
  expect.raises(function()
    state.methods.setItems({}, { { id = 'a', label = 'A' }, { id = 'a', label = 'Again' } })
  end, 'unique')
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
