-- Covers examples/keyboard: its configuration starts, draws, and quits, and the split keyboard it patches in
-- is shown by the wrist button with its halves apart.
local testing = require '@testing'
local expect = testing.expect
local desktop = require '@lunette-desktop'
local surfacesContract = require '@lunette-contracts/surfaces'

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

  -- The split keyboard as the example patches it in, in a desktop whose surfaces the case observes.
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
  wrist:onPress(nil, nil, {
    vibrate = function()
      return true
    end,
  })
  local board
  for _, candidate in ipairs(surfaces:all()) do
    if candidate.pressKey then
      board = candidate
    end
  end
  expect.truthy(board and board.visible, 'the wrist button shows the keyboard')
  local unit = 0.03
  -- The number row is ten keys, a wider backspace, and the split.
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
