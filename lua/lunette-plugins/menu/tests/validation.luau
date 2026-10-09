local testing = require '@testing'
local expect = testing.expect
local fixture = require './support/fixture'
local test = testing.suite()

test('registration rejects malformed fields, unknown keys, and non-finite order', function()
  local env = fixture.start()
  local malformed = {
    { value = false, message = 'menu register: action is a plain table' },
    { value = {}, message = 'menu register: id is a non-empty string' },
    { value = { id = 'x', label = '', run = function() end }, message = 'label is a non-empty string' },
    { value = { id = 'x', label = 'X', run = true }, message = 'run is a function' },
    { value = { id = 'x', label = 'X', group = {}, run = function() end }, message = 'menu register: group is ' },
    { value = { id = 'x', label = 'X', order = 0 / 0, run = function() end }, message = 'order is a finite number' },
    { value = { id = 'x', label = 'X', unknown = true, run = function() end }, message = 'unknown field unknown' },
  }
  for _, case in ipairs(malformed) do
    expect.raises(function()
      env.service:register(env.owner, case.value)
    end, case.message:gsub('%-', '%%-'), 'a malformed action')
  end
  expect.equal(#env.service:list(), 0, 'validation failures acquire no registrations')
  expect.raises(function()
    env.service:invoke(false)
  end, 'menu invoke: id is a non%-empty string', 'a malformed invocation id')
  env.session:close()
end)

test('state validation is atomic and rejects unknown and mistyped fields', function()
  local env = fixture.start()
  local effect = env.service:register(env.owner, fixture.action 'fixture.state')
  local malformed = {
    { value = { enabled = false, selected = 'yes' }, message = 'selected is a boolean' },
    { value = { enabled = false, extra = true }, message = 'unknown field extra' },
  }
  for _, case in ipairs(malformed) do
    expect.raises(function()
      env.service:update(env.owner, effect, case.value)
    end, 'menu update: ' .. case.message, 'a malformed update')
    expect.equal(env.service:list()[1].enabled, true, 'invalid updates preserve enabled')
    expect.equal(env.service:list()[1].selected, false, 'invalid updates preserve selected')
  end
  env.session:close()
end)

return test
