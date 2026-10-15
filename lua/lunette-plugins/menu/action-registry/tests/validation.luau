local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/fixture'
local test = testing.suite()

test('registration rejects a malformed action and acquires nothing', function()
  local env = fixture.start()
  expect.raises(function()
    env.service:register(env.owner, { id = 'x', label = 'X', unknown = true, run = function() end })
  end, 'menu register: unknown field unknown', 'an unknown field')
  expect.raises(function()
    env.service:register(env.owner, { id = 'x', label = 'X', run = true })
  end, 'run is a function', 'a mistyped field')
  expect.equal(#env.service:list(), 0, 'validation failures acquire no registrations')
  env.session:close()
end)

return test
