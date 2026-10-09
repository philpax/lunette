local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local themesContract = require '@lunette-contracts/themes'
local base = require '@lunette-plugins/theme/base'

local test = testing.suite()

local function start(entries)
  local env = { native = testing.native() }
  env.session = testing.start(entries or { 'themes' })
  local observed = env.session:observe(themesContract.capability)
  env.themes, env.owner = observed.service, observed.context
  return env
end

local function registrant(env, name, registrations)
  return env.session:use(plugin.define {
    name = name,
    requires = { themes = themesContract.capability },
    init = function(context)
      local catalog = context:require(themesContract.capability)
      for _, registration in registrations do
        catalog:register(context, registration)
      end
    end,
  })
end

local function names(env)
  local result = {}
  for _, entry in env.themes:list() do
    result[#result + 1] = entry.name
  end
  return table.concat(result, ',')
end

test('a registration is checked before it is accepted', function()
  local env = start()
  local function rejects(registration, message, label)
    expect.raises(function()
      env.themes:register(env.owner, registration)
    end, message, label)
  end
  rejects(
    { name = 'x', label = 'X', theme = base, colour = 1 },
    'themes register: unknown field colour; the fields are name, label, order, and theme',
    'an unknown field'
  )
  rejects({ name = '', label = 'X', theme = base }, 'themes register: name is a non%-empty string', 'an empty name')
  rejects({ name = 'x', theme = base }, 'themes register: label is a non%-empty string', 'a missing label')
  rejects({ name = 'x', label = 'X', order = 0 / 0, theme = base }, 'themes register: order is a finite', 'a NaN order')
  rejects(
    { name = 'x', label = 'X', order = math.huge, theme = base },
    'themes register: order is a finite',
    'an infinite order'
  )
  rejects({ name = 'x', label = 'X', theme = { colors = base.colors } }, 'themes register x', 'an incomplete theme')
  expect.equal(names(env), '', 'no rejected registration is listed')
  env.themes:register(env.owner, { name = 'x', label = 'X', theme = base })
  rejects({ name = 'x', label = 'Other', theme = base }, 'themes register: x is already registered', 'a taken name')
  env.session:close()
end)

test('entries list by order and then by name, and order defaults to zero', function()
  local env = start()
  env.themes:register(env.owner, { name = 'late', label = 'Late', order = 2, theme = base })
  env.themes:register(env.owner, { name = 'beta', label = 'Beta', theme = base })
  env.themes:register(env.owner, { name = 'alpha', label = 'Alpha', theme = base })
  env.themes:register(env.owner, { name = 'early', label = 'Early', order = -1, theme = base })
  expect.equal(names(env), 'early,alpha,beta,late', 'the listed order')
  local listed = env.themes:list()
  expect.equal(#listed, 4, 'every entry is listed')
  expect.equal(listed[2].order, 0, 'an omitted order')
  local entry = env.themes:get 'late'
  expect.equal(entry.label, 'Late', 'the label')
  expect.truthy(table.isfrozen(entry), 'an entry is frozen')
  expect.equal(env.themes:get 'missing', nil, 'an unregistered name')
  env.session:close()
end)

test('an owner ending removes its entries, and reactivation registers them again', function()
  local env = start()
  local heard = 0
  env.themes:onChanged(env.owner, {
    run = function()
      heard += 1
    end,
  })
  local instance = registrant(env, 'catalog-registrant', {
    { name = 'one', label = 'One', theme = base },
    { name = 'two', label = 'Two', theme = base },
  })
  expect.equal(names(env), 'one,two', 'the registered names')
  instance:disable()
  expect.equal(names(env), '', 'an ended owner leaves nothing registered')
  expect.equal(heard, 4, 'each registration and removal is heard')
  instance:enable()
  expect.equal(names(env), 'one,two', 'a reactivated owner registers again')
  env.session:close()
end)

test('the shipped theme plugins register Dark, Light, and Arcade in that order', function()
  local env = start { 'themes', 'theme/standard', 'theme/arcade' }
  expect.equal(names(env), 'dark,light,arcade', 'the shipped names')
  expect.equal(env.themes:get('arcade').theme.typography.font.kind, 'file', 'Arcade carries its bundled face')
  env.session.instances['theme/arcade']:disable()
  expect.equal(names(env), 'dark,light', 'disabling the Arcade plugin removes only Arcade')
  env.session:close()
end)

return test
