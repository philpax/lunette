local testing = require '@testing'
local collection = require '../collection'
local expect = testing.expect
local test = testing.suite()

type ui = typeof(require '@lunette-contracts/ui')
type vocabulary = typeof(require '@lunette-contracts/vocabulary')
type lunette = typeof(require '@lunette')
type Row = { id: string, label: string, enabled: boolean? }
type Theme = { rowHeight: number, padding: number, spacing: number }
type Item = { id: string, label: string, enabled: boolean, selected: boolean, bounds: ui.Bounds }
type Visual = {
  id: string,
  kind: 'choice' | 'list',
  label: string,
  bounds: ui.Bounds,
  clip: ui.Bounds,
  theme: Theme,
  enabled: boolean,
  hovered: boolean,
  pressed: boolean,
  focused: boolean,
  items: { Item },
  value: string?,
  opened: boolean?,
  overflow: boolean?,
}
type Extra = { button: lunette.PointerButton?, dx: number?, dy: number?, reason: vocabulary.CancelReason? }
type Methods = {
  setItems: <R>(R, { Row }) -> (),
  setSelected: <R>(R, string?) -> (),
}
type State = {
  bounds: ui.Bounds,
  changes: { string },
  focuses: number,
  methods: Methods?,
  items: (() -> { Item })?,
  visual: (() -> Visual)?,
  event: (('press' | 'release' | 'cancel' | 'scroll', number?, number?, Extra?) -> ())?,
  click: ((number, number, Extra?) -> ())?,
}
type Event = {
  kind: 'press' | 'release' | 'cancel' | 'scroll',
  x: number?,
  y: number?,
  pointer: State,
  inside: boolean,
  captured: boolean,
  button: lunette.PointerButton,
  dx: number?,
  dy: number?,
  reason: vocabulary.CancelReason?,
}

local THEME = { rowHeight = 20, padding = 2, spacing = 3 }

local function rows(count: number): { Row }
  local items: { Row } = {}
  for index = 1, count do
    items[index] = { id = tostring(index), label = 'Row ' .. index }
  end
  return items
end

local function fixture(kind: 'choice' | 'list', height: number, items: { Row }, selected: string?): State
  local state: State = { bounds = { x = 10, y = 20, width = 100, height = height }, changes = {}, focuses = 0 }
  local host = {
    live = function(): boolean
      return true
    end,
    changed = function() end,
    cancel = function() end,
    focus = function(): boolean
      state.focuses += 1
      return true
    end,
    blur = function(): boolean
      return true
    end,
    bounds = function(): ui.Bounds
      return state.bounds
    end,
    theme = function(): Theme
      return THEME
    end,
    callback = function(_: string, run: () -> ()): boolean
      run()
      return true
    end,
  }
  local widget = collection.widget(kind, {
    id = kind,
    bounds = state.bounds,
    label = 'Rows',
    items = items,
    selected = selected,
    onChange = function(id: string)
      table.insert(state.changes, id)
    end,
  }, host)
  state.methods = widget.methods
  function state.items(): { Item }
    return widget.items(state.bounds, THEME)
  end
  function state.visual(): Visual
    return widget.visual {
      id = kind,
      kind = kind,
      label = 'Rows',
      bounds = state.bounds,
      clip = state.bounds,
      theme = THEME,
      enabled = true,
      hovered = false,
      pressed = false,
      focused = false,
      items = {},
    }
  end
  function state.event(kind: 'press' | 'release' | 'cancel' | 'scroll', x: number?, y: number?, extra: Extra?)
    local event: Event = { kind = kind, x = x, y = y, pointer = state, inside = true, captured = true, button = 'left' }
    for key, value in extra or {} do
      event[key] = value
    end
    local item: string?
    for _, row in state.items() do
      local b = row.bounds
      if x and y and x >= b.x and x < b.x + b.width and y >= b.y and y < b.y + b.height then
        item = row.id
      end
    end
    widget.pointer(event, item)
  end
  function state.click(x: number, y: number, extra: Extra?)
    state.event('press', x, y, extra)
    state.event('release', x, y, extra)
  end
  return state
end

test('a closed choice shows its selection and opens on a primary header release', function()
  local state = fixture('choice', 77, rows(3), '2')
  expect.equal(#state.items(), 0, 'a closed choice exposes no rows')
  expect.equal(state.visual().value, 'Row 2')
  state.click(15, 23, { button = 'right' })
  expect.equal(state.visual().opened, false, 'secondary input does not open')
  state.click(15, 23)
  expect.equal(state.visual().opened, true)
  expect.equal(state.focuses, 0, 'opening takes no focus')
end)

test('every choice option is reachable by scrolling and selecting closes the choice', function()
  local state = fixture('choice', 77, rows(20))
  state.click(15, 23)
  state.event('scroll', 15, 50, { dx = 100, dy = 10000 })
  local items = state.items()
  local last = items[#items]
  expect.equal(last.id, '20')
  state.click(last.bounds.x + 1, last.bounds.y + 1)
  expect.equal(state.changes[1], '20')
  expect.equal(state.visual().opened, false)
  expect.equal(state.visual().value, 'Row 20')
end)

test('a list row activates only on a primary press and release inside the same enabled row', function()
  local items = rows(4)
  items[3].enabled = false
  local state = fixture('list', 54, items)
  state.event('press', 15, 23)
  state.event('release', 15, 46)
  state.click(15, 23, { button = 'right' })
  state.click(15, 43)
  state.click(15, 69)
  expect.equal(#state.changes, 0, 'drags, secondary input, gaps, and disabled rows never select')
  state.event('press', 15, 23)
  state.event('cancel', nil, nil, { reason = 'disabled' })
  state.event('release', 15, 23)
  expect.equal(#state.changes, 0, 'a cancelled press never selects')
  state.click(15, 46)
  expect.equal(state.changes[1], '2')
end)

test('list rows clip at the viewport and stay disjoint while scrolling', function()
  local state = fixture('list', 54, rows(6))
  state.event('scroll', 15, 30, { dy = 5.5 })
  local items = state.items()
  expect.equal(items[1].bounds.height, 14.5, 'a partial row is clipped')
  expect.equal(state.visual().overflow, true)
  for count = 0, 12 do
    local list = fixture('list', 54, rows(count))
    for _, delta in { 0, 0.25, 7.75, 16, 90, -30, -1000 } do
      list.event('scroll', 15, 30, { dy = delta })
      local bottom = 22
      for _, item in list.items() do
        expect.truthy(item.bounds.y >= bottom and item.bounds.height > 0)
        expect.truthy(item.bounds.y + item.bounds.height <= 72)
        bottom = item.bounds.y + item.bounds.height
      end
    end
  end
end)

-- Reads the selection from the rows a list exposes.
local function selected(state: State): string?
  for _, item in state.items() do
    if item.selected then
      return item.id
    end
  end
  return nil
end

test('replacing list items keeps a surviving selection and clears a removed one', function()
  local state = fixture('list', 54, rows(8), '2')
  state.methods.setItems({}, { { id = '2', label = 'Retained' } })
  expect.equal(selected(state), '2')
  state.methods.setItems({}, rows(1))
  expect.equal(selected(state), nil)
  expect.equal(#state.changes, 0, 'programmatic changes do not echo onChange')
end)

return test
