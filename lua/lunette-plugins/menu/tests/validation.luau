local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local fixture = require './support/fixture'
local test = testing.suite()

test('registration rejects malformed plain fields unknown keys sparse data and non-finite order', function()
  local env = fixture.start()
  local malformed = {
    { value = false, message = 'menu register: action is a plain table' },
    { value = {}, message = 'menu register: id is a non-empty string' },
    { value = { id = '', label = 'Empty', run = function() end }, message = 'id is a non-empty string' },
    { value = { id = 'x', label = false, run = function() end }, message = 'label is a non-empty string' },
    { value = { id = 'x', label = '', run = function() end }, message = 'label is a non-empty string' },
    { value = { id = 'x', label = 'X', run = true }, message = 'run is a function' },
  }
  for _, case in ipairs(malformed) do
    expect.raises(function()
      env.service:register(env.owner, case.value)
    end, case.message:gsub('%-', '%%-'), 'a malformed action')
  end
  for _, field in ipairs { 'group', 'order', 'enabled', 'selected' } do
    local action = fixture.action 'x'
    action[field] = {}
    expect.raises(function()
      env.service:register(env.owner, action)
    end, 'menu register: ' .. field .. ' is ', 'a mistyped optional field')
  end
  for _, order in ipairs { math.huge, -math.huge, 0 / 0 } do
    local action = fixture.action 'x'
    action.order = order
    expect.raises(function()
      env.service:register(env.owner, action)
    end, 'menu register: order is a finite number', 'non-finite order')
  end
  for _, key in ipairs { 'unknown', 1, 3 } do
    local action = fixture.action 'x'
    action[key] = true
    expect.raises(function()
      env.service:register(env.owner, action)
    end, 'menu register: unknown field ' .. tostring(key), 'unknown or sparse numeric fields')
  end
  local getterCalls = 0
  local exotic = setmetatable(fixture.action 'x', {
    __index = function()
      getterCalls += 1
      error 'an action getter runs'
    end,
  })
  expect.raises(function()
    env.service:register(env.owner, exotic)
  end, 'menu register: action is a plain table', 'a metatable action')
  expect.equal(getterCalls, 0, 'validation calls no getters')
  expect.equal(#env.service:list(), 0, 'validation failures acquire no registrations')
  env.session:close()
end)

test('state validation is atomic and rejects unknown numeric metatable and mistyped fields', function()
  local env = fixture.start()
  local effect = env.service:register(env.owner, fixture.action 'fixture.state')
  local malformed = {
    { value = false, message = 'state is a plain table' },
    { value = { enabled = 1 }, message = 'enabled is a boolean' },
    { value = { enabled = false, selected = 'yes' }, message = 'selected is a boolean' },
    { value = { enabled = false, extra = true }, message = 'unknown field extra' },
    { value = { [2] = true }, message = 'unknown field 2' },
    { value = setmetatable({}, {}), message = 'state is a plain table' },
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

test('fabricated unrelated and out-of-runtime owners cannot register or update actions', function()
  local env = fixture.start()
  local effect = env.service:register(env.owner, fixture.action 'fixture.authority')
  local calls = 0
  local fake = {
    services = function()
      calls += 1
    end,
    effect = function()
      calls += 1
      error 'a fabricated owner effect runs'
    end,
  }
  expect.raises(function()
    env.service:register(fake, fixture.action 'fake')
  end, 'the owner is not a plugin context', 'a fabricated owner')
  expect.equal(env.service:update(fake, effect, { enabled = false }), false, 'a fabricated owner cannot update')
  expect.equal(calls, 0, 'owner methods are not trusted')
  local unrelatedOwner
  env.session:use(plugin.define {
    name = 'menu-unrelated',
    init = function(context)
      unrelatedOwner = context
    end,
  })
  expect.raises(function()
    env.service:register(unrelatedOwner, fixture.action 'unrelated')
  end, 'plugin', 'an owner without the capability dependency')
  expect.equal(
    env.service:update(unrelatedOwner, effect, { enabled = false }),
    false,
    'an unrelated owner cannot update'
  )
  local other = testing.start { 'menu' }
  local foreign = other:observe(require('@lunette-contracts/menu').capability)
  expect.raises(function()
    env.service:register(foreign.context, fixture.action 'foreign')
  end, 'plugin', 'an owner from another runtime')
  expect.equal(env.service:update(foreign.context, effect, { enabled = false }), false, 'a foreign owner cannot update')
  other:close()
  expect.equal(env.service:invoke('missing').kind, 'unavailable', 'an absent id')
  expect.raises(function()
    env.service:invoke(false)
  end, 'menu invoke: id is a non%-empty string', 'a malformed invocation id')
  env.session:close()
end)

return test
