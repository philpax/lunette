local testing = require '@testing'
local expect = testing.expect
local errors = require '@lunette-contracts/errors'

local test = testing.suite()

test('the error overlay draws at its configured position and a cleared stream draws nothing', function()
  local position = vector.pack(2, 3, -4)
  local session = testing.boot {
    'frame',
    'theme',
    'errors',
    { id = 'desktop/errors', definition = require '@lunette-plugins/desktop/errors', config = { position = position } },
  }
  session.native.raise('fixture overlay error', 'fixture traceback')
  session:draw()
  local plane, text
  for _, call in ipairs(session.native.events.draw) do
    if call[1] == 'plane' then
      plane = call
    elseif call[1] == 'text' then
      text = call
    end
  end
  expect.truthy(plane and text, 'the overlay background and text')
  expect.near(plane[2], position.x, 1e-5, 'the plane x position')
  expect.near(plane[3], position.y, 1e-5, 'the plane y position')
  expect.near(plane[4], position.z, 1e-5, 'the plane z position')
  local stream = session:observe(errors.capability)
  stream.service:clear(stream.context)
  session.native.events.draw = {}
  session:draw()
  expect.equal(#session.native.events.draw, 0, 'a cleared stream has no overlay')
  session:close()
end)

return test
