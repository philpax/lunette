local testing = require '@testing'
local expect = testing.expect
local themesContract = require '@lunette-contracts/themes'
local base = require '@lunette-plugins/theme/base'

local test = testing.suite()

type Environment = {
  native: typeof(testing.native()),
  session: typeof(testing.start {})?,
  themes: themesContract.Service?,
  owner: typeof(testing.start({}):observe(themesContract.capability).context)?,
}

local function start(entries: { string }?): Environment
  local env: Environment = { native = testing.native() }
  env.session = testing.start(entries or { 'themes' })
  local observed = env.session:observe(themesContract.capability)
  env.themes, env.owner = observed.service, observed.context
  return env
end

local function names(env: Environment): string
  local result: { string } = {}
  for _, entry in env.themes:list() do
    result[#result + 1] = entry.name
  end
  return table.concat(result, ',')
end

test('a registration is checked before it is accepted', function()
  local env = start()
  -- Validation accepts untrusted records, including deliberately incomplete themes.
  local function rejects(
    registration: { read name: string, read label: string, read theme: unknown },
    message: string,
    label: string
  )
    expect.raises(function()
      env.themes:register(env.owner, registration)
    end, message, label)
  end
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
  expect.equal(env.themes:get 'missing', nil, 'an unregistered name')
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
