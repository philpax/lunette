local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local menuContract = require '@lunette-contracts/menu'
local themeContract = require '@lunette-contracts/theme'
local themesContract = require '@lunette-contracts/themes'
local base = require '@lunette-plugins/theme/base'
local descriptors = require '@lunette-plugins/theme/descriptors'
local presets = require '@lunette-plugins/theme/standard/presets'
local arcade = require '@lunette-plugins/theme/arcade/preset'

type Config = typeof(require('@lunette-plugins/desktop/theme/config').schema.input {})
type Environment = {
  session: testing.Session,
  native: testing.Native,
  owner: adapter.Context,
  menu: menuContract.Service,
  theme: themeContract.Service,
  themes: themesContract.Service,
}

local test = testing.suite()

local function boot(config: Config?): Environment
  local session = testing.boot {
    'frame',
    'theme',
    'themes',
    'theme/standard',
    'theme/arcade',
    'menu',
    { id = 'desktop/theme', definition = require('@lunette-plugins/desktop/theme').definition, config = config or {} },
  }
  local env: Environment = { session = session, native = session.native }
  session:use(adapter.define {
    name = 'selector-test',
    requires = {
      menuContract.capability,
      themeContract.capability,
      themesContract.capability,
    },
    init = function(context: adapter.Context)
      env.owner = context
      env.menu = context:require(menuContract.capability)
      env.theme = context:require(themeContract.capability)
      env.themes = context:require(themesContract.capability)
    end,
  })
  return env
end

local function shows(env: Environment, expected: themeContract.Theme, label: string)
  expect.truthy(descriptors.equal(env.theme:current().theme, expected), label)
end

-- Returns the Appearance choice ids in menu order, with the selected one marked by an asterisk.
local function choices(env: Environment): string
  local result: { string } = {}
  for _, action in env.menu:list() do
    if action.group == 'Appearance' then
      result[#result + 1] = action.id:gsub('^desktop/theme/', '') .. (if action.selected then '*' else '')
    end
  end
  return table.concat(result, ',')
end

local function invoke(env: Environment, name: string): 'invoked' | 'unavailable' | 'failed'
  return env.menu:invoke('desktop/theme/' .. name).kind
end

local function logged(env: Environment, message: string): number
  local count = 0
  for _, log in env.native.events.logs do
    if log[1]:find(message, 1, true) then
      count += 1
    end
  end
  return count
end

test('choices follow the catalog and a choice selects its theme', function()
  local env = boot()
  expect.equal(choices(env), 'dark*,light,arcade', 'the initial choices')
  shows(env, presets.dark, 'the configured default')
  expect.equal(invoke(env, 'arcade'), 'invoked', 'choosing Arcade')
  expect.equal(choices(env), 'dark,light,arcade*', 'the choice after Arcade')
  shows(env, arcade, 'the Arcade theme')
  env.session:close()
end)

test('disabling the selected theme falls back to the configured one, and re-enabling it restores it', function()
  local env = boot { preset = 'light' }
  invoke(env, 'arcade')
  local arcadePlugin = env.session.instances['theme/arcade']
  arcadePlugin:disable()
  expect.equal(choices(env), 'dark,light*', 'Arcade leaves the menu and Light is shown')
  shows(env, presets.light, 'the configured fallback')
  arcadePlugin:enable()
  expect.equal(choices(env), 'dark,light,arcade*', 'Arcade returns as the session choice')
  env.session:close()
end)

test('a configured name that is not registered is reported once and applied once it registers', function()
  local env = boot { preset = 'later' }
  local missing = 'desktop/theme: later is not a registered theme; the registered themes are dark, light, arcade'
  env.session:update()
  env.session:update()
  expect.equal(logged(env, missing), 1, 'the missing theme is reported once')
  shows(env, base, 'nothing is selected')
  env.themes:register(env.owner, { name = 'later', label = 'Later', order = 4, theme = presets.light })
  expect.equal(choices(env), 'dark,light,arcade,later*', 'the registered theme is chosen')
  env.session:close()
end)

test('configured overrides apply over whichever theme is chosen', function()
  local env = boot { overrides = { metrics = { padding = 3 } } }
  expect.equal(env.theme:current().theme.metrics.padding, 3, 'the override over Dark')
  invoke(env, 'arcade')
  expect.equal(env.theme:current().theme.metrics.padding, 3, 'the override over Arcade')
  expect.equal(env.theme:current().theme.metrics.spacing, arcade.metrics.spacing, 'the rest of Arcade')
  env.session:close()
end)

return test
