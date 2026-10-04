local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local tagsContract = require '@lunette-contracts/tags'
local placementContract = require '@lunette-contracts/placement'
local panelsContract = require '@lunette-contracts/panels'

local test = testing.suite()

local WORKSPACES = require '@lunette-plugins/desktop/workspaces'

local function start(config)
  local env = {}
  env.session = testing.boot {
    'frame',
    'bindings',
    'panels',
    'tags',
    'rules',
    'placement',
    {
      id = 'desktop/workspaces',
      definition = WORKSPACES,
      config = config or {
        workspaces = { { name = 'main', key = '1' }, { name = 'web', key = '2' } },
        modifiers = { 'alt' },
      },
    },
  }
  env.native = env.session.native
  env.session:use(plugin.define {
    name = 'workspaces-test',
    requires = {
      panels = panelsContract.capability,
      tags = tagsContract.capability,
      placement = placementContract.capability,
    },
    init = function(context)
      env.owner = context
      env.tags = context:require(tagsContract.capability)
      env.placement = context:require(placementContract.capability)
    end,
  })
  env.main, env.web = env.tags:find 'main', env.tags:find 'web'
  return env
end

local function open(env, id)
  local panel = env.placement:place(env.owner, { window = env.native.newWindow(id), defaults = { tags = { 'main' } } })
  return panel
end

local function chord(env, key)
  env.native.events.held.lalt = true
  lovr.keypressed(key, 0, false)
  env.native.events.held = {}
end

test('a chord switches the workspace, hiding the panels of the one left and showing those chosen', function()
  local env = start()
  expect.truthy(env.main.selected and not env.web.selected, 'the first workspace is in view at activation')
  local first = open(env, 1)
  expect.falsy(first.hidden, 'a window of the workspace in view')
  chord(env, '2')
  expect.truthy(env.web.selected and not env.main.selected, 'the chord selects its workspace')
  expect.truthy(first.hidden, 'a window of a workspace out of view')
  local second = open(env, 2)
  expect.truthy(env.web:has(second) and not env.main:has(second), 'a new window joins the workspace in view')
  expect.falsy(second.hidden, 'the new window is shown')
  chord(env, '1')
  expect.truthy(not first.hidden and second.hidden, 'switching back shows and hides again')
  env.session:close()
end)

test('a panel another plugin hid stays hidden when its workspace comes into view', function()
  local env = start()
  local first = open(env, 1)
  local hiding = first:setHidden(env.owner, { hidden = true })
  chord(env, '2')
  chord(env, '1')
  expect.truthy(first.hidden, 'a panel another plugin hid')
  hiding:dispose()
  expect.falsy(first.hidden, 'the panel once the other plugin lets it go')
  env.session:close()
end)

test('a window moved to a workspace out of view is hidden until that workspace is chosen', function()
  local env = start()
  local first = open(env, 1)
  env.main:exclude(env.owner, { panel = first })
  env.web:add(env.owner, first)
  expect.truthy(first.hidden, 'a window moved out of view')
  chord(env, '2')
  expect.falsy(first.hidden, 'the window once its workspace is chosen')
  env.session:close()
end)

test('a bindings outage leaves the workspaces as they were, and the chords return with it', function()
  local env = start()
  local first = open(env, 1)
  chord(env, '2')
  env.session.instances.bindings:disable()
  expect.equal(env.session.instances['desktop/workspaces']:state(), 'active', 'the consumer during the outage')
  expect.truthy(env.web.selected and first.hidden, 'the workspaces during the outage')
  env.session.instances.bindings:enable()
  chord(env, '1')
  expect.truthy(env.main.selected and not first.hidden, 'a chord after the outage')
  env.session:close()
end)

test('unloading the consumer shows every panel it hid', function()
  local env = start()
  local first = open(env, 1)
  chord(env, '2')
  local second = open(env, 2)
  chord(env, '1')
  env.session.instances['desktop/workspaces']:disable()
  expect.truthy(not first.hidden and not second.hidden, 'the panels after unloading')
  env.session:close()
end)

test('a malformed workspace list fails the consumer and names the option', function()
  for _, case in ipairs {
    { config = { workspaces = {} }, message = 'option workspaces names at least one workspace' },
    { config = { workspaces = { { name = 'a', key = '1' }, { name = 'a', key = '2' } } }, message = 'names a twice' },
  } do
    local env = start(case.config)
    local instance = env.session.instances['desktop/workspaces']
    expect.equal(instance:state(), 'failed', 'the consumer')
    local diagnostic = tostring(instance:diagnostic())
    expect.truthy(diagnostic:find(case.message, 1, true), 'the diagnostic: ' .. diagnostic)
    expect.equal(#testing.takeReports(), 1, 'the failures reported')
    env.session:close()
  end
end)

return test
