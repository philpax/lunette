local testing = require '@testing'
local expect = testing.expect
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

local HINT = 'lunette: no windows yet'

local function drawsHint(session)
  local events = session.native.events
  events.draw = {}
  session:draw()
  for _, call in ipairs(events.draw) do
    if call[1] == 'text' and call[2] == HINT then
      return true
    end
  end
  return false
end

test('the empty scene draws the hint and a scene with a panel does not', function()
  local session = testing.boot { 'frame', 'surfaces', 'panels', 'desktop/hint' }
  expect.truthy(drawsHint(session), 'the hint in the empty scene')
  local panels = session:observe(panelsContract.capability)
  panels.service:fromWindow(panels.context, session.native.newWindow(1), {})
  expect.falsy(drawsHint(session), 'the hint in a scene with a panel')
  session:close()
end)

test('the configured vector position reaches the hint draw pose unchanged', function()
  local position = vector.pack(2, 3, -4)
  local session = testing.boot {
    'frame',
    'surfaces',
    'panels',
    { id = 'desktop/hint', definition = require '@lunette-plugins/desktop/hint', config = { position = position } },
  }
  session:draw()
  local pose
  for _, call in ipairs(session.native.events.draw) do
    if call[1] == 'text' and call[2] == HINT then
      pose = call[3]
    end
  end
  expect.truthy(pose, 'the hint draw pose')
  local x, y, z = pose:getPosition()
  expect.near(x, position.x, 1e-5, 'the hint x position')
  expect.near(y, position.y, 1e-5, 'the hint y position')
  expect.near(z, position.z, 1e-5, 'the hint z position')
  expect.equal(position, vector.pack(2, 3, -4), 'the configured position is unchanged')
  session:close()
end)

return test
