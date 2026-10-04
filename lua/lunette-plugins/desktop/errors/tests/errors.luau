local testing = require '@testing'
local expect = testing.expect
local errors = require '@lunette-contracts/errors'

local test = testing.suite()

test('the error overlay uses a vector position and keeps its background as a color list', function()
  local position = vector.pack(2, 3, -4)
  local background = { 0.2, 0.3, 0.4, 0.5 }
  local session = testing.boot {
    'frame',
    'errors',
    {
      id = 'desktop/errors',
      definition = require '@lunette-plugins/desktop/errors',
      config = { position = position, background = background },
    },
  }
  session.native.raise('fixture overlay error', 'fixture traceback')
  session:draw()
  local plane, color, text
  for _, call in ipairs(session.native.events.draw) do
    if call[1] == 'plane' then
      plane = call
    elseif call[1] == 'setColor' and call[2] == background[1] then
      color = call
    elseif call[1] == 'text' then
      text = call
    end
  end
  expect.truthy(plane and color and text, 'the overlay background and text')
  expect.near(plane[2], position.x, 1e-5, 'the plane x position')
  expect.near(plane[3], position.y, 1e-5, 'the plane y position')
  expect.near(plane[4], position.z, 1e-5, 'the plane z position')
  for index = 1, 4 do
    expect.equal(color[index + 1], background[index], 'background component ' .. index)
  end
  expect.near(text[5], position.z + 0.001, 1e-5, 'the text is in front of the background')
  expect.equal(position, vector.pack(2, 3, -4), 'the configured position is unchanged')
  expect.equal(type(background), 'table', 'the background remains a list')
  local stream = session:observe(errors.capability)
  stream.service:clear(stream.context)
  session.native.events.draw = {}
  session:draw()
  expect.equal(#session.native.events.draw, 0, 'a cleared stream has no overlay')
  session:close()
end)

return test
