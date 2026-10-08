local testing = require '@testing'
local controller = require '@lunette-plugins/desktop/manager/controller'
local boot = require './support/boot'
local expect = testing.expect
local test = testing.suite()

test('visible manager refreshes on a bounded interval and opening refreshes immediately', function()
  local update, calls = controller.update, 0
  controller.update = function(state)
    calls += 1
    update(state)
  end
  local running
  local ok, message = pcall(function()
    local fake, public
    running, fake, _, _, _, public = boot { visible = true }
    local initial = calls
    for _ = 1, 120 do
      lovr.update(1 / 120)
    end
    expect.truthy(calls - initial <= 5, 'one second does not rebuild a snapshot on all 120 frames')
    expect.truthy(calls > initial, 'visible state is refreshed periodically')
    public:click(public:pointer(), 'close')
    local hidden = calls
    for _ = 1, 120 do
      lovr.update(1 / 120)
    end
    expect.equal(calls, hidden, 'hidden manager has no snapshot polling')
    public:open()
    expect.truthy(calls > hidden, 'opening refreshes immediately')
    lovr.draw(fake.events.pass)
    expect.truthy(#fake.events.draw > 0, 'drawing does not depend on rebuilding the UI each frame')
  end)
  controller.update = update
  if running then
    running.runtime:close()
  end
  if not ok then
    error(message, 0)
  end
end)

return test
