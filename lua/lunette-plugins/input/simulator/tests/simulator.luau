local testing = require '@testing'
local vrUi = require '@testing/vr-ui'
local simulator = require '@lunette-plugins/input/simulator'
local expect = testing.expect

local test = testing.suite()

local function boot(config: simulator.Config?): vrUi.Fixture
  local fixture = vrUi.boot { 'frame' }
  fixture.native.events.headsetActive = false
  assert(fixture.session):use(simulator.definition, config or { smoothing = 0 })
  return fixture
end

local function forward(fixture: vrUi.Fixture): vector
  return vector.pack(fixture.native.events.headPose:mul(0, 0, -1, 0))
end

local function position(fixture: vrUi.Fixture): vector
  return vector.pack(fixture.native.events.headPose:getPosition())
end

test('a secondary drag turns the head by the sensitivity and holds the mouse while it lasts', function()
  local fixture = boot { smoothing = 0, lookSensitivity = 0.001 }
  local events = fixture.native.events
  lovr.simulate(0.016)
  lovr.mousemoved(10, 10, 300, 0)
  lovr.simulate(0.016)
  expect.near(forward(fixture).x, 0, 1e-6, 'a move without the button does not turn')
  lovr.mousepressed(10, 10, 2)
  expect.equal(events.window.mouseMode, 'relative', 'the drag holds the mouse')
  lovr.mousemoved(10, 10, 300, 0)
  lovr.simulate(0.016)
  local turned = forward(fixture)
  expect.near(math.atan2(turned.x, -turned.z), 0.3, 1e-5, 'a drag right turns right by the sensitivity')
  lovr.mousereleased(10, 10, 2)
  expect.equal(events.window.mouseMode, 'normal', 'the release gives the mouse back')
  lovr.mousepressed(10, 10, 1)
  lovr.mousemoved(10, 10, 300, 0)
  lovr.simulate(0.016)
  expect.near(math.atan2(forward(fixture).x, -forward(fixture).z), 0.3, 1e-5, 'a primary drag does not turn')
  assert(fixture.session):close()
end)

test('movement keys move the head only while the look button is held', function()
  local fixture = boot()
  local events = fixture.native.events
  lovr.simulate(0.016)
  local start = position(fixture)
  events.held.w = true
  lovr.simulate(0.5)
  expect.near(vector.magnitude(position(fixture) - start), 0, 1e-6, 'typing w does not move the head')
  lovr.mousepressed(10, 10, 2)
  lovr.simulate(0.5)
  expect.near(start.z - position(fixture).z, 1.5, 1e-5, 'w moves forward at the speed')
  events.held.w = nil
  lovr.mousereleased(10, 10, 2)
  assert(fixture.session):close()
end)

test('ending the plugin during a drag gives the mouse back', function()
  local fixture = boot()
  lovr.simulate(0.016)
  lovr.mousepressed(10, 10, 2)
  assert(fixture.session):close()
  expect.equal(fixture.native.events.window.mouseMode, 'normal', 'the mouse is given back')
end)

return test
