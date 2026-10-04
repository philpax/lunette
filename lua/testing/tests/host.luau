local testing = require '@testing'
local expect = testing.expect

local test = testing.suite()

test('the shipped configuration starts, reloads through the production path, and quits', function()
  local native = testing.native()
  testing.host.useConfiguration 'etc/xdg/lunette'
  require 'main'
  lovr.load()
  expect.equal(#native.events.spawned, 0, 'the shipped configuration opens no application')
  for reload = 1, 2 do
    local ok, failure = require('@lunette').reload()
    expect.truthy(ok, 'reload ' .. reload .. ': ' .. tostring(failure))
    expect.equal(type(lovr.update), 'function', 'the callbacks bound again by reload ' .. reload)
  end
  expect.equal(#native.events.spawned, 0, 'reload opens no application')
  expect.equal(lovr.quit(), false, 'quit does not veto')
  expect.equal(#testing.host.shutdown(), 0, 'the failures of the shutdown')
  native.assertResourcesReleased()
end)

test('a configuration that is not a directory of the repository is refused', function()
  expect.raises(function()
    testing.host.useConfiguration 'no/such/configuration'
  end, 'is not a directory', 'the missing configuration')
end)

return test
