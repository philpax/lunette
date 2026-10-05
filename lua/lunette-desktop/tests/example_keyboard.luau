local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local surfacesContract = require '@lunette-contracts/surfaces'
local interactionContract = require '@lunette-contracts/interaction'

local test = testing.suite()

test('the keyboard example runs, and its split keyboard is shown with its halves apart', function()
  local native = testing.native()
  local events = native.events
  testing.host.useConfiguration 'examples/keyboard'
  require 'main'
  lovr.load()
  lovr.update(0.016)
  expect.equal(lovr.draw(events.pass), false, 'draw does not veto')
  expect.equal(lovr.quit(), false, 'quit does not veto')

  local session = testing.boot(
    desktop.compose {
      patches = {
        { id = 'keyboard', definition = require 'split' },
        { id = 'desktop/keyboard', config = { hand = 'right' } },
      },
    },
    { native = native }
  )
  local surfaces = session:observe(surfacesContract.capability).service
  local wrist
  for _, candidate in ipairs(surfaces:all()) do
    if candidate.grabbable == false and candidate.width == 0.115 then
      wrist = candidate
    end
  end
  assert(wrist, 'the wrist button')
  local observed = session:observe(interactionContract.capability)
  local pointer = observed.service:newPointer(observed.context)
  local frame = {
    origin = vector.pack(wrist.pose:mul(0, 0, 1, 1)),
    direction = vector.pack(wrist.pose:mul(0, 0, -1, 0)),
    buttons = { left = true },
    grip = false,
    dt = 0.016,
  }
  pointer:update(frame, surfaces:all())
  frame.buttons = {}
  pointer:update(frame, surfaces:all())
  local board
  for _, candidate in ipairs(surfaces:all()) do
    if candidate.pressKey then
      board = candidate
    end
  end
  expect.truthy(board and board.visible, 'the wrist button shows the keyboard')
  local unit = 0.03
  -- The split adds half a key unit between the five and six keys.
  expect.near(board.width, 13 * unit, 1e-9, 'the keyboard width')
  local five, six
  for _, key in ipairs(board:keys()) do
    if key.code == 6 then
      five = key
    elseif key.code == 7 then
      six = key
    end
  end
  expect.near(six.x, five.x + five.width + 1.5 * unit, 1e-9, 'the halves are split')
  session:close()
end)

return test
