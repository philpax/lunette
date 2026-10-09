local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local menuContract = require '@lunette-contracts/menu'
local themeContract = require '@lunette-contracts/theme'
local themesContract = require '@lunette-contracts/themes'
local base = require '@lunette-plugins/theme/base'
local descriptors = require '@lunette-plugins/theme/descriptors'
local presets = require '@lunette-plugins/theme/standard/presets'
local arcade = require '@lunette-plugins/theme/arcade/preset'

local test = testing.suite()

-- A failed case leaves its session open; closing it here keeps one failure from failing every later boot.
local leftover

local function boot(config)
  if leftover then
    pcall(leftover.close, leftover)
  end
  local session = testing.boot {
    'frame',
    'theme',
    'themes',
    'theme/standard',
    'theme/arcade',
    'menu',
    { id = 'desktop/theme', factory = require '@lunette-plugins/desktop/theme', config = config or {} },
  }
  leftover = session
  local env = { session = session, native = session.native }
  session:use(plugin.define {
    name = 'selector-test',
    requires = {
      menu = menuContract.capability,
      theme = themeContract.capability,
      themes = themesContract.capability,
    },
    init = function(context)
      env.owner = context
      env.menu = context:require(menuContract.capability)
      env.theme = context:require(themeContract.capability)
      env.themes = context:require(themesContract.capability)
    end,
  })
  return env
end

local function shows(env, expected, label)
  expect.truthy(descriptors.equal(env.theme:current().theme, expected), label)
end

-- Returns the Appearance choice ids in menu order, with the selected one marked by an asterisk.
local function choices(env)
  local result = {}
  for _, action in env.menu:list() do
    if action.group == 'Appearance' then
      result[#result + 1] = action.id:gsub('^desktop/theme/', '') .. (if action.selected then '*' else '')
    end
  end
  return table.concat(result, ',')
end

local function invoke(env, name)
  return env.menu:invoke('desktop/theme/' .. name).kind
end

local function logged(env, message)
  local count = 0
  for _, log in env.native.events.logs do
    if log[1]:find(message, 1, true) then
      count += 1
    end
  end
  return count
end

test('choices follow the catalog and a choice updates one selection in place', function()
  local env = boot()
  expect.equal(choices(env), 'dark*,light,arcade', 'the initial choices')
  shows(env, presets.dark, 'the configured default')
  expect.equal(invoke(env, 'arcade'), 'invoked', 'choosing Arcade')
  expect.equal(choices(env), 'dark,light,arcade*', 'the choice after Arcade')
  shows(env, arcade, 'the Arcade theme')
  local selections = 0
  for _, registration in env.theme:inspect().registrations do
    if registration.kind == 'selection' then
      selections += 1
    end
  end
  expect.equal(selections, 1, 'the selector holds one selection')
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
  shows(env, arcade, 'the restored session choice')
  env.session:close()
end)

test('a choice made while a theme is missing outranks its return', function()
  local env = boot()
  invoke(env, 'arcade')
  local arcadePlugin = env.session.instances['theme/arcade']
  arcadePlugin:disable()
  invoke(env, 'light')
  arcadePlugin:enable()
  expect.equal(choices(env), 'dark,light*,arcade', 'Light remains chosen')
  shows(env, presets.light, 'the later choice')
  env.session:close()
end)

test('with neither the choice nor the configured theme registered, nothing is selected', function()
  local env = boot()
  env.session.instances['theme/standard']:disable()
  expect.equal(choices(env), 'arcade', 'only Arcade is offered')
  shows(env, base, 'the base theme')
  invoke(env, 'arcade')
  shows(env, arcade, 'a remaining theme can still be chosen')
  env.session:close()
end)

test('a configured name that is not registered is reported after a frame and applied once it registers', function()
  local env = boot { preset = 'later' }
  local missing = 'desktop/theme: later is not a registered theme; the registered themes are dark, light, arcade'
  expect.equal(logged(env, missing), 0, 'activation alone reports nothing')
  env.session:update()
  env.session:update()
  expect.equal(logged(env, missing), 1, 'the missing theme is reported once')
  shows(env, base, 'nothing is selected')
  env.themes:register(env.owner, { name = 'later', label = 'Later', order = 4, theme = presets.light })
  expect.equal(choices(env), 'dark,light,arcade,later*', 'the registered theme is chosen')
  shows(env, presets.light, 'the late theme is shown')
  env.session:close()
end)

test('a theme registered ahead of the others moves every choice after it', function()
  local env = boot()
  env.themes:register(env.owner, { name = 'first', label = 'First', order = 0, theme = presets.light })
  expect.equal(choices(env), 'first,dark*,light,arcade', 'the menu follows the catalog order')
  env.session:close()
end)

test('a theme registered again under the selected name replaces the shown theme', function()
  local env = boot { preset = 'arcade' }
  env.session.instances['theme/arcade']:disable()
  local substitute = descriptors.resolve(arcade, { colors = { focus = { 1, 0, 0, 1 } } })
  local registration = env.themes:register(env.owner, { name = 'arcade', label = 'Arcade II', theme = substitute })
  expect.equal(choices(env), 'arcade*,dark,light', 'the substitute is chosen and its order is respected')
  shows(env, substitute, 'the substitute theme')
  local labels = {}
  for _, action in env.menu:list() do
    labels[action.id] = action.label
  end
  expect.equal(labels['desktop/theme/arcade'], 'Theme: Arcade II', 'the substitute label')
  registration:dispose()
  shows(env, base, 'with the configured name gone too, nothing is selected')
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

test('the session choice survives a selector reactivation, but a changed configured name wins', function()
  local env = boot()
  invoke(env, 'arcade')
  local selector = env.session.instances['desktop/theme']
  selector:disable()
  shows(env, base, 'a disabled selector selects nothing')
  expect.equal(choices(env), '', 'a disabled selector offers nothing')
  selector:enable()
  expect.equal(choices(env), 'dark,light,arcade*', 'the session choice returns')
  selector:reload { preset = 'light' }
  expect.equal(choices(env), 'dark,light*,arcade', 'the changed configured name')
  selector:disable()
  selector:enable()
  expect.equal(choices(env), 'dark,light*,arcade', 'the changed configured name replaces the earlier session choice')
  env.session:close()
end)

test('a failed choice keeps the previous selection and menu state', function()
  local env = boot()
  local newFont = lovr.graphics.newFont
  lovr.graphics.newFont = function()
    error 'the face cannot be loaded'
  end
  local result = env.menu:invoke 'desktop/theme/arcade'
  lovr.graphics.newFont = newFont
  expect.equal(result.kind, 'failed', 'the choice fails')
  local reported = env.native.events.reported
  expect.truthy(reported[#reported].message:find('the face cannot be loaded', 1, true), 'the cause is reported')
  expect.equal(choices(env), 'dark*,light,arcade', 'the menu state is unchanged')
  shows(env, presets.dark, 'the previous theme remains')
  env.session:close()
end)

return test
