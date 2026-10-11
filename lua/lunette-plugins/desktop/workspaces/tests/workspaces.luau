local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local adapter = require '@lunette-plugin/adapter'
local tagsContract = require '@lunette-contracts/tags'
local placementContract = require '@lunette-contracts/placement'
local panelsContract = require '@lunette-contracts/panels'
local menuContract = require '@lunette-contracts/menu'

local test = testing.suite()

local WORKSPACES = require '@lunette-plugins/desktop/workspaces'

type Environment = {
  session: testing.Session,
  native: testing.Native,
  owner: adapter.Context,
  tags: tagsContract.Service,
  placement: placementContract.Service,
  actions: testing.Observed<menuContract.Service>,
  main: tagsContract.Tag?,
  web: tagsContract.Tag?,
}

local function start(config: WORKSPACES.Config?): Environment
  local env: Environment = {}
  env.session = testing.boot {
    'frame',
    'menu',
    'theme',
    'panels',
    'tags',
    'rules',
    'placement',
    {
      id = 'desktop/workspaces',
      definition = WORKSPACES.definition,
      config = config or { names = { 'main', 'web' } },
    },
  }
  env.native = env.session.native
  env.session:use(adapter.define {
    name = 'workspaces-test',
    requires = {
      panelsContract.capability,
      tagsContract.capability,
      placementContract.capability,
    },
    init = function(context: adapter.Context)
      env.owner = context
      env.tags = context:require(tagsContract.capability)
      env.placement = context:require(placementContract.capability)
    end,
  })
  env.actions = env.session:observe(menuContract.capability)
  env.main, env.web = env.tags:find 'main', env.tags:find 'web'
  return env
end

local function open(env: Environment, id: number): (panelsContract.WindowPanel, plugin.Effect)
  local placed, effect =
    env.placement:place(env.owner, { window = env.native.newWindow(id), defaults = { tags = { 'main' } } })
  return placed.panel, effect
end

local function choose(env: Environment, name: string)
  expect.equal(env.actions.service:invoke('desktop/workspace/' .. name).kind, 'invoked', 'the workspace action')
end

local function row(env: Environment, name: string): menuContract.Descriptor
  for _, action in env.actions.service:list() do
    if action.id == 'desktop/workspace/' .. name then
      return action
    end
  end
  error('missing workspace action ' .. name)
end

test('a menu action switches the workspace, hiding the panels of the one left and showing those chosen', function()
  local env = start()
  expect.truthy(env.main.selected and not env.web.selected, 'the first workspace is in view at activation')
  expect.truthy(row(env, 'main').selected and not row(env, 'web').selected, 'the selected action')
  local first = open(env, 1)
  expect.falsy(first.hidden, 'a window of the workspace in view')
  choose(env, 'web')
  expect.truthy(env.web.selected and not env.main.selected, 'the action selects its workspace')
  expect.truthy(first.hidden, 'a window of a workspace out of view')
  local second = open(env, 2)
  expect.truthy(env.web:has(second) and not env.main:has(second), 'a new window joins the workspace in view')
  expect.falsy(second.hidden, 'the new window is shown')
  choose(env, 'main')
  expect.truthy(not first.hidden and second.hidden, 'switching back shows and hides again')
  env.session:close()
end)

test('a panel another plugin hid stays hidden, and unloading shows only what the consumer hid', function()
  local env = start()
  local first, second = open(env, 1), open(env, 2)
  local hiding = first:setHidden(env.owner, true)
  choose(env, 'web')
  choose(env, 'main')
  expect.truthy(first.hidden, 'a panel another plugin hid')
  choose(env, 'web')
  env.session.instances['desktop/workspaces']:disable()
  expect.falsy(second.hidden, 'unloading shows the panels the consumer hid')
  expect.truthy(first.hidden, 'and leaves hidden what another plugin hid')
  expect.equal(#env.actions.service:list(), 0, 'unloading removes the actions')
  hiding:dispose()
  env.session:close()
end)

test('follow can be disabled while workspace actions still update visibility', function()
  local env = start { names = { 'main', 'web' }, follow = false }
  choose(env, 'web')
  local panel = open(env, 1)
  expect.truthy(env.main:has(panel) and not env.web:has(panel), 'placement retains its configured workspace')
  expect.truthy(panel.hidden, 'the unselected workspace is hidden')
  choose(env, 'main')
  expect.falsy(panel.hidden, 'choosing the configured workspace shows it')
  env.session:close()
end)

test('a placed window in no workspace joins the selected one, and rejoins when the consumer activates again', function()
  local env = start { names = { 'main', 'web' }, follow = false }
  choose(env, 'web')
  local panel = env.placement:place(env.owner, { window = env.native.newWindow(1) }).panel
  expect.truthy(env.web:has(panel) and not env.main:has(panel), 'the window joins the selected workspace')
  local instance = env.session.instances['desktop/workspaces']
  instance:disable()
  instance:enable()
  local main = assert(env.tags:find 'main')
  expect.truthy(main.selected and main:has(panel), 'the reactivated consumer puts the window in its workspace')
  env.session:close()
end)

test('a duplicate workspace name fails the consumer and names the option', function()
  local env = start { names = { 'a', 'a' } }
  local instance = env.session.instances['desktop/workspaces']
  expect.equal(instance:state(), 'failed', 'the consumer')
  local diagnostic = tostring(testing.diagnostic(env.session.runtime, instance))
  expect.truthy(diagnostic:find('workspace name a occurs twice', 1, true), 'the diagnostic: ' .. diagnostic)
  expect.equal(#testing.takeReports(), 1, 'the failures reported')
  env.session:close()
end)

return test
