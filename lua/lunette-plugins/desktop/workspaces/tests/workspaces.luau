local testing = require '@testing'
local expect = testing.expect
local plugin = require '@lunette-plugin'
local tagsContract = require '@lunette-contracts/tags'
local placementContract = require '@lunette-contracts/placement'
local panelsContract = require '@lunette-contracts/panels'
local menuContract = require '@lunette-contracts/menu'

local test = testing.suite()

local WORKSPACES = require '@lunette-plugins/desktop/workspaces'

local function start(config)
  local env = {}
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
      definition = WORKSPACES,
      config = config or { workspaces = { { name = 'main' }, { name = 'web' } } },
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
  env.actions = env.session:observe(menuContract.capability)
  env.main, env.web = env.tags:find 'main', env.tags:find 'web'
  return env
end

-- Selects one tag for the owner and deselects the others.
local function only(tags, owner, chosen)
  for _, tag in tags:all() do
    tag:setSelected(owner, { selected = tag == chosen })
  end
end

local function open(env, id)
  return env.placement:place(env.owner, { window = env.native.newWindow(id), defaults = { tags = { 'main' } } })
end

local function choose(env, name)
  expect.equal(env.actions.service:invoke('desktop/workspace/' .. name).kind, 'invoked', 'the workspace action')
end

local function row(env, name)
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
  local actions = env.actions.service:list()
  expect.equal(#actions, 2, 'one action per workspace')
  expect.equal(actions[1].id, 'desktop/workspace/main', 'the first action id')
  expect.equal(actions[1].label, 'main', 'the configured workspace name')
  expect.equal(actions[1].group, 'Workspaces', 'the workspace group')
  expect.equal(actions[1].order, 1, 'the configured order')
  expect.equal(actions[1].selected, true, 'the first action is selected')
  expect.equal(actions[2].order, 2, 'the second action order')
  expect.equal(actions[2].selected, false, 'the second action is explicitly unselected')
  local first = open(env, 1)
  expect.falsy(first.hidden, 'a window of the workspace in view')
  choose(env, 'web')
  expect.truthy(env.web.selected and not env.main.selected, 'the action selects its workspace')
  expect.truthy(first.hidden, 'a window of a workspace out of view')
  expect.truthy(row(env, 'web').selected and not row(env, 'main').selected, 'selected action metadata')
  local second = open(env, 2)
  expect.truthy(env.web:has(second) and not env.main:has(second), 'a new window joins the workspace in view')
  expect.falsy(second.hidden, 'the new window is shown')
  choose(env, 'main')
  expect.truthy(not first.hidden and second.hidden, 'switching back shows and hides again')
  env.session:close()
end)

test('a panel another plugin hid stays hidden when its workspace comes into view', function()
  local env = start()
  local first = open(env, 1)
  local hiding = first:setHidden(env.owner, { hidden = true })
  choose(env, 'web')
  choose(env, 'main')
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
  choose(env, 'web')
  expect.falsy(first.hidden, 'the window once its workspace is chosen')
  env.session:close()
end)

test(
  'a menu outage preserves selection, visibility, and follow, and recovery uses current selected metadata',
  function()
    local env = start()
    local first = open(env, 1)
    choose(env, 'web')
    local oldService, oldInvoke = env.actions.service, env.actions.service.invoke
    local oldRow = row(env, 'main')
    env.session.instances.menu:disable()
    expect.equal(env.session.instances['desktop/workspaces']:state(), 'active', 'the consumer during the outage')
    expect.truthy(env.web.selected and first.hidden, 'the workspaces during the outage')
    expect.equal(oldInvoke(oldService, oldRow.id, oldRow.registration).kind, 'unavailable', 'an old action is inert')
    local second = open(env, 2)
    expect.truthy(env.web:has(second) and not env.main:has(second), 'follow remains active without the broker')
    only(env.tags, env.owner, env.main)
    expect.truthy(not first.hidden and second.hidden, 'external selection updates visibility without the broker')
    env.session.instances.menu:enable()
    expect.truthy(row(env, 'main').selected and not row(env, 'web').selected, 'recovery reads actual tag selection')
    expect.equal(
      env.actions.service:invoke(oldRow.id, oldRow.registration).kind,
      'unavailable',
      'a stale registration cannot select after recovery'
    )
    choose(env, 'web')
    expect.truthy(env.web.selected and first.hidden and not second.hidden, 'the recovered action')
    env.session:close()
  end
)

test('external tag selection updates action metadata and the workspace followed by newly placed panels', function()
  local env = start()
  only(env.tags, env.owner, env.web)
  expect.truthy(row(env, 'web').selected and not row(env, 'main').selected, 'external selection metadata')
  local panel = open(env, 1)
  expect.truthy(env.web:has(panel) and not env.main:has(panel), 'follow uses the externally chosen workspace')
  expect.falsy(panel.hidden, 'the followed panel is visible')
  env.session:close()
end)

test('follow can be disabled while workspace actions still update visibility', function()
  local env = start { workspaces = { { name = 'main' }, { name = 'web' } }, follow = false }
  choose(env, 'web')
  local panel = open(env, 1)
  expect.truthy(env.main:has(panel) and not env.web:has(panel), 'placement retains its configured workspace')
  expect.truthy(panel.hidden, 'the unselected workspace is hidden')
  choose(env, 'main')
  expect.falsy(panel.hidden, 'choosing the configured workspace shows it')
  env.session:close()
end)

test('unloading the consumer shows every panel it hid and removes its actions', function()
  local env = start()
  local first = open(env, 1)
  choose(env, 'web')
  local second = open(env, 2)
  choose(env, 'main')
  local oldRow = row(env, 'web')
  env.session.instances['desktop/workspaces']:disable()
  expect.truthy(not first.hidden and not second.hidden, 'the panels after unloading')
  expect.equal(#env.actions.service:list(), 0, 'the registrations after unloading')
  expect.equal(env.actions.service:invoke(oldRow.id, oldRow.registration).kind, 'unavailable', 'the ended action')
  env.session:close()
end)

test('a malformed workspace list fails the consumer and names the option', function()
  for _, case in ipairs {
    { config = { workspaces = {} }, message = 'option workspaces has fewer than 1 entries' },
    {
      config = { workspaces = { { name = 'a' }, { name = 'a' } } },
      message = 'workspace name a occurs twice',
    },
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

test('a single workspace registers no menu actions', function()
  local env = start { workspaces = { { name = 'main' } } }
  expect.truthy(env.main.selected, 'the only workspace is in view')
  expect.equal(#env.actions.service:list(), 0, 'the menu actions')
  env.session:close()
end)

return test
