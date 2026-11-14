-- Covers the standard angle kinds: the dial track and the Angle control.

local testing = require '@testing'
local fixture = require '@testing/ui-host'
local expect = testing.expect
local test = testing.suite()

local function boot(): fixture.State
  return fixture.boot { standard = true, width = 0.4, height = 0.4 }
end

-- Sweeps the dial from one angle to another in degrees, pressing at the first and releasing at the last.
local function sweep(state: fixture.State, track: any, from: number, to: number): ()
  local bounds = track:panelBounds()
  local cx, cy = bounds.x + bounds.width / 2, bounds.y + bounds.height / 2
  local radius = math.min(bounds.width, bounds.height) * 0.35
  local function at(degrees: number): (number, number)
    local angle = math.rad(degrees - 90)
    return cx + radius * math.sin(angle), cy - radius * math.cos(angle)
  end
  local runner = state.fixture
  local geometry = fixture.geometry(state)
  runner:button('right', 'trigger', false)
  runner:aim(geometry, at(from))
  runner:step()
  runner:button('right', 'trigger', true)
  runner:step()
  for step = 1, 4 do
    runner:aim(geometry, at(from + (to - from) * step / 4))
    runner:step()
  end
  runner:button('right', 'trigger', false)
  runner:step()
end

-- Presses the centre sign button of a dial and releases it.
local function pressCentre(state: fixture.State, track: any): ()
  local bounds = track:panelBounds()
  local runner = state.fixture
  local geometry = fixture.geometry(state)
  runner:button('right', 'trigger', false)
  runner:aim(geometry, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
  runner:step()
  runner:button('right', 'trigger', true)
  runner:step()
  runner:button('right', 'trigger', false)
  runner:step()
end

test('an angle shows its label, readout, and unit on a dial', function()
  local state = boot()
  local c = assert(state.components)
  fixture.show(
    state,
    c.Panel { c.Body { key = 'body', c.Angle { key = 'yaw', label = 'Yaw', value = 45, unit = '°' } } }
  )
  expect.truthy(state.panel:find 'body/yaw/track', 'the dial')
  expect.equal(assert(state.panel:find 'body/yaw/heading/value').props.text, '45.0', 'the readout')
  expect.equal(assert(state.panel:find 'body/yaw/heading/unit').props.text, '°', 'the unit')
  expect.equal(state.service:findByRole('slider', 'Yaw'), state.panel:find 'body/yaw', 'the accessible role')
  state.fixture:close()
end)

test('a dial drag previews and its release snaps to the nearest angle', function()
  local state = boot()
  local c = assert(state.components)
  local changes: { number } = {}
  local commits: { number } = {}
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Angle {
          key = 'yaw',
          label = 'Yaw',
          value = 0,
          min = 0,
          max = 180,
          snap = 22.5,
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
  local track = assert(state.panel:find 'body/yaw/track')
  sweep(state, track, 0, 50)
  expect.truthy(#changes > 1, 'the drag previews')
  expect.equal(commits[#commits], 45, 'the release snaps to 45 degrees')
  state.fixture:step()
  expect.equal(assert(state.panel:find 'body/yaw/heading/value').props.text, '45.0', 'the released value is shown')
  state.fixture:close()
end)

test('the centre button negates the angle, and a free dial keeps its angle', function()
  local state = boot()
  local c = assert(state.components)
  local commits: { number } = {}
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Angle {
          key = 'yaw',
          label = 'Yaw',
          value = 0,
          min = 0,
          max = 180,
          snap = 22.5,
          negatable = true,
          onCommit = function(value: number)
            table.insert(commits, value)
          end,
        },
        c.Angle {
          key = 'free',
          label = 'Free',
          value = 0,
          min = 0,
          max = 180,
          negatable = true,
          onCommit = function(value: number)
            table.insert(commits, value)
          end,
        },
      },
    }
  )
  local yaw = assert(state.panel:find 'body/yaw/track')
  sweep(state, yaw, 0, 50)
  expect.equal(commits[1], 45, 'the drag snaps to 45 degrees')
  pressCentre(state, yaw)
  expect.equal(commits[2], -45, 'the centre button flips the sign')
  local free = assert(state.panel:find 'body/free/track')
  sweep(state, free, 0, 50)
  expect.near(commits[3], 50, 1e-3, 'without a snap the dial reports the magnitude it was given')
  pressCentre(state, free)
  expect.near(commits[4], -50, 1e-3, 'the free dial flips its sign too')
  state.fixture:close()
end)

test('a drag across the dial hub keeps the dragged value', function()
  local state = boot()
  local c = assert(state.components)
  local values: { number } = {}
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Angle {
          key = 'yaw',
          label = 'Yaw',
          value = 0,
          min = 0,
          max = 180,
          snap = 22.5,
          onChange = function(value: number)
            table.insert(values, value)
          end,
        },
      },
    }
  )
  local track = assert(state.panel:find 'body/yaw/track')
  local bounds = track:panelBounds()
  local cx, cy = bounds.x + bounds.width / 2, bounds.y + bounds.height / 2
  local radius = math.min(bounds.width, bounds.height) * 0.35
  local angle = math.rad(45 - 90)
  local geometry = fixture.geometry(state)
  local runner = state.fixture
  runner:button('right', 'trigger', false)
  runner:aim(geometry, cx + radius * math.sin(angle), cy - radius * math.cos(angle))
  runner:step()
  runner:button('right', 'trigger', true)
  runner:step()
  local dragged = values[#values]
  expect.near(dragged, 45, 0.1, 'the drag value')
  runner:aim(geometry, cx, cy)
  runner:step()
  expect.near(values[#values], dragged, 1e-9, 'crossing the hub keeps the dragged value')
  runner:button('right', 'trigger', false)
  runner:step()
  state.fixture:close()
end)

test('an angle steps by its snap angle from the keyboard', function()
  local state = boot()
  local c = assert(state.components)
  local value = 0
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Angle {
          key = 'yaw',
          label = 'Yaw',
          value = value,
          min = 0,
          max = 180,
          snap = 22.5,
          onCommit = function(next: number)
            value = next
          end,
        },
      },
    }
  )
  local host = state.service
  expect.truthy(host:nextPanel(), 'the dial takes focus')
  state.fixture:step()
  expect.truthy(host:activate(), 'activation engages the dial')
  expect.truthy(host:navigate 'right', 'the engaged dial takes the direction')
  expect.equal(value, 22.5, 'one snap angle towards the positive turn')
  state.fixture:step()
  expect.truthy(host:navigate 'left')
  expect.equal(value, 0, 'and back')
  state.fixture:close()
end)

test('a disabled angle takes no pointer input', function()
  local state = boot()
  local c = assert(state.components)
  local commits = 0
  fixture.show(
    state,
    c.Panel {
      c.Body {
        key = 'body',
        c.Angle {
          key = 'yaw',
          label = 'Yaw',
          value = 0,
          snap = 22.5,
          disabledReason = 'The mount fixes the tilt.',
          onCommit = function(): ()
            commits += 1
          end,
        },
      },
    }
  )
  local track = assert(state.panel:find 'body/yaw/track')
  expect.truthy(track.props.disabled, 'the dial is disabled')
  expect.equal(track.props.disabledReason, 'The mount fixes the tilt.', 'the dial states why')
  sweep(state, track, 0, 90)
  expect.equal(commits, 0, 'a disabled dial commits nothing')
  state.fixture:close()
end)

test('a dial pulses as a drag reaches each snap angle', function()
  local state = boot()
  local c = assert(state.components)
  fixture.show(
    state,
    c.Panel {
      c.Body { key = 'body', c.Angle { key = 'yaw', label = 'Yaw', value = 0, snap = 22.5 } },
    }
  )
  local events = state.fixture.native.events
  local before = events.haptics or 0
  sweep(state, assert(state.panel:find 'body/yaw/track'), 0, 90)
  expect.truthy((events.haptics or 0) - before >= 4, 'a pulse at each snap angle')
  state.fixture:close()
end)

return test
