local testing = require '@testing'
local expect = testing.expect

local test = testing.suite()

test('the first-plugin example runs its inserted plugins in the shipped desktop', function()
  local native = testing.native()
  local events = native.events
  testing.host.useConfiguration 'examples/first-plugin'
  require 'main'
  lovr.load()
  events.time = 3
  lovr.update(0.016)
  expect.equal(lovr.draw(events.pass), false, 'draw does not veto')
  local hello, uptime = false, false
  for _, call in ipairs(events.draw) do
    if call[1] == 'text' then
      hello = hello or call[2] == 'hello from a plugin'
      uptime = uptime or call[2] == 'running for 3s, 0 windows'
    end
  end
  expect.truthy(hello, 'the first plugin draws')
  expect.truthy(uptime, 'the consumer reads the provider and its option')
  expect.equal(lovr.quit(), false, 'quit does not veto')
end)

return test
