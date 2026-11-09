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

test('disabled reasons reject empty and mistyped values before changing state', function()
  local env = fixture.start()
  for _, value in { '', true, 42, false } do
    expect.raises(function()
      env.service:register(env.owner, { id = 'reason', label = 'Reason', disabledReason = value, run = function() end })
    end, 'disabledReason is a non%-empty string')
  end
  local registration = env.service:register(env.owner, fixture.action 'reason')
  for _, value in { '', true, 42 } do
    expect.raises(function()
      registration:update { disabledReason = value }
    end, 'disabledReason is a non%-empty string')
  end
  expect.equal(env.service:list()[1].enabled, true, 'invalid updates preserve the action')
  env.session:close()
end)

return test
