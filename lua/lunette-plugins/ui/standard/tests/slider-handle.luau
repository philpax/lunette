local testing = require '@testing'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

-- Presses a node at one fraction of its width and drags to others in turn, reporting the pulses after each stop.
local function sweep(state: fixture.State, path: string, stops: { number }): { number }
  local node = assert(state.panel:find(path), `no node at {path}`)
  local bounds = node:panelBounds()
  local geometry = fixture.geometry(state)
  local events = state.fixture.native.events
  local function at(t: number): (number, number)
    return bounds.x + bounds.width * t, bounds.y + bounds.height / 2
  end
  local runner = state.fixture
  runner:aim(geometry, at(stops[1]))
  runner:step()
  runner:button('right', 'trigger', true)
  runner:step()
  local counts: { number } = { events.haptics or 0 }
  for index = 2, #stops do
    runner:aim(geometry, at(stops[index]))
    runner:step()
    counts[#counts + 1] = events.haptics or 0
  end
  runner:button('right', 'trigger', false)
  runner:step()
  return counts
end

test('a slider drag pulses the holding pointer once at each detent it reaches', function()
  local state = fixture.boot { standard = true, width = 0.4, height = 0.2 }
  local c = assert(state.components)
  local detents = { { value = 0, label = 'Off' }, { value = 0.5, label = 'Half' }, { value = 1, label = 'Full' } }
  fixture.show(
    state,
    c.Panel { c.Body { key = 'body', c.Slider { key = 'level', label = 'Level', value = 0.1, detents = detents } } }
  )
  local counts = sweep(state, 'body/level/track', { 0.15, 0.3, 0.45, 0.5, 0.55, 0.7 })
  expect.equal(counts[2] - counts[1], 0, 'moving between detents does not pulse')
  expect.equal(counts[4] - counts[2], 1, 'reaching the middle detent pulses once')
  expect.equal(counts[6] - counts[4], 0, 'leaving it does not pulse again')
  state.fixture:close()
end)

test('a stepped slider pulses at each step, and haptics off silences it', function()
  local state = fixture.boot { standard = true, width = 0.4, height = 0.2 }
  local c = assert(state.components)
  fixture.show(
    state,
    c.Panel {
      c.Body { key = 'body', c.Slider { key = 'count', label = 'Count', value = 0, min = 0, max = 4, step = 1 } },
    }
  )
  local counts = sweep(state, 'body/count/track', { 0.05, 0.3, 0.55, 0.8 })
  expect.equal(counts[4] - counts[1], 3, 'three steps, three pulses')
  state.service:setAccessibility { haptics = false }
  counts = sweep(state, 'body/count/track', { 0.8, 0.55, 0.3 })
  expect.equal(counts[3] - counts[1], 0, 'no pulses with haptics off')
  state.fixture:close()
end)

test('the slider handle grows while the slider is hovered and dragged', function()
  local state = fixture.boot { standard = true, width = 0.4, height = 0.2 }
  local c = assert(state.components)
  -- The handle is the box drawn with a border; an override records the base visual's boxes.
  local handleWidth: number? = nil
  state.service:registerVisual(state.owner, 'lunette/slider-track', function(node: any, draw: any, base: any)
    local proxy = setmetatable({
      box = function(_self: any, rect: any, style: any): any
        if style and style.border then
          handleWidth = rect.width
        end
        return draw:box(rect, style)
      end,
    }, { __index = draw })
    base(node, proxy)
  end)
  fixture.show(state, c.Panel { c.Body { key = 'body', c.Slider { key = 'level', label = 'Level', value = 0.5 } } })
  -- Visuals run when a frame draws.
  state.fixture:draw()
  local resting = assert(handleWidth, 'the handle draws')
  local track = assert(state.panel:find 'body/level/track')
  local bounds = track:panelBounds()
  state.fixture:aim(fixture.geometry(state), bounds.x + bounds.width * 0.2, bounds.y + bounds.height / 2)
  state.fixture:step()
  state.fixture:step()
  state.fixture:draw()
  expect.truthy(assert(handleWidth) > resting, 'the hovered handle is larger')
  state.fixture:aim(fixture.geometry(state), bounds.x + bounds.width * 0.2, bounds.y + bounds.height * 4)
  state.fixture:step()
  state.fixture:step()
  state.fixture:draw()
  expect.near(assert(handleWidth), resting, 1e-9, 'and returns to its size when the ray leaves')
  state.fixture:close()
end)

return test
