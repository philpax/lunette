local testing = require '@testing'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local function boot(): fixture.State
  return fixture.boot { standard = true, width = 0.4, height = 0.3 }
end

-- Presses the trigger at one point of a node and moves the aim by `dx` metres to the right, then releases.
local function drag(state: fixture.State, path: string, from: { number }, dx: number): ()
  local node = assert(state.panel:find(path), `no node at {path}`)
  local bounds = node:panelBounds()
  local geometry = fixture.geometry(state)
  local x, y = bounds.x + bounds.width * from[1], bounds.y + bounds.height * from[2]
  local runner = state.fixture
  runner:button('right', 'trigger', false)
  runner:aim(geometry, x, y)
  runner:step()
  runner:button('right', 'trigger', true)
  runner:step()
  for step = 1, 4 do
    runner:aim(geometry, x + dx * step / 4, y)
    runner:step()
  end
  runner:button('right', 'trigger', false)
  runner:step()
end

local function x(state: fixture.State): number
  local px = state.panel:pose():getPosition()
  return px
end

test('a titled panel shows the standard header with its detail, actions, and close button', function()
  local state = boot()
  local c = assert(state.components)
  local closed = 0
  fixture.show(
    state,
    c.Panel {
      title = 'Settings',
      detail = 'plugin/settings',
      onClose = function()
        closed += 1
      end,
      c.HeaderActions { c.Button { key = 'reset', label = 'Reset', variant = 'band' } },
      c.Body { key = 'body', c.Text { key = 'text', text = 'Content' } },
    }
  )
  expect.equal(assert(state.panel:find 'header/band/title').props.text, 'Settings', 'the band shows the title')
  expect.equal(assert(state.panel:find 'header/band/detail').props.text, 'plugin/settings', 'and the detail')
  expect.truthy(state.panel:find 'header/band/reset', 'the actions sit in the band')
  expect.truthy(state.panel:find 'body/text', 'the other children are the content')
  local reset = assert(state.panel:find 'header/band/reset'):panelBounds()
  local close = assert(state.panel:find 'header/band/close'):panelBounds()
  expect.truthy(close.x > reset.x, 'the close button comes after the actions')
  fixture.click(state, 'header/band/close')
  expect.equal(closed, 1, 'the close button calls onClose')
  state.fixture:close()
end)

test('a trigger drag on the empty part of the header moves the panel, and one on its buttons does not', function()
  local state = boot()
  local c = assert(state.components)
  local closed = 0
  fixture.show(
    state,
    c.Panel {
      title = 'Movable',
      onClose = function()
        closed += 1
      end,
      c.Body { key = 'body', c.Text { key = 'text', text = 'Content' } },
    }
  )
  local start = x(state)
  -- The spacer is the band's empty space between the title and the close button.
  drag(state, 'header/band/spacer', { 0.5, 0.5 }, 0.1)
  expect.near(x(state) - start, 0.1, 0.01, 'the panel follows the ray')
  local moved = x(state)
  drag(state, 'header/band/close', { 0.5, 0.5 }, 0)
  expect.equal(closed, 1, 'the close button still takes the press')
  expect.near(x(state), moved, 1e-6, 'pressing the close button does not move the panel')
  drag(state, 'body/text', { 0.5, 0.5 }, 0.1)
  expect.near(x(state), moved, 1e-6, 'a trigger drag on the content does not move the panel')
  state.fixture:close()
end)

test('a panel without a title has no header, and its content does not move it', function()
  local state = boot()
  local c = assert(state.components)
  fixture.show(state, c.Panel { c.Body { key = 'body', c.Text { key = 'text', text = 'Content' } } })
  expect.equal(state.panel:find 'header', nil, 'no header is shown')
  local start = x(state)
  drag(state, 'body', { 0.5, 0.5 }, 0.1)
  expect.near(x(state), start, 1e-6, 'the panel stays put')
  state.fixture:close()
end)

return test
