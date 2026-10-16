local testing = require '@testing'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local function boot(): fixture.State
  return fixture.boot { standard = true, width = 0.4, height = 0.4 }
end

-- Presses at one point of a node, drags to another, and releases, as fractions of the node's box.
local function drag(state: fixture.State, path: string, from: { number }, to: { number }): ()
  local node = assert(state.panel:find(path), `no node at {path}`)
  local bounds = node:panelBounds()
  local geometry = fixture.geometry(state)
  local function at(point: { number }): (number, number)
    return bounds.x + bounds.width * point[1], bounds.y + bounds.height * point[2]
  end
  local runner = state.fixture
  runner:button('right', 'trigger', false)
  runner:aim(geometry, at(from))
  runner:step()
  runner:button('right', 'trigger', true)
  runner:step()
  for step = 1, 4 do
    local t = step / 4
    runner:aim(geometry, at { from[1] + (to[1] - from[1]) * t, from[2] + (to[2] - from[2]) * t })
    runner:step()
  end
  runner:button('right', 'trigger', false)
  runner:step()
end

test('a toggle reports the flipped value', function()
  local state = boot()
  local c = assert(state.components)
  local reported = {}
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Toggle {
          key = 'backdrop',
          label = 'Backdrop',
          value = false,
          onChange = function(value: boolean)
            table.insert(reported, value)
          end,
        },
      },
    }
  )
  fixture.click(state, 'body/backdrop')
  expect.equal(#reported, 1)
  expect.equal(reported[1], true)
  state.fixture:close()
end)

test('a disabled button does not activate and shows its reason on hover', function()
  local state = boot()
  local c = assert(state.components)
  local activations = 0
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Button {
          key = 'pin',
          label = 'Pin',
          disabledReason = 'Pinning needs the Attention source.',
          onActivate = function()
            activations += 1
          end,
        },
      },
    }
  )
  fixture.click(state, 'body/pin')
  state.fixture:step()
  expect.equal(activations, 0)
  expect.truthy(state.panel:find 'body/pin/reason', 'the reason is shown while hovered')
  state.fixture:close()
end)

test('a slider drag reports values and snaps the release to a detent', function()
  local state = boot()
  local c = assert(state.components)
  local changes, commits = {}, {}
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Slider {
          key = 'response',
          label = 'Response',
          value = 0,
          detents = { { value = 0, label = 'None' }, { value = 0.5, label = 'Medium' }, { value = 1, label = 'Full' } },
          onChange = function(value: number)
            table.insert(changes, value)
          end,
          onCommit = function(value: number)
            table.insert(commits, value)
          end,
        },
      },
    }
  )
  drag(state, 'body/response/track', { 0.05, 0.5 }, { 0.51, 0.5 })
  expect.truthy(#changes > 2, 'each drag step reports a value')
  expect.equal(#commits, 1)
  expect.equal(commits[1], 0.5, 'the release snaps to the Medium detent')
  state.fixture:step()
  local value = assert(state.panel:find 'body/response/heading/value')
  expect.equal(value.props.text, '0.50', 'the released value is shown before the prop changes')
  state.fixture:close()
end)

test('a dropdown opens and reports the chosen option', function()
  local state = boot()
  local c = assert(state.components)
  local chosen = nil
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Dropdown {
          key = 'layout',
          value = 'arc',
          options = { { id = 'arc', label = 'Arc' }, { id = 'grid', label = 'Grid' } },
          onChange = function(id: string)
            chosen = id
          end,
        },
      },
    }
  )
  expect.equal(state.panel:find 'body/layout/menu', nil, 'the menu starts closed')
  fixture.click(state, 'body/layout/trigger')
  state.fixture:step()
  expect.truthy(state.panel:find 'body/layout/menu', 'the trigger opens the menu')
  fixture.click(state, 'body/layout/menu/grid')
  state.fixture:step()
  expect.equal(chosen, 'grid')
  expect.equal(state.panel:find 'body/layout/menu', nil, 'choosing closes the menu')
  state.fixture:close()
end)

test('list rows report their ids, including ids with separators', function()
  local state = boot()
  local c = assert(state.components)
  local chosen = nil
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.List {
          key = 'plugins',
          items = { { id = 'desktop/backdrop', title = 'Backdrop' }, { id = 'desktop/keyboard', title = 'Keyboard' } },
          onChange = function(id: string)
            chosen = id
          end,
        },
      },
    }
  )
  fixture.click(state, 'body/plugins/desktop%2Fkeyboard')
  expect.equal(chosen, 'desktop/keyboard')
  state.fixture:close()
end)

test('a scroll box scrolls its content by dragging', function()
  local state = boot()
  local c = assert(state.components)
  local rows = {}
  for index = 1, 20 do
    rows[index] = c.Text { key = `row-{index}`, text = `Row {index}` }
  end
  fixture.show(
    state,
    c.Panel { c.Body { key = 'body', c.ScrollBox { key = 'box', height = 0.1, c.Column { key = 'rows', rows } } } }
  )
  local first = assert(state.panel:find 'body/box/rows/row-1')
  local before = first:panelBounds().y
  drag(state, 'body/box', { 0.5, 0.8 }, { 0.5, 0.2 })
  state.fixture:step()
  local after = first:panelBounds().y
  expect.truthy(after < before - 0.03, `the content moved up: {before} to {after}`)
  state.fixture:close()
end)

test('a cancelled slider drag returns to the value prop', function()
  local state = boot()
  local c = assert(state.components)
  local changes: { number } = {}
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Slider {
          key = 'level',
          label = 'Level',
          value = 0.2,
          onChange = function(value: number)
            table.insert(changes, value)
          end,
        },
      },
    }
  )
  local track = assert(state.panel:find 'body/level/track'):panelBounds()
  local surface = fixture.surface(state)
  local pointer = fixture.pointer()
  local y = track.y + track.height / 2
  local function deliver(kind: string, x: number?): ()
    surface:onPointer {
      kind = kind,
      pointer = pointer,
      x = x,
      y = if x then y else nil,
      button = 'left',
      captured = false,
      inside = true,
      reason = 'tracking-loss',
    }
  end
  deliver('enter', track.x + track.width * 0.2)
  deliver('press', track.x + track.width * 0.2)
  deliver('move', track.x + track.width * 0.8)
  state.fixture:step()
  local previewed = tonumber(assert(state.panel:find 'body/level/heading/value').props.text) :: number
  expect.truthy(previewed > 0.7, `the drag previews a higher value: {previewed}`)
  deliver 'cancel'
  state.fixture:step()
  expect.equal(assert(state.panel:find 'body/level/heading/value').props.text, '0.20', 'the cancel returns')
  expect.equal(changes[#changes], 0.2, 'the consumer hears the return')
  state.fixture:close()
end)

test('a scroll box scrolled past content that shrank shows the content from its top', function()
  local state = boot()
  local c = assert(state.components)
  local function show(count: number): ()
    local rows = {}
    for index = 1, count do
      rows[index] = c.Text { key = `row-{index}`, text = `Row {index}` }
    end
    fixture.show(
      state,
      c.Panel { c.Body { key = 'body', c.ScrollBox { key = 'box', height = 0.1, c.Column { key = 'rows', rows } } } }
    )
  end
  show(30)
  local box = assert(state.panel:find 'body/box')
  box:setState { scrollY = 10 }
  state.fixture:step()
  show(3)
  state.fixture:step()
  local first = assert(state.panel:find 'body/box/rows/row-1'):panelBounds()
  expect.near(first.y, box:panelBounds().y, 1e-6, 'the first row is at the top of the box')
  state.fixture:close()
end)

return test
