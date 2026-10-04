local testing = require '@testing'
local expect = testing.expect

local test = testing.suite()

test('the desktop example runs, and control, alt, and H hide and show every window', function()
  local native = testing.native()
  local events = native.events
  testing.host.useConfiguration 'examples/desktop'
  require 'main'
  lovr.load()
  events.windows = { native.newWindow(1) }
  native.emit('onWindowOpened', { window = events.windows[1] })
  local function frame()
    events.draw, events.textures = {}, 0
    lovr.update(0.016)
    expect.equal(lovr.draw(events.pass), false, 'draw does not veto')
  end
  frame()
  expect.equal(events.textures, 1, 'the window draws')
  events.held.lctrl, events.held.lalt = true, true
  lovr.keypressed('h', 0, false)
  frame()
  expect.equal(events.textures, 0, 'the binding hides the window')
  lovr.keypressed('h', 0, false)
  frame()
  expect.equal(events.textures, 1, 'the binding shows the window again')
  events.held = {}
  expect.equal(lovr.quit(), false, 'quit does not veto')
end)

return test
