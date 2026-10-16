local testing = require '@testing'
local vrUi = require '@testing/vr-ui'
local simulator = require '@lunette-plugins/input/simulator'
local expect = testing.expect

local test = testing.suite()

local function boot(config: simulator.Config?): vrUi.Fixture
  local fixture = vrUi.boot { 'frame', 'focus' }
  fixture.native.events.headsetActive = false
  assert(fixture.session):use(simulator.definition, config or {})
  return fixture
end

local function heading(fixture: vrUi.Fixture): number
  local x, _, z = fixture.native.events.headPose:mul(0, 0, -1, 0)
  return math.atan2(x, -z)
end

local function position(fixture: vrUi.Fixture): vector
  return vector.pack(fixture.native.events.headPose:getPosition())
end

test('a secondary drag pulls the scene across the view, and other drags do not turn', function()
  local fixture = boot()
  local window = fixture.native.events.window
  lovr.simulate(0.016)
  lovr.mousemoved(400, 300, 300, 0)
  lovr.simulate(0.016)
  expect.near(heading(fixture), 0, 1e-6, 'a move without the button does not turn')
  lovr.mousepressed(400, 300, 2)
  lovr.mousemoved(800, 300, 400, 0)
  lovr.simulate(0.016)
  expect.near(heading(fixture), -0.8, 1e-5, 'a drag to the right edge turns left by the half-angle')
  expect.equal(window.mouseMode, 'normal', 'the cursor stays visible')
  lovr.mousereleased(800, 300, 2)
  lovr.mousepressed(400, 300, 1)
  lovr.mousemoved(800, 300, 400, 0)
  lovr.simulate(0.016)
  expect.near(heading(fixture), -0.8, 1e-5, 'a primary drag does not turn')
  assert(fixture.session):close()
end)

test('movement keys move the head while nothing has keyboard focus', function()
  local fixture = boot()
  local events = fixture.native.events
  lovr.simulate(0.016)
  local start = position(fixture)
  events.held.w = true
  lovr.simulate(0.5)
  expect.near(start.z - position(fixture).z, 1.5, 1e-5, 'w moves forward at the speed')
  events.held.w = nil
  assert(fixture.session):close()
end)

return test
