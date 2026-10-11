local testing = require '@testing'
local expect = testing.expect
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

local HINT = 'lunette: no windows yet'

local function drawsHint(session: testing.Session): testing.DrawCall?
  local events = session.native.events
  events.draw = {}
  session:draw()
  for _, call in ipairs(events.draw) do
    if call[1] == 'text' and call[2] == HINT then
      return call
    end
  end
  return nil
end

test('the empty scene draws the hint at its configured position and a scene with a panel does not', function()
  local position = vector.pack(2, 3, -4)
  local session = testing.boot {
    'frame',
    'theme',
    'surfaces',
    'panels',
    {
      id = 'desktop/hint',
      definition = require('@lunette-plugins/desktop/hint').definition,
      config = { position = position },
    },
  }
  local hint = drawsHint(session)
  expect.truthy(hint, 'the hint in the empty scene')
  local x, y, z = hint[3]:getPosition()
  expect.near(x, position.x, 1e-5, 'the hint x position')
  expect.near(y, position.y, 1e-5, 'the hint y position')
  expect.near(z, position.z, 1e-5, 'the hint z position')
  local panels = session:observe(panelsContract.capability)
  panels.service:fromWindow(panels.context, session.native.newWindow(1), {})
  expect.falsy(drawsHint(session), 'the hint in a scene with a panel')
  session:close()
end)

return test
