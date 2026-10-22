local testing = require '@testing'
local fixture = require '@testing/ui-host'
local menu = require '@lunette-contracts/menu'
local expect = testing.expect
local test = testing.suite()

local function boot(config: { [string]: unknown }?): (any, any, any)
  local state = fixture.boot {
    standard = true,
    plugins = { require('@lunette-plugins/menu/action-registry').definition },
  }
  local session = assert(state.fixture.session)
  local instance = session:use(require('../init').definition, config or {})
  local menus = assert(session:observe(menu.capability).service)
  return state, instance, menus
end

local TIMING = {
  interval = 0.011,
  work = 0.006,
  prediction = 0.03,
  skipped = 1,
  compositor = {
    frame = 1,
    gpu = 0.002,
    cpu = 0.001,
    presents = 1,
    mispresented = 0,
    dropped = 0,
    reprojecting = false,
  },
}

test('the plugin applies fixed foveation at start and restores the headset when it ends', function()
  local state, instance = boot()
  local events = state.fixture.native.events
  expect.equal(events.foveation.level, 'low', 'the default level')
  expect.equal(events.foveation.dynamic, false, 'the level is fixed')
  expect.equal(events.foveation.overlay, false)
  instance:disable()
  expect.equal(events.foveation.level, 'none', 'the previous level returns')
  state.fixture:close()
end)

test('an unsupported headset leaves the plugin running', function()
  local state =
    fixture.boot { standard = true, plugins = { require('@lunette-plugins/menu/action-registry').definition } }
  state.fixture.native.events.foveationSupported = false
  local instance =
    assert(state.fixture.session):use(require('../init').definition, { foveation = 'high', overlay = true })
  expect.equal(instance:state(), 'active')
  expect.equal(state.fixture.native.events.foveation.level, 'none', 'the refused level changes nothing')
  state.fixture:close()
end)

test('timing runs only while the panel is open, and the header closes it', function()
  local state, _, menus = boot()
  local events = state.fixture.native.events
  state.fixture:step()
  expect.equal(state.service:find 'Performance:body', nil, 'the panel starts closed')
  expect.equal(events.timingEnabled, false)
  expect.equal(menus:invoke('dev/perf/open').kind, 'invoked')
  state.fixture:step()
  state.fixture:step()
  expect.truthy(state.service:find 'Performance:body', 'the action opens the panel')
  expect.equal(events.timingEnabled, true, 'GPU timing is enabled while the panel is open')
  events.frameTiming = TIMING
  events.passTiming = {}
  -- Twenty frames of 16 ms pass one refresh.
  for _ = 1, 20 do
    state.fixture:step()
  end
  local counts =
    assert(state.service:find 'Performance:body/scroll/content/count-1', 'the panel shows the window counts')
  expect.truthy(string.find(counts.props.text, 'Skipped refreshes: ', 1, true), 'a refresh replaces the empty readout')
  expect.truthy(state.service:find 'Performance:body/scroll/content/times/interval', 'the frame interval has a row')
  local close = assert(state.service:find 'Performance:header/band/close', 'the open panel has a close button')
  state.fixture:click(fixture.nodeGeometry(close), 0.5, 0.5)
  state.fixture:step()
  expect.equal(state.service:find 'Performance:body', nil, 'the close button closes the panel')
  expect.equal(events.timingEnabled, false, 'closing restores the previous timing state')
  state.fixture:close()
end)

test('closing the panel keeps timing that was enabled before it opened', function()
  local state, _, menus = boot()
  local events = state.fixture.native.events
  events.timingEnabled = true
  menus:invoke 'dev/perf/open'
  state.fixture:step()
  menus:invoke 'dev/perf/open'
  state.fixture:step()
  expect.equal(events.timingEnabled, true)
  state.fixture:close()
end)

return test
