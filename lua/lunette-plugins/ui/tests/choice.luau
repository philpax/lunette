local testing = require '@testing'
local collection = require '../collection'
local selection = require './support/selection'
local expect = testing.expect
local test = testing.suite()

local function fixture(items, selected, onChange)
  local state = selection.state { x = 10, y = 20, width = 100, height = 77 }
  local widget = collection.widget('choice', {
    id = 'choice',
    bounds = state.bounds,
    label = 'Choose',
    items = items,
    selected = selected,
    onChange = onChange or function() end,
  }, selection.host(state))
  state.widget = widget
  state.methods = widget.methods
  function state:items(clip)
    return widget.items(clip or self.bounds, self.theme)
  end
  function state:visual()
    return widget.visual {
      id = 'choice',
      kind = 'choice',
      label = 'Choose',
      bounds = self.bounds,
      clip = self.bounds,
      theme = self.theme,
      enabled = true,
      hovered = false,
      pressed = false,
      focused = false,
      items = {},
    }
  end
  function state:event(kind, x, y, extra, pointer, item)
    selection.event(self, kind, x, y, extra, pointer, item)
  end
  function state:click(x, y)
    self:event('press', x, y)
    self:event('release', x, y)
  end
  return state
end

local function rows(count)
  return selection.rows(count, 'Option ')
end

test('closed choices show the selected label and expose no option hit bounds', function()
  local state = fixture(rows(3), '2')
  expect.equal(#state:items(), 0)
  expect.equal(state:visual().value, 'Option 2')
  expect.equal(state:visual().label, 'Choose')
  expect.equal(state:visual().opened, false)
  state.methods.setSelected({}, nil)
  expect.equal(state:visual().value, nil)
end)

test('opening happens on a matching primary header release without taking focus', function()
  local state = fixture(rows(3))
  state:event('press', 15, 23)
  expect.equal(state:visual().opened, false)
  state:event('release', 15, 43)
  expect.equal(state:visual().opened, true)
  state:click(15, 23)
  expect.equal(state:visual().opened, false)
  state:event('press', 15, 23, { button = 'right' })
  state:event('release', 15, 23, { button = 'right' })
  expect.equal(state:visual().opened, false)
  state:event('press', 15, 23)
  state:event 'cancel'
  state:event('release', 15, 23)
  expect.equal(state:visual().opened, false)
  expect.equal(state.focuses, 0)
  expect.equal(state.widget.wantsKeyboard, false)
  expect.equal(state.widget.receiver, nil)
end)

test('open choices reserve the header and keep options inside declared bounds', function()
  local state = fixture(rows(6))
  state.methods.setOpen({}, true)
  local items = state:items()
  expect.equal(#items, 3)
  expect.equal(items[1].bounds.x, 12)
  expect.equal(items[1].bounds.y, 45)
  expect.equal(items[1].bounds.height, 20)
  expect.equal(items[2].bounds.y, 68)
  expect.equal(items[3].bounds.y, 91)
  expect.equal(items[3].bounds.height, 4)
  expect.equal(state:visual().overflow, true)
  expect.equal(state:visual().items[1].bounds.y, 45)
  for _, item in items do
    expect.truthy(item.bounds.y + item.bounds.height <= 95)
  end
end)

test('clip rectangles never relocate the layout origin', function()
  local state = fixture(rows(4))
  state.methods.setOpen({}, true)
  local clipped = state:items { x = 20, y = 50, width = 70, height = 24 }
  expect.equal(#clipped, 2)
  expect.equal(clipped[1].id, '1')
  expect.equal(clipped[1].bounds.x, 20)
  expect.equal(clipped[1].bounds.y, 50)
  expect.equal(clipped[1].bounds.height, 15)
  expect.equal(clipped[2].bounds.y, 68)
  expect.equal(clipped[2].bounds.height, 6)
end)

test('insufficient space and empty content keep choices closed', function()
  local empty = fixture {}
  empty.methods.setOpen({}, true)
  empty:click(15, 23)
  expect.equal(empty:visual().opened, false)
  local state = fixture(rows(1))
  state.bounds = { x = 10, y = 20, width = 100, height = 46 }
  state.methods.setOpen({}, true)
  expect.equal(state:visual().opened, false)
  state.bounds = { x = 10, y = 20, width = 100, height = 47 }
  state.methods.setOpen({}, true)
  expect.equal(state:visual().opened, true)
  expect.equal(state:items()[1].bounds.height, 20)
end)

test('long choices are completely reachable through logical pixel pointer scrolling', function()
  local changes = {}
  local state = fixture(rows(20), nil, function(id)
    table.insert(changes, id)
  end)
  state:click(15, 23)
  state:event('scroll', 15, 50, { dx = 100, dy = 10000 })
  local items = state:items()
  expect.equal(items[#items].id, '20')
  local last = items[#items].bounds
  state:click(last.x + 1, last.y + 1)
  expect.equal(state.methods.selected {}, '20')
  expect.equal(changes[1], '20')
  expect.equal(state:visual().opened, false)
  expect.equal(state:visual().value, 'Option 20')
  state.methods.setOpen({}, true)
  state.methods.scroll({}, -10000)
  expect.equal(state:items()[1].id, '1')
end)

test('option releases require the original enabled id and unchanged bounds', function()
  local items = rows(5)
  items[1].enabled = false
  local state = fixture(items)
  state.methods.setOpen({}, true)
  state:click(15, 46)
  expect.equal(state.methods.selected {}, nil)
  state:event('press', 15, 69)
  state:event('release', 15, 92)
  expect.equal(state.methods.selected {}, nil)
  state:event('press', 15, 69)
  state.methods.scroll({}, 1)
  state:event('release', 15, 69)
  expect.equal(state.methods.selected {}, nil)
  state:event('press', 15, 69)
  state.methods.setOpen({}, false)
  expect.equal(state.cancels[#state.cancels], 'control-removed')
  state:event('release', 15, 69)
  expect.equal(state.methods.selected {}, nil)
end)

test('item replacement retains stable selection and cancels active option captures', function()
  local state = fixture(rows(4), '2')
  state.methods.setOpen({}, true)
  state:event('press', 15, 69)
  state.methods.setItems({}, { { id = '2', label = 'Retained' } })
  expect.equal(state.methods.selected {}, '2')
  expect.equal(state:visual().value, 'Retained')
  state:event('release', 15, 69)
  state.methods.setItems({}, { { id = '1', label = 'Other' } })
  expect.equal(state.methods.selected {}, nil)
  state.methods.setItems({}, {})
  expect.equal(state:visual().opened, false)
  expect.equal(#state:items(), 0)
end)

test('callbacks see committed selection and closed state and may reopen replace or fail', function()
  local state
  state = fixture(rows(3), nil, function(id)
    expect.equal(state.methods.selected {}, id)
    expect.equal(state:visual().opened, false)
    state.methods.setItems({}, rows(1))
    state.methods.setOpen({}, true)
    error 'expected callback failure'
  end)
  state:click(15, 23)
  state:click(15, 69)
  expect.equal(state.methods.selected {}, nil)
  expect.equal(state:visual().opened, true)
  expect.equal(#state.reports, 1)
  state:event('release', 15, 69)
  expect.equal(#state.reports, 1)
end)

test('capture cancellation may reenter item updates without being overwritten', function()
  local state = fixture(rows(3))
  state.methods.setOpen({}, true)
  state:event('press', 15, 69)
  state.onCancel = function()
    state.onCancel = nil
    state.methods.setItems({}, { { id = 'last', label = 'Final' } })
    state.methods.setSelected({}, 'last')
  end
  state.methods.setItems({}, rows(2))
  expect.equal(state.methods.selected {}, 'last')
  expect.equal(state:items()[1].id, 'last')
  state:event('release', 15, 69)
  expect.equal(state.methods.selected {}, 'last')
  state.live = false
  local revision = state.revision
  state.methods.setItems({}, rows(10))
  state.methods.setOpen({}, false)
  state.methods.scroll({}, 10)
  state.methods.setSelected({}, 'missing')
  expect.equal(state.revision, revision)
end)

test('surface eligibility guards choice headers and options with matching projected coordinates', function()
  local state = fixture { { id = 'one', label = 'One' }, { id = 'two', label = 'Two' } }
  state:event('press', 15, 23)
  state:event('release', 15, 23, { inside = false })
  expect.falsy(state:visual().opened, 'an outside release cannot open the header')
  state:event('press', 15, 23, { inside = false })
  state:event('release', 15, 23)
  expect.falsy(state:visual().opened, 'an outside press cannot arm the header')
  state.methods.setOpen({}, true)
  local row = state:items()[1].bounds
  local x, y = row.x + row.width / 2, row.y + row.height / 2
  state:event('press', x, y)
  state:event('release', x, y, { inside = false })
  expect.equal(state.methods.selected {}, nil, 'an outside option release cannot select')
  state:event('press', x, y, { inside = false })
  state:event('release', x, y)
  expect.equal(state.methods.selected {}, nil, 'an outside option press cannot arm')
  state:event('press', x, y)
  state:event('release', x, y)
  expect.equal(state.methods.selected {}, 'one', 'an eligible fresh option gesture selects')
end)

return test
