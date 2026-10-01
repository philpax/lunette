-- The first-plugin example in examples/first-plugin: its main.lua inserts a
-- plugin that draws, a provider, and a consumer of that provider with an
-- option, and each runs in the shipped desktop.
require 'main'
lovr.load()
events.time = 3
events.draw = {}
lovr.update(0.016)
assert(lovr.draw(events.pass) == false)
local hello, uptime = false, false
for _, call in ipairs(events.draw) do
  if call[1] == 'text' then
    hello = hello or call[2] == 'hello from a plugin'
    uptime = uptime or call[2] == 'running for 3s, 0 windows'
  end
end
assert(hello, 'the first plugin draws')
assert(uptime, 'the consumer reads the provider and its option')
assert(lovr.quit() == false)
